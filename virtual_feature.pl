# virtual_feature.pl
# Virtualmin feature hooks for the Remote Mail Server plugin.
# This file is loaded by Virtualmin to register the plugin as a domain feature.

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
# Provisions DNS records on vh1 and mail services on the remote server.
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

# Step 2: DNS records (MX, SPF, A records for mail hosts)
&$virtual_server::first_print($text{'setup_dns'});
$err = &setup_remote_mail_dns($d, $server);
if ($err) {
	&$virtual_server::second_print(&text('setup_edns', $err));
	$ok = 0;
	}
else {
	$state{'dns_configured'} = 1;
	&$virtual_server::second_print($virtual_server::text{'setup_done'});
	}

# Step 3: Postfix configuration on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_postfix'});
	$err = &setup_remote_postfix($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_epostfix', $err));
		$ok = 0;
		}
	else {
		$state{'postfix_configured'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 4: Dovecot user on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_dovecot'});
	$err = &setup_remote_dovecot($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_edovecot', $err));
		$ok = 0;
		}
	else {
		$state{'dovecot_configured'} = 1;
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 5: DKIM on remote server
if ($ok) {
	&$virtual_server::first_print($text{'setup_dkim'});
	$err = &setup_remote_dkim($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_edkim', $err));
		# DKIM failure is non-fatal
		}
	else {
		$state{'dkim_configured'} = 1;
		$d->{'remote_mail_dkim_enabled'} = 1;

		# Add DKIM TXT record to DNS (key was just generated on remote)
		my $dkim_err = &add_dkim_dns_record($d, $server_id, $server);
		if ($dkim_err) {
			&$virtual_server::second_print(
				&text('setup_edkim_dns', $dkim_err));
			}
		else {
			&$virtual_server::second_print(
				$virtual_server::text{'setup_done'});
			}
		}
	}

# Step 6: SSL certificate sync
if ($ok) {
	&$virtual_server::first_print($text{'setup_ssl'});
	$err = &sync_remote_mail_ssl($d, $server_id);
	if ($err) {
		&$virtual_server::second_print(
			&text('setup_essl', $err));
		# SSL failure is non-fatal
		}
	else {
		$state{'ssl_synced'} = 1;
		$d->{'remote_mail_ssl_synced'} = time();
		$d->{'remote_mail_ssl_fp'} =
			&get_ssl_cert_fingerprint($d->{'ssl_cert'});
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Step 7: Ensure certbot deploy hook is installed on the remote server.
# This hook rebuilds the Postfix SNI map (with postmap -F) whenever certbot
# on the mail server renews any certificate. Without it, renewed certs are
# written to disk but the SNI map retains stale base64-encoded cert data.
if ($ok) {
	if (!&check_remote_certbot_hook($server_id)) {
		&$virtual_server::first_print($text{'setup_hook'});
		$err = &deploy_remote_certbot_hook($server_id);
		if ($err) {
			&$virtual_server::second_print(
				&text('setup_ehook', $err));
			# Hook failure is non-fatal
			}
		else {
			$state{'certbot_hook_deployed'} = 1;
			&$virtual_server::second_print(
				$virtual_server::text{'setup_done'});
			}
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
# Tears down all remote mail configuration.
sub feature_delete
{
my ($d) = @_;
my $server_id = &get_domain_mail_server($d);
my $server = &get_remote_mail_server($server_id);

&obtain_lock_remote_mail($d);

# Remove DKIM on remote
if ($d->{'remote_mail_dkim_enabled'} && $server) {
	&$virtual_server::first_print($text{'delete_dkim'});
	my $err = &delete_remote_dkim($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_edkim', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove Dovecot user on remote
if ($server) {
	&$virtual_server::first_print($text{'delete_dovecot'});
	my $err = &delete_remote_dovecot($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_edovecot', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove Postfix config on remote
if ($server) {
	&$virtual_server::first_print($text{'delete_postfix'});
	my $err = &delete_remote_postfix($d, $server_id, $server);
	if ($err) {
		&$virtual_server::second_print(
			&text('delete_epostfix', $err));
		}
	else {
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}

# Remove DNS records
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
# Called when a domain with this feature is modified (e.g., renamed)
# or when domain settings change (including mail routing overrides).
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

# Check if SSL certificate changed.
# NOTE: Virtualmin's cert paths are stable across Let's Encrypt renewals --
# only the file *contents* change -- so comparing paths alone misses every
# renewal. Compare a fingerprint of the cert on disk against the one recorded
# at the last successful sync as well.
# Also note that install-cert.pl / generate-letsencrypt-cert.pl do NOT call
# feature_modify, so renewals are primarily handled by the certbot deploy hook
# at /etc/letsencrypt/renewal-hooks/deploy/sync-ssl-to-mail.sh. This block is a
# backstop for when feature_modify is invoked by other domain operations.
my $ssl_changed = 0;
if ($d->{'ssl_cert'} && $oldd->{'ssl_cert'}) {
	$ssl_changed = ($d->{'ssl_cert'} ne $oldd->{'ssl_cert'} ||
	                $d->{'ssl_key'} ne $oldd->{'ssl_key'});
	}
elsif ($d->{'ssl_cert'} && !$oldd->{'ssl_cert'}) {
	$ssl_changed = 1;
	}
my $ssl_fp;
if ($d->{'ssl_cert'}) {
	$ssl_fp = &get_ssl_cert_fingerprint($d->{'ssl_cert'});
	if (!$ssl_changed && $ssl_fp &&
	    $ssl_fp ne ($d->{'remote_mail_ssl_fp'} || '')) {
		$ssl_changed = 1;
		}
	}

if ($renamed || $overrides_changed) {
	&$virtual_server::first_print(
		$renamed ? $text{'modify_domain'} : $text{'modify_overrides'});
	my $server_id = &get_domain_mail_server($d);
	my $server = &get_remote_mail_server($server_id);

	&obtain_lock_remote_mail($d);

	# Update DNS records — delete with old config, create with new
	my $err = &delete_remote_mail_dns($oldd, $server);
	if (!$err) {
		$err = &setup_remote_mail_dns($d, $server);
		}

	# Update Postfix transports
	if (!$err && $server) {
		if ($renamed) {
			$err = &modify_remote_postfix($d, $oldd, $server_id, $server);
			}
		elsif ($overrides_changed) {
			# Delete with old domain hash, recreate with new
			$err = &delete_remote_postfix($oldd, $server_id, $server);
			$err = &setup_remote_postfix($d, $server_id, $server) if (!$err);
			}
		}

	# Update DKIM (only on rename — overrides don't affect DKIM)
	if (!$err && $renamed && $server && $d->{'remote_mail_dkim_enabled'}) {
		&delete_remote_dkim($oldd, $server_id, $server);
		$err = &setup_remote_dkim($d, $server_id, $server);
		}

	# Move/update state file
	&delete_domain_state($oldd->{'dom'}) if ($renamed);
	my %state = ( 'server_id' => $server_id,
	              'setup_time' => time(),
	              'dns_configured' => 1,
	              'postfix_configured' => 1,
	              'dovecot_configured' => 1,
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
		$d->{'remote_mail_ssl_fp'} = $ssl_fp if ($ssl_fp);
		&$virtual_server::second_print(
			$virtual_server::text{'setup_done'});
		}
	}
return 1;
}

# feature_disable(&domain)
# Called when the domain is being disabled (suspended)
sub feature_disable
{
my ($d) = @_;
&$virtual_server::first_print($text{'disable_mail'});
my $server_id = &get_domain_mail_server($d);

# Disable Postfix transport on remote (stops accepting mail)
my $err = &disable_remote_postfix($d, $server_id);
if ($err) {
	&$virtual_server::second_print(&text('disable_err', $err));
	return 0;
	}
&$virtual_server::second_print($virtual_server::text{'setup_done'});
return 1;
}

# feature_enable(&domain)
# Called when the domain is being re-enabled (unsuspended)
sub feature_enable
{
my ($d) = @_;
&$virtual_server::first_print($text{'enable_mail'});
my $server_id = &get_domain_mail_server($d);

# Re-enable Postfix transport on remote
my $err = &enable_remote_postfix($d, $server_id);
if ($err) {
	&$virtual_server::second_print(&text('enable_err', $err));
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
# Check Postfix
if (!$state->{'postfix_configured'}) {
	return $text{'validate_enopostfix'};
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

# ---- Stub functions for later phases ----
# These will be implemented in phases 3-8.

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

# modify_remote_mail_dns(&domain, &old_domain, \%server)
# Update DNS records when domain is renamed — delete old, create new
sub modify_remote_mail_dns
{
my ($d, $oldd, $server) = @_;
my $err = &delete_remote_mail_dns($oldd, $server);
return $err if ($err);
return &setup_remote_mail_dns($d, $server);
}

# ---- Phase 4: Remote Postfix Configuration ----

# setup_remote_postfix(&domain, $server_id, \%server)
# Configures Postfix on the remote server:
# - Adds domain to virtual_domains
# - Adds sender-dependent transport map entry for outgoing relay
# - Runs postmap and reloads Postfix
sub setup_remote_postfix
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

# Merge domain overrides with server defaults
$server = &get_effective_mail_config($d, $server);

eval {
	# Add to virtual_domains (hash map file)
	&remote_mail_ssh($server_id,
		"postconf -h virtual_mailbox_domains 2>/dev/null");

	# Add domain to virtual_mailbox_domains via hash file
	my $cmd = "grep -q '^\Q${dom}\E\\b' /etc/postfix/virtual_domains 2>/dev/null" .
	          " || echo '${dom} OK' >> /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add virtual domain: $out";
		}

	# Add sender-dependent transport map for outgoing relay
	if ($server->{'outgoing_relay'}) {
		my $relay = $server->{'outgoing_relay'};
		my $port = $server->{'outgoing_relay_port'} || 25;
		# Defense-in-depth: strip any shell-unsafe chars (validation
		# should have already rejected bad input, but belt-and-suspenders)
		$relay =~ s/[^a-zA-Z0-9.\-]//g;
		$port =~ s/[^0-9]//g;
		$port = 25 if (!$port);
		my $transport = "smtp:[${relay}]:${port}";
		$cmd = "grep -q '^\@\Q${dom}\E\\b' /etc/postfix/dependent 2>/dev/null" .
		       " || echo '\@${dom} ${transport}' >> /etc/postfix/dependent" .
		       " && postmap /etc/postfix/dependent";
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		if ($exit != 0) {
			die "Failed to add sender transport: $out";
			}
		}

	# Reload Postfix
	($out, $exit) = &remote_mail_ssh($server_id, "systemctl reload postfix");
	if ($exit != 0) {
		die "Failed to reload Postfix: $out";
		}
	};

return $@ ? "$@" : undef;
}

# delete_remote_postfix(&domain, $server_id, \%server)
# Removes Postfix configuration for a domain from the remote server
sub delete_remote_postfix
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	# Remove from virtual_domains
	my $cmd = "sed -i '/^\Q${dom}\E\\b/d' /etc/postfix/virtual_domains 2>/dev/null" .
	          " && postmap /etc/postfix/virtual_domains";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove from sender-dependent transport
	$cmd = "sed -i '/^\@\Q${dom}\E\\b/d' /etc/postfix/dependent 2>/dev/null" .
	       " && postmap /etc/postfix/dependent";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove any virtual_mailbox entries for the domain
	$cmd = "sed -i '/\@\Q${dom}\E\\b/d' /etc/postfix/virtual_mailbox 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_mailbox 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove virtual alias entries
	$cmd = "sed -i '/\@\Q${dom}\E\\b/d' /etc/postfix/virtual_alias 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_alias 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Reload
	($out, $exit) = &remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# modify_remote_postfix(&domain, &old_domain, $server_id, \%server)
# Updates Postfix config when domain is renamed
sub modify_remote_postfix
{
my ($d, $oldd, $server_id, $server) = @_;
my $err = &delete_remote_postfix($oldd, $server_id, $server);
return $err if ($err);
return &setup_remote_postfix($d, $server_id, $server);
}

# disable_remote_postfix(&domain, $server_id)
# Temporarily disables mail delivery by commenting out virtual_domains entry
sub disable_remote_postfix
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
eval {
	my $cmd = "sed -i 's/^\Q${dom}\E\\b/#DISABLED# ${dom}/' /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains" .
	          " && systemctl reload postfix";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to disable domain in Postfix: $out";
		}
	};
return $@ ? "$@" : undef;
}

# enable_remote_postfix(&domain, $server_id)
# Re-enables mail delivery by uncommenting virtual_domains entry
sub enable_remote_postfix
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
eval {
	my $cmd = "sed -i 's/^#DISABLED# \Q${dom}\E/${dom} OK/' /etc/postfix/virtual_domains" .
	          " && postmap /etc/postfix/virtual_domains" .
	          " && systemctl reload postfix";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to enable domain in Postfix: $out";
		}
	};
return $@ ? "$@" : undef;
}

# ---- Phase 5: Remote Dovecot / User Management ----

# setup_remote_dovecot(&domain, $server_id, \%server)
# Creates the domain's home directory and initial Maildir on the remote server
sub setup_remote_dovecot
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};
my $maildir = $server->{'maildir_format'} || '.maildir';

eval {
	# Create domain home and maildir
	my $home = "/home/${dom}";
	my $cmd = "mkdir -p ${home}/${maildir}/{cur,new,tmp}" .
	          " && chmod -R 700 ${home}/${maildir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to create maildir: $out";
		}
	};

return $@ ? "$@" : undef;
}

# delete_remote_dovecot(&domain, $server_id, \%server)
# Removes the domain's mail home from the remote server.
# Note: Does NOT delete data by default — renames to .deleted for safety.
sub delete_remote_dovecot
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	my $home = "/home/${dom}";
	my $ts = time();
	my $cmd = "[ -d ${home} ] && mv ${home} ${home}.deleted.${ts} || true";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to archive mail home: $out";
		}
	};

return $@ ? "$@" : undef;
}

# create_remote_mail_user(&domain, $server_id, $user, $password, \%opts)
# Creates a mailbox user on the remote server:
# - Adds virtual_mailbox entry
# - Creates Maildir
# - Sets password in Dovecot passwd file
sub create_remote_mail_user
{
my ($d, $server_id, $user, $password, $opts) = @_;
my $dom = $d->{'dom'};

# $user and $dom are interpolated into shell commands run as root on the mail
# server below. Validate both here so that interpolation cannot inject; do not
# assume the caller checked.
my $verr = &validate_mail_username($user);
return $verr if ($verr);
my $derr = &validate_domain_name($dom);
return $derr if ($derr);

my $email = "${user}\@${dom}";
my $server = &get_remote_mail_server($server_id);
my $maildir = $server->{'maildir_format'} || '.maildir';
my $home = "/home/${dom}";
my $userdir = "${home}/${maildir}/${user}";

eval {
	# Create user maildir
	my $cmd = "mkdir -p ${userdir}/{cur,new,tmp} && chmod -R 700 ${userdir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to create user maildir: $out";
		}

	# Add virtual_mailbox entry
	$cmd = "grep -q '^\Q${email}\E\\b' /etc/postfix/virtual_mailbox 2>/dev/null" .
	       " || echo '${email} ${dom}/${maildir}/${user}/' >> /etc/postfix/virtual_mailbox" .
	       " && postmap /etc/postfix/virtual_mailbox";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add virtual mailbox: $out";
		}

	# Generate password hash and add to Dovecot passwd file
	if ($password) {
		$cmd = "doveadm pw -s SSHA512 -p " . quotemeta($password);
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		chomp($out);
		if ($exit != 0) {
			die "Failed to generate password hash: $out";
			}
		my $hash = $out;

		# Append to passwd file (or update existing)
		$cmd = "grep -q '^\Q${email}\E:' /etc/dovecot/users 2>/dev/null" .
		       " && sed -i 's|^\Q${email}\E:.*|${email}:${hash}::::${userdir}|' /etc/dovecot/users" .
		       " || echo '${email}:${hash}::::${userdir}' >> /etc/dovecot/users";
		($out, $exit) = &remote_mail_ssh($server_id, $cmd);
		if ($exit != 0) {
			die "Failed to set user password: $out";
			}
		}

	# Reload Postfix to pick up virtual_mailbox changes
	&remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# delete_remote_mail_user(&domain, $server_id, $user)
# Removes a mailbox user from the remote server
sub delete_remote_mail_user
{
my ($d, $server_id, $user) = @_;
my $dom = $d->{'dom'};

# Same reasoning as create_remote_mail_user: these values reach a root shell.
my $verr = &validate_mail_username($user);
return $verr if ($verr);
my $derr = &validate_domain_name($dom);
return $derr if ($derr);

my $email = "${user}\@${dom}";

eval {
	# Remove from virtual_mailbox
	my $cmd = "sed -i '/^\Q${email}\E\\b/d' /etc/postfix/virtual_mailbox 2>/dev/null" .
	          " && postmap /etc/postfix/virtual_mailbox";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove from Dovecot passwd
	$cmd = "sed -i '/^\Q${email}\E:/d' /etc/dovecot/users 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove virtual alias entries for this user
	$cmd = "sed -i '/^\Q${email}\E\\b/d' /etc/postfix/virtual_alias 2>/dev/null" .
	       " && postmap /etc/postfix/virtual_alias 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	&remote_mail_ssh($server_id, "systemctl reload postfix");
	};

return $@ ? "$@" : undef;
}

# list_remote_mail_users(&domain, $server_id)
# Returns a list of mail users for the domain from the remote server
sub list_remote_mail_users
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my @users;

my ($out, $exit) = &remote_mail_ssh($server_id,
	"grep '\@\Q${dom}\E:' /etc/dovecot/users 2>/dev/null");
if ($exit == 0 && $out) {
	foreach my $line (split(/\n/, $out)) {
		if ($line =~ /^([^@]+)\@\Q${dom}\E:/) {
			push(@users, $1);
			}
		}
	}

return @users;
}

# ---- Phase 6: DKIM Integration ----

# setup_remote_dkim(&domain, $server_id, \%server)
# Configures OpenDKIM on the remote server for this domain:
# - Generates key pair if needed
# - Adds signing table and key table entries
# - Reloads OpenDKIM
sub setup_remote_dkim
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};
my $selector = $server->{'dkim_selector'} || '202307';

eval {
	my $keydir = "/etc/opendkim/keys/${dom}";

	# Create key directory and generate key if not exists
	my $cmd = "mkdir -p ${keydir}" .
	          " && [ -f ${keydir}/${selector}.private ] ||" .
	          " opendkim-genkey -s ${selector} -d ${dom} -D ${keydir}" .
	          " && chown -R opendkim:opendkim ${keydir}";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to generate DKIM key: $out";
		}

	# Add signing table entry
	$cmd = "grep -q '\Q${dom}\E' /etc/opendkim/signing.table 2>/dev/null" .
	       " || echo '*\@${dom} ${selector}._domainkey.${dom}'" .
	       " >> /etc/opendkim/signing.table";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add signing table entry: $out";
		}

	# Add key table entry
	$cmd = "grep -q '\Q${dom}\E' /etc/opendkim/key.table 2>/dev/null" .
	       " || echo '${selector}._domainkey.${dom} ${dom}:${selector}:${keydir}/${selector}.private'" .
	       " >> /etc/opendkim/key.table";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);
	if ($exit != 0) {
		die "Failed to add key table entry: $out";
		}

	# Reload OpenDKIM
	($out, $exit) = &remote_mail_ssh($server_id,
		"systemctl reload opendkim 2>/dev/null || systemctl restart opendkim");
	if ($exit != 0) {
		die "Failed to reload OpenDKIM: $out";
		}
	};

return $@ ? "$@" : undef;
}

# get_remote_dkim_public_key($server_id, $domain, $selector)
# Fetches the DKIM public key from the remote server
sub get_remote_dkim_public_key
{
my ($server_id, $domain, $selector) = @_;
$selector ||= '202307';
my $keyfile = "/etc/opendkim/keys/${domain}/${selector}.txt";

my ($out, $exit) = &remote_mail_ssh($server_id, "cat ${keyfile} 2>/dev/null");
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

# add_dkim_dns_record(&domain, $server_id, \%server)
# Fetches the DKIM public key from the remote server and adds the
# corresponding TXT record to the domain's DNS zone on this server.
# Called after setup_remote_dkim generates the key on the remote.
sub add_dkim_dns_record
{
my ($d, $server_id, $server) = @_;
return "No DNS zone for domain" if (!$d->{'dns'});

my $dom = $d->{'dom'};
my $selector = $server->{'dkim_selector'} || '202307';

# Fetch public key from remote
my $pubkey = &get_remote_dkim_public_key($server_id, $dom, $selector);
if (!$pubkey) {
	return "Could not retrieve DKIM public key from remote server";
	}

my ($dkim_name, $dkim_value) = &build_dkim_record($dom, $selector, $pubkey);

eval {
	if (defined(&virtual_server::obtain_lock_dns)) {
		&virtual_server::obtain_lock_dns($d, 1);
		}

	my ($recs, $file) = &virtual_server::get_domain_dns_records_and_file($d);
	if (!$file) {
		die "Could not get DNS zone file for $dom";
		}

	# Remove any existing DKIM records for this selector
	foreach my $r (@$recs) {
		if ($r->{'type'} eq 'TXT' &&
		    ($r->{'name'} eq "${dkim_name}." ||
		     $r->{'name'} eq $dkim_name)) {
			&virtual_server::delete_dns_record($recs, $file, $r);
			}
		}

	# Add the DKIM TXT record
	&virtual_server::create_dns_record($recs, $file,
		{ 'name' => "${dkim_name}.",
		  'type' => 'TXT',
		  'values' => [ "\"${dkim_value}\"" ] });

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

# delete_remote_dkim(&domain, $server_id, \%server)
# Removes OpenDKIM configuration for a domain
sub delete_remote_dkim
{
my ($d, $server_id, $server) = @_;
my $dom = $d->{'dom'};

eval {
	# Remove signing table entry
	my $cmd = "sed -i '/\Q${dom}\E/d' /etc/opendkim/signing.table 2>/dev/null";
	my ($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Remove key table entry
	$cmd = "sed -i '/\Q${dom}\E/d' /etc/opendkim/key.table 2>/dev/null";
	($out, $exit) = &remote_mail_ssh($server_id, $cmd);

	# Note: we keep the key files for potential reuse

	# Reload OpenDKIM
	($out, $exit) = &remote_mail_ssh($server_id,
		"systemctl reload opendkim 2>/dev/null || systemctl restart opendkim");
	};

return $@ ? "$@" : undef;
}

# ---- Phase 7: SSL Certificate Sync ----

# get_ssl_cert_fingerprint(file)
# Returns the SHA-256 fingerprint of an X.509 certificate, or undef if the
# file is missing or unreadable. Used to detect content-only cert changes
# (e.g. Let's Encrypt renewals) where the file path stays the same.
sub get_ssl_cert_fingerprint
{
my ($file) = @_;
return undef if (!$file || ! -r $file);
my $out = &backquote_command("openssl x509 -in ".quotemeta($file).
			     " -noout -fingerprint -sha256 2>/dev/null");
return undef if ($?);
return $out =~ /=\s*([0-9A-Fa-f:]+)/ ? $1 : undef;
}

# sync_remote_mail_ssl(&domain, $server_id)
# Syncs SSL certificates from vh1 to the remote mail server via SCP.
# Reloads Dovecot and Postfix on the remote server.
sub sync_remote_mail_ssl
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $server = &get_remote_mail_server($server_id);
return "Server not found" if (!$server);

eval {
	# Determine cert paths on vh1 (Virtualmin stores these in domain hash)
	my $cert = $d->{'ssl_cert'} || "/home/${dom}/ssl.cert";
	my $key  = $d->{'ssl_key'}  || "/home/${dom}/ssl.key";
	my $ca   = $d->{'ssl_chain'} || $d->{'ssl_ca'};

	# Verify cert exists locally
	if (! -r $cert) {
		die "SSL certificate not found at $cert";
		}
	if (! -r $key) {
		die "SSL key not found at $key";
		}

	my $ssh_host = $server->{'ssh_host'} || $server->{'host'};
	my $ssh_user = $server->{'ssh_user'} || 'root';
	my $ssh_key  = $server->{'ssh_key'};

	my @scp_opts = ('-o', 'StrictHostKeyChecking=no',
	                '-o', 'BatchMode=yes',
	                '-o', 'ConnectTimeout=10');
	push(@scp_opts, '-i', $ssh_key) if ($ssh_key);

	# Target: /home/{domain}/ssl/ — this is where the Postfix SNI map
	# entries point. Certs MUST go here, not /etc/ssl/mail/.
	my $remote_ssl = "/home/${dom}/ssl";
	my $dest = "${ssh_user}\@${ssh_host}";

	# Create remote directory
	my ($out, $exit) = &remote_mail_ssh($server_id,
		"mkdir -p ${remote_ssl}");
	if ($exit != 0) {
		die "Failed to create remote SSL directory: $out";
		}

	# SCP cert, key, and CA chain to per-domain ssl dir
	my $scp_base = "scp " . join(' ', map { quotemeta($_) } @scp_opts);
	$out = &backquote_command(
		"${scp_base} " . quotemeta($cert) .
		" ${dest}:${remote_ssl}/${dom}.crt 2>&1");
	if ($?) {
		die "Failed to copy certificate: $out";
		}

	$out = &backquote_command(
		"${scp_base} " . quotemeta($key) .
		" ${dest}:${remote_ssl}/${dom}.key 2>&1");
	if ($?) {
		die "Failed to copy private key: $out";
		}

	if ($ca && -r $ca) {
		$out = &backquote_command(
			"${scp_base} " . quotemeta($ca) .
			" ${dest}:${remote_ssl}/${dom}.ca 2>&1");
		}

	# Build ssl.combined: KEY + LEAF + CA (full chain required for Dovecot SNI
	# and modern mail clients like Apple Mail that strict-validate chain).
	# KEY must be first for Postfix smtpd_tls_chain_files compatibility.
	# If .ca is missing, falls back to key + crt (incomplete but functional).
	&remote_mail_ssh($server_id,
		"if [ -f ${remote_ssl}/${dom}.ca ]; then " .
		"  cat ${remote_ssl}/${dom}.key ${remote_ssl}/${dom}.crt ${remote_ssl}/${dom}.ca > /home/${dom}/ssl.combined; " .
		"else " .
		"  cat ${remote_ssl}/${dom}.key ${remote_ssl}/${dom}.crt > /home/${dom}/ssl.combined; " .
		"fi && " .
		"OWNER=\$(stat -c '%U:%G' /home/${dom} 2>/dev/null || echo root:root) && " .
		"chown \$OWNER ${remote_ssl}/${dom}.crt ${remote_ssl}/${dom}.key /home/${dom}/ssl.combined 2>/dev/null; " .
		"test -f ${remote_ssl}/${dom}.ca && chown \$OWNER ${remote_ssl}/${dom}.ca 2>/dev/null; " .
		"chmod 600 ${remote_ssl}/${dom}.key /home/${dom}/ssl.combined && " .
		"postmap -F hash:/etc/postfix/sni_map 2>/dev/null; " .
		"systemctl restart postfix 2>/dev/null; " .
		"systemctl restart dovecot 2>/dev/null");
	};

return $@ ? "$@" : undef;
}

# ---- Phase 8: Disk Usage ----

# get_remote_disk_usage(&domain, $server_id)
# Returns disk usage in bytes for the domain's mail directory on the remote server.
# Results are cached for the configured TTL.
sub get_remote_disk_usage
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};
my $cache_file = "$domains_dir/${dom}.du";
my $cache_ttl = $config{'disk_usage_cache'} || 3600;

# Check cache
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

# Fetch from remote
my ($out, $exit) = &remote_mail_ssh($server_id,
	"du -sb /home/${dom} 2>/dev/null | cut -f1");
my $bytes = 0;
if ($exit == 0 && $out =~ /^(\d+)/) {
	$bytes = $1;
	}

# Cache result
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
my $server = &get_remote_mail_server($server_id);

if ($state->{'dkim_configured'} && $server) {
	eval { &delete_remote_dkim($d, $server_id, $server) };
	}
if ($state->{'dovecot_configured'} && $server) {
	eval { &delete_remote_dovecot($d, $server_id, $server) };
	}
if ($state->{'postfix_configured'} && $server) {
	eval { &delete_remote_postfix($d, $server_id, $server) };
	}
if ($state->{'dns_configured'}) {
	eval { &delete_remote_mail_dns($d, $server) };
	}
&delete_domain_state($d->{'dom'});
}

1;
