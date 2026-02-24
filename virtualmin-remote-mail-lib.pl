# virtualmin-remote-mail-lib.pl
# Core library for the Virtualmin Remote Mail Server plugin.
# Handles server config CRUD, RPC/SSH wrappers, DNS builders, and state.

use strict;
use warnings;
use Socket;
our (%text, %config, %module_info);
our $module_name;
our $module_config_directory;

BEGIN { push(@INC, ".."); };
eval "use WebminCore;";
&init_config();
&foreign_require('virtual-server', 'virtual-server-lib.pl');
our %access = &get_module_acl();

# Directory for per-domain state files
our $domains_dir = "$module_config_directory/domains";

# Lock tracking
our $got_lock_remote_mail = 0;
our @got_lock_remote_mail_files;

# ---- Server Config CRUD ----

# list_remote_mail_servers()
# Returns a list of configured remote mail server IDs
sub list_remote_mail_servers
{
my @servers;
foreach my $k (keys %config) {
	if ($k =~ /^server_([a-zA-Z0-9]+)_host$/) {
		push(@servers, $1);
		}
	}
return sort @servers;
}

# get_remote_mail_server($id)
# Returns a hash ref with all config fields for the given server ID
sub get_remote_mail_server
{
my ($id) = @_;
return undef if (!defined $config{"server_${id}_host"});
my %server;
foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_(.+)$/) {
		$server{$1} = $config{$k};
		}
	}
$server{'id'} = $id;
return \%server;
}

# save_remote_mail_server($id, \%server)
# Saves server config fields. Removes old keys for this ID first, then
# writes new ones. Persists to the module config file.
sub save_remote_mail_server
{
my ($id, $server) = @_;

# Remove old keys for this server
foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_/) {
		delete $config{$k};
		}
	}

# Write new keys
foreach my $k (keys %$server) {
	next if ($k eq 'id');
	$config{"server_${id}_${k}"} = $server->{$k};
	}

&lock_file("$module_config_directory/config");
&save_module_config();
&unlock_file("$module_config_directory/config");
}

# delete_remote_mail_server($id)
# Removes all config keys for a server
sub delete_remote_mail_server
{
my ($id) = @_;

foreach my $k (keys %config) {
	if ($k =~ /^server_\Q${id}\E_/) {
		delete $config{$k};
		}
	}

&lock_file("$module_config_directory/config");
&save_module_config();
&unlock_file("$module_config_directory/config");
}

# get_default_remote_mail_server()
# Returns the ID of the default server, or the first one found
sub get_default_remote_mail_server
{
foreach my $id (&list_remote_mail_servers()) {
	my $s = &get_remote_mail_server($id);
	return $id if ($s->{'default'});
	}
# Fall back to first server
my @servers = &list_remote_mail_servers();
return $servers[0] if (@servers);
return undef;
}

# ---- RPC Wrappers ----

# _build_rpc_server(\%server)
# Builds a Webmin RPC connection hash from server config fields.
# Shared helper used by remote_mail_call() and remote_mail_cmd().
sub _build_rpc_server
{
my ($server) = @_;
return { 'host' => $server->{'webmin_host'} || $server->{'host'},
         'port' => $server->{'webmin_port'} || 10000,
         'ssl'  => $server->{'webmin_ssl'},
         'user' => $server->{'webmin_user'},
         'pass' => $server->{'webmin_pass'} };
}

# _ensure_rpc_session($serv)
# Ensures a Webmin RPC session is established for the given server hash.
# Calls remote_foreign_require once per server to create a FIFO session
# on the remote side. Subsequent remote_foreign_call requests will reuse it.
our %_rpc_initialized;
sub _ensure_rpc_session
{
my ($serv) = @_;
my $key = ($serv->{'host'} || '') . ':' . ($serv->{'port'} || 10000);
if (!$_rpc_initialized{$key}) {
	&remote_foreign_require($serv, 'webmin');
	$_rpc_initialized{$key} = 1;
	}
}

# remote_mail_call($server_id, $module, $func, @args)
# Wrapper around remote_foreign_call to the mail server's Webmin
sub remote_mail_call
{
my ($server_id, $module, $func, @args) = @_;
my $server = &get_remote_mail_server($server_id);
return undef if (!$server);

my $serv = &_build_rpc_server($server);
&_ensure_rpc_session($serv);
return &remote_foreign_call($serv, $module, $func, @args);
}

# remote_mail_cmd($server_id, $command)
# Executes a shell command on the remote server via Webmin RPC.
# Wraps the command with a sentinel to capture the exit code.
# Returns ($output, $exit_code) — same interface as the old remote_mail_ssh().
sub remote_mail_cmd
{
my ($server_id, $command) = @_;
my $server = &get_remote_mail_server($server_id);
return (undef, -1) if (!$server);

my $serv = &_build_rpc_server($server);
&_ensure_rpc_session($serv);

# Wrap command with sentinel to capture exit code
my $wrapped = "($command) 2>&1; echo \"\\n__RC__=\$?\"";
# remote_foreign_call may return multiple values (backquote_command returns
# a list of lines in list context through the RPC FIFO layer), so capture
# in list context and join to get the full output string.
my $out = join("", &remote_foreign_call($serv, 'webmin', 'backquote_command', $wrapped));

# Parse exit code from sentinel
my $exit = 0;
if ($out =~ /__RC__=(\d+)/) {
	$exit = $1;
	}
# Strip the sentinel line from output
$out =~ s/\n?__RC__=\d+\s*$//s;

return ($out, $exit);
}

# remote_mail_write($server_id, $local_file, $remote_file)
# Transfers a file to the remote server via Webmin RPC.
# Replaces SCP for file transfers.
sub remote_mail_write
{
my ($server_id, $local_file, $remote_file) = @_;
my $server = &get_remote_mail_server($server_id);
return 0 if (!$server);

my $serv = &_build_rpc_server($server);
&_ensure_rpc_session($serv);
return &remote_write($serv, $local_file, $remote_file);
}

# ---- Virtualmin CLI API Wrappers ----
# These functions delegate mail server operations to Virtualmin's CLI
# on the remote server (email1), rather than managing Postfix/Dovecot
# config files directly.

# _shell_quote($str)
# Shell-safe single-quoting for command arguments.
sub _shell_quote
{
my ($str) = @_;
$str =~ s/'/'\\''/g;
return "'$str'";
}

# remote_virtualmin_cmd($server_id, $subcmd, @args)
# Runs `virtualmin $subcmd @args` on the remote server via RPC.
# @args are alternating --flag / value pairs. Bare flags (no value) are
# passed through; values are shell-quoted for safety.
# Returns ($output, $exit_code) — same as remote_mail_cmd().
sub remote_virtualmin_cmd
{
my ($server_id, $subcmd, @args) = @_;
my @parts = ("virtualmin", $subcmd);
for (my $i = 0; $i < @args; $i++) {
	if ($args[$i] =~ /^--/) {
		push(@parts, $args[$i]);
		# If next arg is a value (doesn't start with --), quote it
		if ($i + 1 < @args && $args[$i + 1] !~ /^--/) {
			$i++;
			push(@parts, &_shell_quote($args[$i]));
			}
		}
	}
my $cmd = join(" ", @parts);
return &remote_mail_cmd($server_id, $cmd);
}

# parse_multiline_output($output)
# Parses Virtualmin's --multiline output format into an array of hashrefs.
# Each entry starts with a non-indented line (stored as '_name') followed
# by indented "    Key: Value" lines.
sub parse_multiline_output
{
my ($output) = @_;
return () if (!defined($output) || $output eq '');

my @entries;
my $current;

foreach my $line (split(/\n/, $output)) {
	if ($line =~ /^\S/) {
		# New entry — non-indented line is the entry name
		push(@entries, $current) if ($current);
		my $name = $line;
		$name =~ s/^\s+|\s+$//g;
		$current = { '_name' => $name };
		}
	elsif ($line =~ /^\s+(\S.*?):\s*(.*)$/ && $current) {
		my ($key, $val) = ($1, $2);
		# Normalize key: lowercase, spaces to underscores
		$key = lc($key);
		$key =~ s/\s+/_/g;
		$current->{$key} = $val;
		}
	}
push(@entries, $current) if ($current);

return @entries;
}

# get_remote_domain_info(&domain, $server_id)
# Returns a parsed hash of domain info from the remote server,
# via `virtualmin list-domains --domain X --multiline`.
sub get_remote_domain_info
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "list-domains",
	"--domain", $dom, "--multiline");
return undef if ($exit || !$out);

my @entries = &parse_multiline_output($out);
return $entries[0];
}

# list_remote_mail_users(&domain, $server_id)
# Returns a list of parsed user hashes for the domain from the remote
# server, via `virtualmin list-users --domain X --multiline`.
sub list_remote_mail_users
{
my ($d, $server_id) = @_;
my $dom = $d->{'dom'};

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "list-users",
	"--domain", $dom, "--multiline");
return () if ($exit || !$out);

return &parse_multiline_output($out);
}

# get_remote_mail_user(&domain, $server_id, $username)
# Returns a single user hash for the given username, or undef if not found.
sub get_remote_mail_user
{
my ($d, $server_id, $username) = @_;
my $dom = $d->{'dom'};

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "list-users",
	"--domain", $dom, "--multiline", "--user", $username);
return undef if ($exit || !$out);

my @entries = &parse_multiline_output($out);
return $entries[0];
}

# create_remote_mail_user(&domain, $server_id, $user, $password, \%opts)
# Creates a mail user on the remote server via `virtualmin create-user`.
sub create_remote_mail_user
{
my ($d, $server_id, $user, $password, $opts) = @_;
my $dom = $d->{'dom'};

my @args = ("--domain", $dom, "--user", $user);
push(@args, "--pass", $password) if ($password);
push(@args, "--real", $opts->{'real'}) if ($opts && $opts->{'real'});
# Spam checking is enabled by default on create-user; only --no-check-spam
# is a valid flag (there is no --check-spam for create-user).

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "create-user", @args);
return $exit ? "Failed to create user: $out" : undef;
}

# delete_remote_mail_user(&domain, $server_id, $user)
# Deletes a mail user on the remote server via `virtualmin delete-user`.
sub delete_remote_mail_user
{
my ($d, $server_id, $user) = @_;
my $dom = $d->{'dom'};

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "delete-user",
	"--domain", $dom, "--user", $user);
return $exit ? "Failed to delete user: $out" : undef;
}

# modify_remote_mail_user(&domain, $server_id, $username, \%changes)
# Modifies a mail user on the remote server via `virtualmin modify-user`.
# %changes keys map to CLI flags:
#   pass, newuser, real, add_email, remove_email,
#   add_forward, del_forward, local, no_local,
#   autoreply, no_autoreply, check_spam, no_check_spam,
#   disable, enable, recovery, no_recovery, send_update_email
sub modify_remote_mail_user
{
my ($d, $server_id, $username, $changes) = @_;
my $dom = $d->{'dom'};

my @args = ("--domain", $dom, "--user", $username);

# Flags that take a value
my @value_flags = (
	['pass',         'pass'],
	['newuser',      'newuser'],
	['real',         'real'],
	['add_email',    'add-email'],
	['remove_email', 'remove-email'],
	['add_forward',  'add-forward'],
	['del_forward',  'del-forward'],
	['autoreply',    'autoreply'],
	['recovery',     'recovery'],
);
foreach my $pair (@value_flags) {
	my ($key, $flag) = @$pair;
	if (defined $changes->{$key}) {
		if (ref($changes->{$key}) eq 'ARRAY') {
			foreach my $val (@{$changes->{$key}}) {
				push(@args, "--$flag", $val);
				}
			}
		else {
			push(@args, "--$flag", $changes->{$key});
			}
		}
	}

# Boolean flags (no value)
my @bool_flags = (
	['local',             'local'],
	['no_local',          'no-local'],
	['no_autoreply',      'no-autoreply'],
	['check_spam',        'check-spam'],
	['no_check_spam',     'no-check-spam'],
	['disable',           'disable'],
	['enable',            'enable'],
	['no_recovery',       'no-recovery'],
	['send_update_email', 'send-update-email'],
);
foreach my $pair (@bool_flags) {
	my ($key, $flag) = @$pair;
	if ($changes->{$key}) {
		push(@args, "--$flag");
		}
	}

my ($out, $exit) = &remote_virtualmin_cmd($server_id, "modify-user", @args);
return $exit ? "Failed to modify user: $out" : undef;
}

# test_remote_mail_server($id)
# Tests Webmin RPC connectivity by calling get_webmin_version.
# Returns undef on success, or an error message on failure.
sub test_remote_mail_server
{
my ($id) = @_;
my $server = &get_remote_mail_server($id);
return "Server $id not found" if (!$server);

# Require Webmin RPC credentials
if (!$server->{'webmin_user'} || !$server->{'webmin_pass'}) {
	return &text('test_erpc', 'Webmin username and password are required');
	}

# Test Webmin RPC
eval {
	my $ver = &remote_mail_call($id, 'webmin', 'get_webmin_version');
	if (!$ver) {
		die "No response from Webmin RPC";
		}
	};
if ($@) {
	return &text('test_erpc', $@);
	}

return undef;
}

# ---- DNS Helpers ----

# resolve_to_ip($host)
# Returns the IPv4 address for a hostname. If the input already looks like an
# IPv4 address, returns it unchanged. Falls back to the original value if
# resolution fails.
sub resolve_to_ip
{
my ($host) = @_;
return $host if (!$host);
return $host if ($host =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/);
my $packed = inet_aton($host);
return $packed ? inet_ntoa($packed) : $host;
}

# ---- DNS Record Builders ----
# Pure functions that generate record values — no I/O, easy to test.

# build_spf_record(\%params)
# Params: ip4 => [list], ip6 => [list], include => [list], all => '~all'
# Returns the SPF TXT record value string.
sub build_spf_record
{
my ($params) = @_;
my @parts = ('v=spf1');

if ($params->{'ip4'}) {
	foreach my $ip (@{$params->{'ip4'}}) {
		push(@parts, "ip4:$ip");
		}
	}
if ($params->{'ip6'}) {
	foreach my $ip (@{$params->{'ip6'}}) {
		push(@parts, "ip6:$ip");
		}
	}
if ($params->{'include'}) {
	foreach my $inc (@{$params->{'include'}}) {
		push(@parts, "include:$inc");
		}
	}
push(@parts, $params->{'all'} || '~all');
return join(' ', @parts);
}

# build_dkim_record($domain, $selector, $pubkey)
# Returns ($name, $value) for the DKIM TXT record.
# $pubkey should be the base64 public key without headers/footers.
sub build_dkim_record
{
my ($domain, $selector, $pubkey) = @_;
my $name = "${selector}._domainkey.${domain}";
my $value = "v=DKIM1; k=rsa; p=${pubkey}";
return ($name, $value);
}

# build_dmarc_record($domain, \%params)
# Params: p => 'none'|'quarantine'|'reject', rua => 'mailto:...', pct => 100
# Returns ($name, $value) for the DMARC TXT record.
sub build_dmarc_record
{
my ($domain, $params) = @_;
my $name = "_dmarc.${domain}";
my @parts = ('v=DMARC1');
push(@parts, 'p='.($params->{'p'} || 'none'));
push(@parts, 'rua='.$params->{'rua'}) if ($params->{'rua'});
push(@parts, 'pct='.$params->{'pct'}) if (defined $params->{'pct'});
my $value = join('; ', @parts);
return ($name, $value);
}

# build_mx_records($domain, \%server_config)
# Returns a list of hash refs with: name, type, priority, value.
# Generates MX + A records for mail/spam-gateway hosts.
sub build_mx_records
{
my ($domain, $server) = @_;
my @records;

if ($server->{'spam_gateway'}) {
	# MX points to spam gateway hostname
	my $mg_host = ($server->{'spam_gateway_host'} || 'mg') . ".${domain}";
	push(@records,
		{ 'name' => $domain, 'type' => 'MX',
		  'priority' => 5, 'value' => $mg_host },
		{ 'name' => $mg_host, 'type' => 'A',
		  'value' => $server->{'spam_gateway'} },
		);

	# Also add mail.domain pointing to the actual mail server
	push(@records,
		{ 'name' => "mail.${domain}", 'type' => 'A',
		  'value' => $server->{'host'} },
		);
	}
else {
	# Direct MX to the mail server
	push(@records,
		{ 'name' => $domain, 'type' => 'MX',
		  'priority' => 5, 'value' => "mail.${domain}" },
		{ 'name' => "mail.${domain}", 'type' => 'A',
		  'value' => $server->{'host'} },
		);
	}

return @records;
}

# ---- Domain State Management ----

# get_domain_state($domain_name)
# Reads the per-domain state file. Returns a hash ref.
sub get_domain_state
{
my ($domain) = @_;
my $file = "$domains_dir/${domain}.conf";
my %state;
if (-r $file) {
	&read_file($file, \%state);
	}
return \%state;
}

# save_domain_state($domain_name, \%state)
# Writes the per-domain state file.
sub save_domain_state
{
my ($domain, $state) = @_;
if (! -d $domains_dir) {
	&make_dir($domains_dir, 0700);
	}
my $file = "$domains_dir/${domain}.conf";
&lock_file($file);
&write_file($file, $state);
&unlock_file($file);
}

# delete_domain_state($domain_name)
# Removes the per-domain state file.
sub delete_domain_state
{
my ($domain) = @_;
my $file = "$domains_dir/${domain}.conf";
&unlink_file($file) if (-f $file);
}

# ---- Override Validation ----

# validate_mail_override($key, $value)
# Validates a per-domain mail routing override value.
# Returns undef on success, or an error message string on failure.
# $key is one of: spam_gateway, spam_gateway_host, outgoing_relay, outgoing_relay_port
sub validate_mail_override
{
my ($key, $value) = @_;
return undef if (!defined($value) || $value eq '');

if ($key eq 'spam_gateway') {
	# Must be a valid IPv4 address
	if ($value !~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/ ||
	    $1 > 255 || $2 > 255 || $3 > 255 || $4 > 255) {
		return "Invalid IP address: $value";
		}
	}
elsif ($key eq 'spam_gateway_host') {
	# Must be a valid DNS label: alphanumeric + hyphens, no leading/trailing hyphen
	if ($value !~ /^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$/) {
		return "Invalid hostname prefix: $value (alphanumeric and hyphens only)";
		}
	}
elsif ($key eq 'outgoing_relay') {
	# Must be a valid hostname: labels separated by dots
	if ($value !~ /^[a-zA-Z0-9]([a-zA-Z0-9\-\.]{0,253}[a-zA-Z0-9])?$/) {
		return "Invalid relay hostname: $value";
		}
	# No consecutive dots, no leading/trailing dots
	if ($value =~ /\.\./ || $value =~ /^\./ || $value =~ /\.$/) {
		return "Invalid relay hostname: $value";
		}
	}
elsif ($key eq 'outgoing_relay_port') {
	# Must be a numeric port 1-65535
	if ($value !~ /^\d+$/ || $value < 1 || $value > 65535) {
		return "Invalid port number: $value (must be 1-65535)";
		}
	}
return undef;
}

# ---- Username Validation ----

# validate_mail_username($username)
# Validates a mail username (the local part before @domain).
# Returns undef on success, or an error message string on failure.
sub validate_mail_username
{
my ($username) = @_;
if (!defined($username) || $username eq '') {
	return "Username is required";
	}
# Allow: letters, digits, dots, hyphens, underscores
# Disallow: leading/trailing dots, consecutive dots, any other chars
if ($username !~ /^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$/ ||
    $username =~ /\.\./) {
	return "Invalid username: only letters, numbers, dots, hyphens, and underscores are allowed";
	}
return undef;
}

# ---- Effective Mail Config (domain overrides + server defaults) ----

# get_effective_mail_config(&domain, \%server)
# Merges per-domain overrides (stored in $d->{'remote_mail_*'}) with
# server defaults. Returns a new hash ref — never mutates the inputs.
sub get_effective_mail_config
{
my ($d, $server) = @_;
my %eff = %$server;
for my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
	my $dk = "remote_mail_${key}";
	if (defined $d->{$dk} && $d->{$dk} ne '') {
		$eff{$key} = $d->{$dk};
		}
	}
return \%eff;
}

# ---- Server Selection for Domain ----

# get_domain_mail_server($d)
# Returns the mail server ID for a domain, falling back to default
sub get_domain_mail_server
{
my ($d) = @_;
return $d->{'remote_mail_server'} || &get_default_remote_mail_server();
}

# ---- Locking ----

# obtain_lock_remote_mail([$d])
# Acquires locks for remote mail operations
sub obtain_lock_remote_mail
{
my ($d) = @_;
if (defined(&virtual_server::obtain_lock_anything)) {
	&virtual_server::obtain_lock_anything();
	}
if ($got_lock_remote_mail == 0) {
	@got_lock_remote_mail_files = ();
	push(@got_lock_remote_mail_files,
	     "$module_config_directory/config");
	if ($d) {
		push(@got_lock_remote_mail_files,
		     "$domains_dir/".$d->{'dom'}.".conf");
		}
	foreach my $f (@got_lock_remote_mail_files) {
		&lock_file($f);
		}
	}
$got_lock_remote_mail++;
}

# release_lock_remote_mail()
# Releases locks for remote mail operations
sub release_lock_remote_mail
{
if ($got_lock_remote_mail == 1) {
	foreach my $f (@got_lock_remote_mail_files) {
		&unlock_file($f);
		}
	}
$got_lock_remote_mail-- if ($got_lock_remote_mail);
if (defined(&virtual_server::release_lock_anything)) {
	&virtual_server::release_lock_anything();
	}
}

# ---- ACL ----

# can_edit_domain($dname)
# Check if current user can edit mail for this domain
sub can_edit_domain
{
my ($dname) = @_;
my $dom_acl = $access{'dom'};
if (!defined($dom_acl) || $dom_acl eq '' || $dom_acl eq '*') {
	return 1;
	}
return &indexof($dname, split(/\s+/, $dom_acl)) >= 0;
}

1;
