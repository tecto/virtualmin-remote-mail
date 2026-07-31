# virtualmin-remote-mail-lib.pl
# Core library for the Virtualmin Remote Mail Server plugin.
# Handles server config CRUD, RPC/SSH wrappers, DNS builders, and state.

use strict;
use warnings;
use Socket;
use MIME::Base64 ();
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

# ---- RPC and SSH Wrappers ----

# _build_rpc_server($server_id)
# Returns a server hash suitable for remote_foreign_call/require.
# Caches the hash to avoid rebuilding on every call.
our %_rpc_server_cache;
sub _build_rpc_server
{
my ($server_id) = @_;
return $_rpc_server_cache{$server_id} if ($_rpc_server_cache{$server_id});
my $server = &get_remote_mail_server($server_id);
return undef if (!$server);
my $serv = { 'host' => $server->{'webmin_host'} || $server->{'host'},
             'port' => $server->{'webmin_port'} || 10000,
             'ssl'  => $server->{'webmin_ssl'},
             'user' => $server->{'webmin_user'},
             'pass' => $server->{'webmin_pass'} };
$_rpc_server_cache{$server_id} = $serv;
return $serv;
}

# _ensure_rpc_session($server_id, $module)
# Ensures a fastrpc session is established for the given module.
# Webmin 2.x requires remote_foreign_require before remote_foreign_call
# to set up the fastrpc persistent connection and session token.
our %_rpc_required;
sub _ensure_rpc_session
{
my ($server_id, $module) = @_;
my $key = "${server_id}::${module}";
return if ($_rpc_required{$key});
my $serv = &_build_rpc_server($server_id);
return if (!$serv);
&remote_foreign_require($serv, $module);
$_rpc_required{$key} = 1;
}

# remote_mail_call($server_id, $module, $func, @args)
# Wrapper around remote_foreign_call to the mail server's Webmin.
# Ensures the fastrpc session is established before making the call.
sub remote_mail_call
{
my ($server_id, $module, $func, @args) = @_;
my $serv = &_build_rpc_server($server_id);
return undef if (!$serv);
&_ensure_rpc_session($server_id, $module);
return &remote_foreign_call($serv, $module, $func, @args);
}

# remote_mail_ssh($server_id, $command)
# Executes a command on the remote server via SSH.
# Returns ($output, $exit_code).
sub remote_mail_ssh
{
my ($server_id, $command) = @_;
my $server = &get_remote_mail_server($server_id);
return (undef, -1) if (!$server);

my $ssh_host = $server->{'ssh_host'} || $server->{'host'};
my $ssh_user = $server->{'ssh_user'} || 'root';
my $ssh_key  = $server->{'ssh_key'};

my @cmd = ('ssh');
push(@cmd, '-i', $ssh_key) if ($ssh_key);
push(@cmd, '-o', 'StrictHostKeyChecking=no');
push(@cmd, '-o', 'BatchMode=yes');
push(@cmd, '-o', 'ConnectTimeout=10');
push(@cmd, "${ssh_user}\@${ssh_host}");
push(@cmd, $command);

my $out = &backquote_command(join(' ', map { quotemeta($_) } @cmd)." 2>&1");
my $exit = $?;
return ($out, $exit >> 8);
}

# test_remote_mail_server($id)
# Tests Webmin RPC (if credentials configured) and SSH connectivity.
# Returns undef on success, or an error message on failure.
sub test_remote_mail_server
{
my ($id) = @_;
my $server = &get_remote_mail_server($id);
return "Server $id not found" if (!$server);

# Test Webmin RPC (only if credentials are configured)
if ($server->{'webmin_user'} && $server->{'webmin_pass'}) {
	eval {
		my $ver = &remote_mail_call($id, 'webmin', 'get_webmin_version');
		if (!$ver) {
			die "No response from Webmin RPC";
			}
		};
	if ($@) {
		return &text('test_erpc', $@);
		}
	}

# Test SSH
my ($out, $exit) = &remote_mail_ssh($id, 'echo ok');
if ($exit != 0 || $out !~ /ok/) {
	return &text('test_essh', $out || "Connection failed");
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

# ---- Certbot Deploy Hook Management ----

# The hook script deployed to the remote mail server. When certbot on the
# remote server renews any certificate, this hook rebuilds the Postfix SNI
# map using postmap -F (which base64-encodes the cert file contents into
# the hash table — required by Postfix tls_server_sni_maps).
our $CERTBOT_HOOK_NAME = "virtualmin-remote-mail-sni-sync.sh";

# get_certbot_hook_script()
# Returns the shell script content for the remote certbot deploy hook.
sub get_certbot_hook_script
{
return <<'HOOKSCRIPT';
#!/bin/bash
# virtualmin-remote-mail-sni-sync.sh
# Certbot deploy hook installed by the virtualmin-remote-mail plugin.
# Rebuilds the Postfix SNI map after any certificate renewal on this server.
# The SNI map must be rebuilt with postmap -F to base64-encode cert contents.
set -euo pipefail

CERT_NAME=$(basename "$RENEWED_LINEAGE")
HOME_DIR="/home/$CERT_NAME"

# Only process domains that have per-domain SSL files
if [ ! -d "$HOME_DIR/ssl" ]; then
    exit 0
fi

FULLCHAIN="$RENEWED_LINEAGE/fullchain.pem"
PRIVKEY="$RENEWED_LINEAGE/privkey.pem"
CHAIN="$RENEWED_LINEAGE/chain.pem"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ]; then
    logger -t certbot-sni-sync "ERROR: cert files missing for $CERT_NAME"
    exit 0
fi

# Update per-domain cert files (used by SNI map entries)
cp "$FULLCHAIN" "$HOME_DIR/ssl/$CERT_NAME.crt"
cp "$PRIVKEY"   "$HOME_DIR/ssl/$CERT_NAME.key"
[ -f "$CHAIN" ] && cp "$CHAIN" "$HOME_DIR/ssl/$CERT_NAME.ca"

# Build ssl.combined: KEY first (Postfix smtpd_tls_chain_files format)
cat "$PRIVKEY" "$FULLCHAIN" > "$HOME_DIR/ssl.combined"

# Fix ownership and permissions
DOMAIN_USER=$(stat -c '%U' "$HOME_DIR" 2>/dev/null || echo root)
chown "$DOMAIN_USER:$DOMAIN_USER" \
    "$HOME_DIR/ssl/$CERT_NAME.crt" \
    "$HOME_DIR/ssl/$CERT_NAME.key" \
    "$HOME_DIR/ssl.combined" 2>/dev/null || true
[ -f "$HOME_DIR/ssl/$CERT_NAME.ca" ] && \
    chown "$DOMAIN_USER:$DOMAIN_USER" "$HOME_DIR/ssl/$CERT_NAME.ca" 2>/dev/null || true
chmod 600 "$HOME_DIR/ssl/$CERT_NAME.key" "$HOME_DIR/ssl.combined"

# Rebuild Postfix SNI map with -F (base64-encodes cert contents into hash)
if [ -f /etc/postfix/sni_map ]; then
    postmap -F hash:/etc/postfix/sni_map 2>/dev/null || true
fi

# Restart Postfix (not just reload — smtpd processes cache TLS contexts)
systemctl restart postfix 2>/dev/null || true
systemctl reload dovecot  2>/dev/null || true

logger -t certbot-sni-sync "Rebuilt SNI map for $CERT_NAME, restarted mail services"
HOOKSCRIPT
}

# deploy_remote_certbot_hook($server_id)
# Deploys the certbot deploy hook to the remote mail server via SSH.
# Returns undef on success, or an error message on failure.
sub deploy_remote_certbot_hook
{
my ($server_id) = @_;
my $server = &get_remote_mail_server($server_id);
return "Server not found" if (!$server);

my $hook_path = "/etc/letsencrypt/renewal-hooks/deploy/$CERTBOT_HOOK_NAME";
my $hook_content = &get_certbot_hook_script();

eval {
	# Ensure the deploy hooks directory exists
	my ($out, $exit) = &remote_mail_ssh($server_id,
		"mkdir -p /etc/letsencrypt/renewal-hooks/deploy");
	if ($exit != 0) {
		die "Failed to create hook directory: $out";
		}

	# Transfer hook script via SSH using base64 encoding to avoid
	# quoting issues with heredocs and special characters
	my $encoded = MIME::Base64::encode_base64($hook_content, '');

	($out, $exit) = &remote_mail_ssh($server_id,
		"echo '$encoded' | base64 -d > $hook_path && chmod 755 $hook_path");
	if ($exit != 0) {
		die "Failed to install hook: $out";
		}
	};

return $@ ? "$@" : undef;
}

# remove_remote_certbot_hook($server_id)
# Removes the certbot deploy hook from the remote mail server.
# Returns undef on success, or an error message on failure.
sub remove_remote_certbot_hook
{
my ($server_id) = @_;
my $hook_path = "/etc/letsencrypt/renewal-hooks/deploy/$CERTBOT_HOOK_NAME";

my ($out, $exit) = &remote_mail_ssh($server_id,
	"rm -f $hook_path");
return ($exit != 0) ? "Failed to remove hook: $out" : undef;
}

# check_remote_certbot_hook($server_id)
# Checks if the certbot deploy hook is installed on the remote server.
# Returns 1 if installed, 0 if not.
sub check_remote_certbot_hook
{
my ($server_id) = @_;
my $hook_path = "/etc/letsencrypt/renewal-hooks/deploy/$CERTBOT_HOOK_NAME";

my ($out, $exit) = &remote_mail_ssh($server_id,
	"test -x $hook_path && echo installed");
return ($exit == 0 && $out =~ /installed/) ? 1 : 0;
}

# ---- ACL ----

# can_edit_domain($dname)
# Check if current user can edit mail for this domain
sub can_edit_domain
{
my ($dname) = @_;
if ($access{'dom'} eq '*') {
	return 1;
	}
return &indexof($dname, split(/\s+/, $access{'dom'})) >= 0;
}

1;
