# virtual_feature.pl
# Virtualmin feature hooks for the Remote Mail Server plugin.
# This file is loaded by Virtualmin to register the plugin as a domain feature.
#
# Architecture (Approach C):
#   vh1 (this plugin) — Coordination layer:
#     DNS records (MX, SPF, DKIM, DMARC) on vh1's DNS
#     SSL certificate sync to email1
#     UI for managing remote mail users
#     Delegates all mail server operations to email1's Virtualmin
#
#   email1 (remote Virtualmin) — All mail server operations:
#     Virtualmin CLI API: create-domain, create-user, modify-user, etc.
#     Handles Postfix, Dovecot, SpamAssassin, ClamAV, DKIM, quotas

use strict;
use warnings;
our (%text, %config);
our $module_name;
our $module_config_directory;
our $domains_dir;

require 'virtualmin-remote-mail-lib.pl';
my $input_name = $module_name;
$input_name =~ s/[^A-Za-z0-9]/_/g;

# feature_name()
# Returns a short name for this feature
sub feature_name
{
return $text{'feat_name'};
}

# feature_losing(&domain)
# Returns a description of what will be deleted when this feature is removed
sub feature_losing
{
return $text{'feat_losing'};
}

# feature_label(in-edit-form)
# Returns the label for domain creation and editing forms
sub feature_label
{
my ($edit) = @_;
return $edit ? $text{'feat_label2'} : $text{'feat_label'};
}

# feature_hlink(in-edit-form)
# Returns the help page linked by the feature label
sub feature_hlink
{
return 'feat';
}

# feature_check()
# Returns undef if all needed programs/configs are present, or an error message
sub feature_check
{
# Verify at least one remote mail server is configured
my @servers = &list_remote_mail_servers();
if (!@servers) {
	return $text{'feat_enoserver'};
	}
return undef;
}

# feature_depends(&domain, [&olddomain])
# Returns undef if all dependencies are met, or an error message.
# Requires DNS feature to be enabled (we manage MX/SPF/DKIM records).
sub feature_depends
{
my ($d, $oldd) = @_;
return $text{'feat_edns'} if (!$d->{'dns'});
return undef;
}

# feature_clash(&domain, [field])
# Returns undef if no clash, or an error message.
# Clashes with the local mail feature — can't have both.
sub feature_clash
{
my ($d, $field) = @_;
return undef if ($field && $field ne 'dom');
if ($d->{'mail'}) {
	return $text{'feat_eclash_mail'};
	}
return undef;
}

# feature_suitable([&parentdom], [&aliasdom], [&subdom])
# Returns 1 if this feature can be used with the given domain type.
# Only for top-level domains, not aliases or subs.
sub feature_suitable
{
my ($parentdom, $aliasdom, $subdom) = @_;
return !$aliasdom && !$subdom;
}

# feature_setup(&domain)
# Called when this feature is enabled for a domain.
# Creates the domain on the remote mail server via Virtualmin API,
# then configures DNS records on vh1.
sub feature_setup
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $server = &get_remote_mail_server($server_id);
if (!$server) {
	&$virtual_server::first_print($text{'setup_start'});
	&$virtual_server::second_print($text{'setup_enoserver'});
	return 0;
	}

&obtain_lock_remote_mail($d);

my %state = ( 'server_id' => $server_id,
              'setup_time' => time() );
my $ok = 1;

# Step 1: Validate remote server connectivity
&$virtual_server::first_print($text{'setup_test'});
my $err = &test_remote_mail_server($server_id);
if ($err) {
	&$virtual_server::second_print(&text('setup_etest', $err));
	&release_lock_remote_mail();
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});

# Step 2: Create domain on remote mail server via Virtualmin API
# This handles: Unix user, home dir, Postfix, Dovecot, SpamAssassin,
# ClamAV, DKIM, and all other mail-related configuration.
if ($ok) {
	&$virtual_server::first_print($text{'setup_domain'});
	my @create_args = (
		"--domain", $d->{'dom'},
		"--pass", $d->{'pass'} || 'changeme',
		"--mail", "--spam", "--virus", "--unix", "--dir",
		"--skip-warnings",
		);
	push(@create_args, "--template", $server->{'template'})
		if ($server->{'template'});

	my ($out, $exit) = &remote_virtualmin_cmd($server_id,
		"create-domain", @create_args);
	if ($exit) {
		&$virtual_server::second_print(
			&text('setup_edomain_create', $out));
		$ok = 0;
		}
	else {
		$state{'domain_created'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 3: Generate DKIM key on remote server (non-fatal)
if ($ok) {
	&$virtual_server::first_print($text{'setup_dkim'});
	my ($out, $exit) = &remote_virtualmin_cmd($server_id,
		"modify-mail",
		"--domain", $d->{'dom'}, "--generate-dkim-key");
	if (!$exit) {
		$state{'dkim_configured'} = 1;
		$d->{'remote_mail_dkim_enabled'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	else {
		&$virtual_server::second_print(
			&text('setup_edkim', $out));
		# DKIM failure is non-fatal
		}
	}

# Step 4: DNS records on vh1 (MX, SPF, DMARC, autoconfig)
if ($ok) {
	&$virtual_server::first_print($text{'setup_dns'});
	$err = &setup_remote_mail_dns($d, $server);
	if ($err) {
		&$virtual_server::second_print(&text('setup_edns', $err));
		$ok = 0;
		}
	else {
		$state{'dns_configured'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 5: DKIM DNS record on vh1 (needs key from email1)
if ($ok && $state{'dkim_configured'}) {
	my $selector = $server->{'dkim_selector'} || '202307';
	my $pubkey = &get_remote_dkim_public_key(
		$server_id, $d->{'dom'}, $selector);
	if ($pubkey) {
		$err = &setup_dkim_dns_record($d, $selector, $pubkey);
		# DKIM DNS failure is non-fatal
		}
	}

# Step 6: SSL certificate sync (non-fatal)
if ($ok) {
	&$virtual_server::first_print($text{'setup_ssl'});
	$err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_essl', $err));
		}
	else {
		$state{'ssl_synced'} = 1;
		$d->{'remote_mail_ssl_synced'} = time();
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Save state
if ($ok) {
	$d->{'remote_mail_server'} = $server_id;
	&save_domain_state($d->{'dom'}, \%state);
	}
else {
	# Rollback completed steps
	&rollback_setup($d, $server_id, \%state);
	}

&release_lock_remote_mail();
return $ok;
}

# feature_delete(&domain)
# Called when this feature is disabled or the domain is being deleted.
# Deletes the domain on the remote mail server and cleans up DNS on vh1.
sub feature_delete
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $server = &get_remote_mail_server($server_id);

&obtain_lock_remote_mail($d);

# Remove domain on remote mail server via Virtualmin API
# This handles: all users, Postfix, Dovecot, DKIM, SpamAssassin, etc.
if ($server_id) {
	&$virtual_server::first_print($text{'delete_domain'});
	my ($out, $exit) = &remote_virtualmin_cmd($server_id,
		"delete-domain", "--domain", $d->{'dom'});
	if ($exit) {
		&$virtual_server::second_print(
			&text('delete_edomain', $out));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove DNS records on vh1
&$virtual_server::first_print($text{'delete_dns'});
my $err = &delete_remote_mail_dns($d, $server);
if ($err) {
	&$virtual_server::second_print(&text('delete_edns', $err));
	}
else {
	&$virtual_server::second_print(
		$virtual_server::text{'setup_done'});
	}

# Clean up state
&delete_domain_state($d->{'dom'});
delete $d->{'remote_mail_server'};
delete $d->{'remote_mail_ssl_synced'};
delete $d->{'remote_mail_dkim_enabled'};
delete $d->{'remote_mail_spam_gateway'};
delete $d->{'remote_mail_spam_gateway_host'};
delete $d->{'remote_mail_outgoing_relay'};
delete $d->{'remote_mail_outgoing_relay_port'};

&release_lock_remote_mail();
return 1;
}

# feature_modify(&domain, &olddomain)
# Called when a domain with this feature is modified (e.g., renamed),
# when domain settings change (including mail routing overrides), or when
# SSL certificates are updated (install-cert, Let's Encrypt renewal).
sub feature_modify
{
my ($d, $oldd) = @_;
my $renamed = ($d->{'dom'} ne $oldd->{'dom'});

# Check if any mail routing overrides changed
my $overrides_changed = 0;
foreach my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
	my $dk = "remote_mail_${key}";
	my $new_val = $d->{$dk} || '';
	my $old_val = $oldd->{$dk} || '';
	if ($new_val ne $old_val) {
		$overrides_changed = 1;
		last;
		}
	}

# Check if SSL certificate changed (triggered by install-cert,
# generate-letsencrypt-cert, etc. which call feature_modify for all plugins)
my $ssl_changed = 0;
if ($d->{'ssl_cert'} && $oldd->{'ssl_cert'}) {
	$ssl_changed = ($d->{'ssl_cert'} ne $oldd->{'ssl_cert'} ||
	                $d->{'ssl_key'} ne $oldd->{'ssl_key'});
	}
elsif ($d->{'ssl_cert'} && !$oldd->{'ssl_cert'}) {
	$ssl_changed = 1;
	}

if ($renamed || $overrides_changed) {
	&$virtual_server::first_print(
		$renamed ? $text{'modify_domain'} : $text{'modify_overrides'});
	my $server_id = &get_domain_mail_server($d);
	my $server = &get_remote_mail_server($server_id);

	&obtain_lock_remote_mail($d);

	my $err;

	# On rename, tell email1's Virtualmin to rename the domain
	if ($renamed && $server_id) {
		($err) = _modify_err(&remote_virtualmin_cmd($server_id,
			"modify-domain",
			"--domain", $oldd->{'dom'},
			"--newdomain", $d->{'dom'}));
		}

	# Update DNS records on vh1 — delete with old config, create with new
	if (!$err) {
		$err = &delete_remote_mail_dns($oldd, $server);
		}
	if (!$err) {
		$err = &setup_remote_mail_dns($d, $server);
		}

	# Move/update state file
	&delete_domain_state($oldd->{'dom'}) if ($renamed);
	my %state = ( 'server_id' => $server_id,
	              'setup_time' => time(),
	              'domain_created' => 1,
	              'dns_configured' => 1,
	              'dkim_configured' => $d->{'remote_mail_dkim_enabled'} || 0 );
	&save_domain_state($d->{'dom'}, \%state);

	&release_lock_remote_mail();

	if ($err) {
		&$virtual_server::second_print(&text('modify_err', $err));
		return 0;
		}
	&$virtual_server::second_print($virtual_server::text{'setup_done'});
	}

# Re-sync SSL to remote mail server when cert changes
if ($ssl_changed) {
	&$virtual_server::first_print($text{'modify_ssl'});
	my $server_id = &get_domain_mail_server($d);
	my $err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			&text('modify_essl', $err));
		}
	else {
		$d->{'remote_mail_ssl_synced'} = time();
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

return 1;
}

# _modify_err($output, $exit)
# Helper to convert remote_virtualmin_cmd return to error string or undef.
sub _modify_err
{
my ($out, $exit) = @_;
return $exit ? $out : undef;
}

# feature_disable(&domain)
# Called when the domain is being disabled (suspended).
# Tells email1's Virtualmin to disable the domain.
sub feature_disable
{
my ($d) = @_;
&$virtual_server::first_print($text{'disable_mail'});
my $server_id = &get_domain_mail_server($d);

my ($out, $exit) = &remote_virtualmin_cmd($server_id,
	"disable-domain", "--domain", $d->{'dom'});
if ($exit) {
	&$virtual_server::second_print(&text('disable_err', $out));
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_enable(&domain)
# Called when the domain is being re-enabled (unsuspended).
# Tells email1's Virtualmin to enable the domain.
sub feature_enable
{
my ($d) = @_;
&$virtual_server::first_print($text{'enable_mail'});
my $server_id = &get_domain_mail_server($d);

my ($out, $exit) = &remote_virtualmin_cmd($server_id,
	"enable-domain", "--domain", $d->{'dom'});
if ($exit) {
	&$virtual_server::second_print(&text('enable_err', $out));
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_validate(&domain)
# Verify remote config matches expected state
sub feature_validate
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $state = &get_domain_state($d->{'dom'});
if (!$state || !$state->{'server_id'}) {
	return $text{'validate_enostate'};
	}
# Check that we have DNS records
if (!$state->{'dns_configured'}) {
	return $text{'validate_enodns'};
	}
# Check that domain was created on remote server
if (!$state->{'domain_created'}) {
	return $text{'validate_enodomain'};
	}
return undef;
}

# feature_links(&domain)
# Returns links to module pages for this domain
sub feature_links
{
my ($d) = @_;
return ( { 'mod' => $module_name,
           'desc' => $text{'links_link'},
           'page' => 'edit_domain.cgi?dom='.$d->{'dom'},
           'cat' => 'server',
         } );
}

# feature_inputs_show()
# Always show feature inputs
sub feature_inputs_show
{
return 1;
}

# feature_inputs([&domain])
# Returns form fields for choosing the remote mail server
sub feature_inputs
{
my ($d) = @_;
my @servers = &list_remote_mail_servers();
return '' if (!@servers);

my @opts;
foreach my $id (@servers) {
	my $s = &get_remote_mail_server($id);
	push(@opts, [ $id, $s->{'desc'} || $s->{'host'} ]);
	}
my $default = $d ? $d->{'remote_mail_server'} :
              &get_default_remote_mail_server();
my $rv = &ui_table_row($text{'feat_server'},
	&ui_select($input_name."_server", $default, \@opts));

# Per-domain mail routing overrides (blank = use server default)
my $cur_server = $d && $d->{'remote_mail_server'}
    ? &get_remote_mail_server($d->{'remote_mail_server'}) : undef;
foreach my $f ([ 'spam_gateway', $text{'feat_ovr_spam_gateway'} ],
               [ 'spam_gateway_host', $text{'feat_ovr_spam_gateway_host'} ],
               [ 'outgoing_relay', $text{'feat_ovr_outgoing_relay'} ],
               [ 'outgoing_relay_port', $text{'feat_ovr_outgoing_relay_port'} ]) {
	my ($key, $label) = @$f;
	my $dk = "remote_mail_${key}";
	my $val = $d ? ($d->{$dk} || '') : '';
	my $placeholder = $cur_server ? $cur_server->{$key} || '' : '';
	$rv .= &ui_table_row($label,
		&ui_textbox($input_name."_ovr_${key}", $val, 30).
		($placeholder ne '' ? " <i>($text{'feat_ovr_default'}: ".&html_escape($placeholder).")</i>" : ''));
	}

return $rv;
}

# feature_inputs_parse(&domain, &in)
# Parse the server selection input and per-domain override fields
sub feature_inputs_parse
{
my ($d, $in) = @_;
if (defined($in->{$input_name."_server"})) {
	my $id = $in->{$input_name."_server"};
	my $s = &get_remote_mail_server($id);
	if (!$s) {
		return $text{'feat_eserver'};
		}
	$d->{'remote_mail_server'} = $id;
	}

# Per-domain mail routing overrides
foreach my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
	my $field = $input_name."_ovr_${key}";
	if (defined($in->{$field})) {
		my $val = $in->{$field};
		$val =~ s/^\s+|\s+$//g;
		my $err = &validate_mail_override($key, $val);
		return $err if ($err);
		$d->{"remote_mail_${key}"} = $val;
		}
	}

return undef;
}

# feature_args(&domain)
# CLI argument definitions
sub feature_args
{
return ( { 'name' => $module_name."-server",
           'value' => 'server-id',
           'opt' => 1,
           'desc' => 'Remote mail server ID' },
         { 'name' => $module_name."-spam-gateway",
           'value' => 'ip',
           'opt' => 1,
           'desc' => 'Override spam gateway IP (blank = server default)' },
         { 'name' => $module_name."-spam-gateway-host",
           'value' => 'prefix',
           'opt' => 1,
           'desc' => 'Override spam gateway hostname prefix (blank = server default)' },
         { 'name' => $module_name."-outgoing-relay",
           'value' => 'host',
           'opt' => 1,
           'desc' => 'Override outgoing relay server (blank = server default)' },
         { 'name' => $module_name."-outgoing-relay-port",
           'value' => 'port',
           'opt' => 1,
           'desc' => 'Override outgoing relay port (blank = server default)' },
       );
}

# feature_args_parse(&domain, &args)
# Parse CLI arguments including per-domain mail routing overrides
sub feature_args_parse
{
my ($d, $args) = @_;
if (defined($args->{$module_name."-server"})) {
	my $id = $args->{$module_name."-server"};
	my $s = &get_remote_mail_server($id);
	if (!$s) {
		return "Invalid remote mail server ID: $id";
		}
	$d->{'remote_mail_server'} = $id;
	}

# Per-domain mail routing overrides
my %cli_map = (
	"-spam-gateway"       => "spam_gateway",
	"-spam-gateway-host"  => "spam_gateway_host",
	"-outgoing-relay"     => "outgoing_relay",
	"-outgoing-relay-port" => "outgoing_relay_port",
);
foreach my $arg (keys %cli_map) {
	my $full = $module_name . $arg;
	if (defined($args->{$full})) {
		my $val = $args->{$full};
		my $err = &validate_mail_override($cli_map{$arg}, $val);
		return $err if ($err);
		$d->{"remote_mail_".$cli_map{$arg}} = $val;
		}
	}

return undef;
}

# feature_import(domain-name, user-name, db-name)
# Check if this feature is already enabled for an imported domain
sub feature_import
{
my ($dname, $user, $db) = @_;
my $state = &get_domain_state($dname);
return ($state && $state->{'server_id'}) ? 1 : 0;
}

# feature_webmin(&main-domain, &all-domains)
# Returns Webmin module ACLs for the domain owner
sub feature_webmin
{
my @doms = map { $_->{'dom'} } grep { $_->{$module_name} } @{$_[1]};
if (@doms) {
	return ( [ $module_name,
	           { 'dom' => join(" ", @doms),
	             'noconfig' => 1 } ] );
	}
return ();
}

# feature_modules()
sub feature_modules
{
return ( [ $module_name, $text{'feat_module'} ] );
}

# feature_backup(&domain, file, &opts, &all-opts)
# Backup domain mail state
sub feature_backup
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'backup_conf'});
my $state = &get_domain_state($d->{'dom'});
if ($state) {
	&virtual_server::write_as_domain_user($d,
		sub { &write_file($file, $state) });
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_restore(&domain, file, &opts, &all-opts)
# Restore domain mail state
sub feature_restore
{
my ($d, $file) = @_;
&$virtual_server::first_print($text{'restore_conf'});
&obtain_lock_remote_mail($d);
my %state;
&read_file($file, \%state);
&save_domain_state($d->{'dom'}, \%state);
&release_lock_remote_mail();
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_backup_name()
sub feature_backup_name
{
return $text{'backup_name'};
}

# template_input(&template)
# Template settings for default remote mail server
sub template_input
{
my ($tmpl) = @_;
my $v = $tmpl->{$module_name."server"};
$v = "none" if (!defined($v) && $tmpl->{'default'});

my @servers = &list_remote_mail_servers();
my @opts = ( [ 'none', $text{'tmpl_none'} ] );
foreach my $id (@servers) {
	my $s = &get_remote_mail_server($id);
	push(@opts, [ $id, $s->{'desc'} || $s->{'host'} ]);
	}

my $rv = &ui_table_row($text{'tmpl_server'},
	&ui_radio($input_name."_mode",
		$v eq "" ? 0 : $v eq "none" ? 1 : 2,
		[ $tmpl->{'default'} ? () : ( [ 0, $text{'default'} ] ),
		  [ 1, $text{'tmpl_none'} ],
		  [ 2, $text{'tmpl_server_sel'} ] ])."\n".
	&ui_select($input_name."_server", $v, \@opts));
return $rv;
}

# template_parse(&template, &in)
sub template_parse
{
my ($tmpl, $in) = @_;
if ($in->{$input_name.'_mode'} == 0) {
	$tmpl->{$module_name."server"} = "";
	}
elsif ($in->{$input_name.'_mode'} == 1) {
	$tmpl->{$module_name."server"} = "none";
	}
else {
	$tmpl->{$module_name."server"} = $in->{$input_name."_server"};
	}
}

# ---- DNS Record Management (on vh1) ----

# setup_remote_mail_dns(&domain, \%server)
# Creates DNS records: MX, A for mail hosts, SPF TXT, and autoconfig CNAME.
# Uses Virtualmin's DNS API. Merges per-domain overrides with server config.
sub setup_remote_mail_dns
{
my ($d, $server) = @_;
return "No DNS zone for domain" if (!$d->{'dns'});

# Merge domain overrides with server defaults
$server = &get_effective_mail_config($d, $server);

# Resolve server host to IP for A records and SPF
my $host_ip = &resolve_to_ip($server->{'host'});
$server = { %$server, 'host' => $host_ip };

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	if (!$file) {
		die "Could not get DNS zone file for $d->{'dom'}";
		}

	# Remove any existing MX records for the bare domain
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'MX' &&
		    ($r->{'name'} eq $d->{'dom'}.'.' ||
		     $r->{'name'} eq $d->{'dom'})) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	# Add MX and A records from builder
	my @mx_recs = &build_mx_records($d->{'dom'}, $server);
	foreach my $rec (@mx_recs) {
		my %dns = ( 'name'  => $rec->{'name'}.'.',
		            'type'  => $rec->{'type'},
		            'values' => [ $rec->{'value'} ] );
		if ($rec->{'type'} eq 'MX') {
			$dns{'values'} = [ $rec->{'priority'},
			                   $rec->{'value'}.'.' ];
			}
		&virtual_server::create_dns_record($recs, $file, \%dns);
		}

	# SPF record
	my @ip4 = ( $server->{'host'} );
	push(@ip4, $server->{'spam_gateway'}) if ($server->{'spam_gateway'});
	my $spf_value = &build_spf_record({
		ip4     => \@ip4,
		include => ['_spf.trinsiklabs.com'],
		all     => '~all',
		});

	# Remove existing SPF TXT records
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq $d->{'dom'}.'.' ||
		     $r->{'name'} eq $d->{'dom'}) &&
		    join(' ', @{$r->{'values'}}) =~ /v=spf1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => $d->{'dom'}.'.',
		  'type' => 'TXT',
		  'values' => [ "\"$spf_value\"" ] });

	# DMARC record
	my ($dmarc_name, $dmarc_value) = &build_dmarc_record($d->{'dom'}, {
		p => 'none',
		});

	# Remove existing DMARC
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq $dmarc_name.'.' ||
		     $r->{'name'} eq $dmarc_name) &&
		    join(' ', @{$r->{'values'}}) =~ /v=DMARC1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => $dmarc_name.'.',
		  'type' => 'TXT',
		  'values' => [ "\"$dmarc_value\"" ] });

	# Autoconfig/autodiscover CNAME for mail clients
	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => "autoconfig.$d->{'dom'}.",
		  'type' => 'CNAME',
		  'values' => [ "mail.$d->{'dom'}." ] });

	# Bump SOA serial and schedule BIND reload
	if (defined(&virtual_server::post_records_change)) {
		&virtual_server::post_records_change($d, $recs, $file);
		}
	else {
		&virtual_server::register_post_action(
			\&virtual_server::restart_bind);
		}

	if (defined(&virtual_server::release_lock_dns)) {
		&virtual_server::release_lock_dns($d, 1);
		}
	};

return $@ ? "$@" : undef;
}

# setup_dkim_dns_record(&domain, $selector, $pubkey)
# Creates DKIM TXT record on vh1's DNS. The DKIM key is generated on email1
# by Virtualmin; this function only creates the corresponding DNS record.
sub setup_dkim_dns_record
{
my ($d, $selector, $pubkey) = @_;
return undef if (!$d->{'dns'} || !$pubkey);

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	return undef if (!$file);

	my ($dkim_name, $dkim_value) = &build_dkim_record(
		$d->{'dom'}, $selector, $pubkey);

	# Remove existing DKIM records for this selector
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    $r->{'name'} =~ /\._domainkey\.\Q$d->{'dom'}\E\.?$/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => "${dkim_name}.",
		  'type' => 'TXT',
		  'values' => [ "\"$dkim_value\"" ] });

	if (defined(&virtual_server::post_records_change)) {
		&virtual_server::post_records_change($d, $recs, $file);
		}
	else {
		&virtual_server::register_post_action(
			\&virtual_server::restart_bind);
		}

	if (defined(&virtual_server::release_lock_dns)) {
		&virtual_server::release_lock_dns($d, 1);
		}
	};

return $@ ? "$@" : undef;
}

# get_remote_dkim_public_key($server_id, $domain, $selector)
# Fetches the DKIM public key from the remote mail server.
sub get_remote_dkim_public_key
{
my ($server_id, $domain, $selector) = @_;
$selector ||= '202307';
my $keyfile = "/etc/opendkim/keys/${domain}/${selector}.txt";

my ($out, $exit) = &remote_mail_cmd($server_id, "cat ${keyfile} 2>/dev/null");
if ($exit != 0 || !$out) {
	return undef;
	}

# Extract the public key from the TXT record file
# Format: selector._domainkey IN TXT ( "v=DKIM1; k=rsa; " "p=MIIBi..." )
my $pubkey = '';
if ($out =~ /p=([A-Za-z0-9+\/=\s"]+)/) {
	$pubkey = $1;
	$pubkey =~ s/[")\s]//g;
	}
return $pubkey;
}

# delete_remote_mail_dns(&domain, \%server)
# Removes all DNS records added by setup_remote_mail_dns
sub delete_remote_mail_dns
{
my ($d, $server) = @_;
return undef if (!$d->{'dns'});

# Merge domain overrides with server defaults
$server = &get_effective_mail_config($d, $server) if ($server);

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	return undef if (!$file);

	my $dom = $d->{'dom'};

	# Collect names we manage
	my @managed_a = ("mail.${dom}.", "autoconfig.${dom}.");
	if ($server && $server->{'spam_gateway_host'}) {
		push(@managed_a,
		     ($server->{'spam_gateway_host'} || 'mg').".${dom}.");
		}

	# Delete records in reverse to avoid index shifting
	for (my $i = $#$recs; $i >= 0; $i--) {
		my $r = $recs->[$i];

		# MX for bare domain
		if ($r->{'type'} eq 'MX' &&
		    ($r->{'name'} eq "${dom}." || $r->{'name'} eq $dom)) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# A records for mail hosts we created
		if ($r->{'type'} eq 'A' &&
		    grep { $r->{'name'} eq $_ } @managed_a) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# CNAME for autoconfig
		if ($r->{'type'} eq 'CNAME' &&
		    $r->{'name'} eq "autoconfig.${dom}.") {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# SPF TXT
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq "${dom}." || $r->{'name'} eq $dom) &&
		    join(' ', @{$r->{'values'}}) =~ /v=spf1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# DMARC TXT
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq "_dmarc.${dom}." ||
		     $r->{'name'} eq "_dmarc.${dom}") &&
		    join(' ', @{$r->{'values'}}) =~ /v=DMARC1/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}

		# DKIM TXT (selector._domainkey)
		if ($r->{'type'} eq 'TXT' &&
		    $r->{'name'} =~ /\._domainkey\.\Q${dom}\E\.?$/) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			next;
			}
		}

	if (defined(&virtual_server::post_records_change)) {
		&virtual_server::post_records_change($d, $recs, $file);
		}
	else {
		&virtual_server::register_post_action(
			\&virtual_server::restart_bind);
		}

	if (defined(&virtual_server::release_lock_dns)) {
		&virtual_server::release_lock_dns($d, 1);
		}
	};

return $@ ? "$@" : undef;
}

# ---- SSL Certificate Sync ----

# sync_remote_mail_ssl(&domain, $server_id)
# Syncs SSL certificates from vh1 to the remote mail server using Virtualmin's
# install-cert CLI and sync_dovecot_ssl_cert / sync_postfix_ssl_cert functions.
# This leverages the same mechanisms Virtualmin uses for locally-hosted domains.
sub sync_remote_mail_ssl
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $server = &get_remote_mail_server($server_id);
return "Server not found" if (!$server);

eval {
	my $cert = $d->{'ssl_cert'} || "/home/${dom}/ssl.cert";
	my $key  = $d->{'ssl_key'}  || "/home/${dom}/ssl.key";
	my $ca   = $d->{'ssl_chain'} || $d->{'ssl_ca'};

	if (! -r $cert) {
		die "SSL certificate not found at $cert";
		}
	if (! -r $key) {
		die "SSL key not found at $key";
		}

	# Push cert files to a temp directory on the remote server
	my $tmp = "/tmp/.ssl-sync-$$-" . time();
	my ($out, $exit) = &remote_mail_cmd($server_id,
		"mkdir -p ${tmp} && chmod 700 ${tmp}");
	if ($exit != 0) {
		die "Failed to create temp directory: $out";
		}

	&remote_mail_write($server_id, $cert, "${tmp}/cert.pem");
	&remote_mail_write($server_id, $key, "${tmp}/key.pem");

	# Build install-cert args
	my @args = ("--domain", $dom,
		    "--cert", "${tmp}/cert.pem",
		    "--key", "${tmp}/key.pem");
	if ($ca && -r $ca) {
		&remote_mail_write($server_id, $ca, "${tmp}/ca.pem");
		push(@args, "--ca", "${tmp}/ca.pem");
		}

	# Use Virtualmin's install-cert to store certs in standard paths
	# (/home/{dom}/ssl/, ssl.combined) and register with domain config
	($out, $exit) = &remote_virtualmin_cmd($server_id,
		"install-cert", @args);
	if ($exit != 0) {
		&remote_mail_cmd($server_id, "rm -rf ${tmp}");
		die "install-cert failed: $out";
		}

	# Apply cert to Dovecot and Postfix via Virtualmin API functions
	my $sync_err = &_sync_remote_service_ssl($server_id, $dom);
	if ($sync_err) {
		&remote_mail_cmd($server_id, "rm -rf ${tmp}");
		die $sync_err;
		}

	# Clean up temp files
	&remote_mail_cmd($server_id, "rm -rf ${tmp}");
	};

return $@ ? "$@" : undef;
}

# _sync_remote_service_ssl($server_id, $domain_name)
# Calls sync_dovecot_ssl_cert and sync_postfix_ssl_cert on the remote server
# via Webmin RPC to update Dovecot SNI blocks and Postfix SNI map entries.
# Returns undef on success, error string on failure.
sub _sync_remote_service_ssl
{
my ($server_id, $dom) = @_;

eval {
	# Get the domain hash from the remote server's Virtualmin
	my $d_remote = &remote_mail_call($server_id,
		'virtual-server', 'get_domain_by', 'dom', $dom);
	if (!$d_remote || !$d_remote->{'id'}) {
		die "Domain $dom not found on remote server";
		}

	# Call Virtualmin's sync functions to update Dovecot and Postfix
	&remote_mail_call($server_id,
		'virtual-server', 'sync_dovecot_ssl_cert', $d_remote, 1);
	&remote_mail_call($server_id,
		'virtual-server', 'sync_postfix_ssl_cert', $d_remote, 1);
	};

return $@ ? "$@" : undef;
}

# ---- Disk Usage ----

# get_remote_disk_usage(&domain, $server_id)
# Returns disk usage in bytes for the domain's mail directory on the remote server.
sub get_remote_disk_usage
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $cache_file = "$domains_dir/${dom}.du";
my $cache_ttl = $config{'disk_usage_cache'} || 3600;

if (-r $cache_file) {
	my @stat = stat($cache_file);
	if (time() - $stat[9] < $cache_ttl) {
		open(my $fh, '<', $cache_file);
		my $bytes = <$fh>;
		close($fh);
		chomp($bytes);
		return $bytes if ($bytes =~ /^\d+$/);
		}
	}

my ($out, $exit) = &remote_mail_cmd($server_id,
	"du -sb /home/${dom} 2>/dev/null | cut -f1");
my $bytes = 0;
if ($exit == 0 && $out =~ /^(\d+)/) {
	$bytes = $1;
	}

if (! -d $domains_dir) {
	&make_dir($domains_dir, 0700);
	}
open(my $fh, '>', $cache_file);
print $fh "$bytes\n";
close($fh);

return $bytes;
}

# ---- Rollback ----

# rollback_setup(&domain, $server_id, \%state)
# Rolls back partially completed setup steps
sub rollback_setup
{
my ($d, $server_id, $state) = @_;

# Delete the domain on email1 if it was created
if ($state->{'domain_created'}) {
	eval {
		&remote_virtualmin_cmd($server_id,
			"delete-domain", "--domain", $d->{'dom'});
		};
	}

# Remove DNS records on vh1 if they were created
if ($state->{'dns_configured'}) {
	my $server = &get_remote_mail_server($server_id);
	eval { &delete_remote_mail_dns($d, $server) };
	}

&delete_domain_state($d->{'dom'});
}

# ---- Plugin User Management ----

# list_plugin_users(&domain)
# Returns a list of remote mail user hashes for display in Virtualmin's
# users table. Uses Virtualmin's list-users API for full user data.
sub list_plugin_users
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
return () if (!$server_id);
my @user_data = eval { &list_remote_mail_users($d, $server_id) };
return () if ($@ || !@user_data);
my @users;
foreach my $u (@user_data) {
	my $localpart = $u->{'user'} || $u->{'_name'};
	my $email = $u->{'_name'};
	push(@users, {
		'user' => $email,
		'email' => $u->{'email_address'} || $email,
		'real' => $u->{'real_name'} || $text{'feat_remote_user_type'},
		'extra' => 1,
		'type' => $module_name,
		'plugin' => $module_name,
		'noquota' => 1,
		'noprimary' => 1,
		'noextra' => 1,
		'noalias' => 1,
		'nocreatehome' => 1,
		'nomailfile' => 1,
		'edit_url' => "/$module_name/edit_user.cgi?dom=".
			      &urlize($d->{'dom'}).
			      "&user=".&urlize($localpart),
		'dom' => $d,
		});
	}
return @users;
}

# users_create_links(&domain)
# Returns links for the "Add" buttons on the users listing page.
sub users_create_links
{
my ($d) = @_;
return ([ "/$module_name/edit_user.cgi?dom=".&urlize($d->{'dom'}),
	  $text{'feat_add_user'} ]);
}

1;
