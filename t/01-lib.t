#!/usr/bin/perl
# 01-lib.t — Test core library functions with mocked Webmin
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

# Load mock Webmin before the library
require "$FindBin::Bin/mock-webmin.pl";

# Load the library under test
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");

# Point domains_dir at temp directory
$main::domains_dir = "$main::module_config_directory/domains";

# =========================================
# Test: Server Config CRUD
# =========================================

subtest 'Server config CRUD' => sub {
    plan tests => 12;

    # Initially no servers
    my @servers = list_remote_mail_servers();
    is(scalar @servers, 0, 'No servers initially');

    # Save a server
    my %server1 = (
        host         => 'vh2.trinsik.io',
        desc         => 'Primary Mail Server',
        webmin_host  => 'vh2.trinsik.io',
        webmin_port  => 10000,
        webmin_ssl   => 1,
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        ssh_host     => 'vh2.trinsik.io',
        ssh_user     => 'root',
        ssh_key      => '/root/.ssh/id_rsa',
        spam_gateway => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        dkim_selector => '202307',
        maildir_format => '.maildir',
        default      => 1,
    );
    save_remote_mail_server('1', \%server1);

    # List should now have one
    @servers = list_remote_mail_servers();
    is(scalar @servers, 1, 'One server after save');
    is($servers[0], '1', 'Server ID is 1');

    # Get server
    my $s = get_remote_mail_server('1');
    ok($s, 'Got server config');
    is($s->{'host'}, 'vh2.trinsik.io', 'Host matches');
    is($s->{'desc'}, 'Primary Mail Server', 'Description matches');
    is($s->{'webmin_port'}, 10000, 'Webmin port matches');
    is($s->{'default'}, 1, 'Default flag matches');
    is($s->{'id'}, '1', 'ID field added');

    # Get default server
    my $default_id = get_default_remote_mail_server();
    is($default_id, '1', 'Default server is server_1');

    # Get nonexistent server
    my $none = get_remote_mail_server('99');
    is($none, undef, 'Nonexistent server returns undef');

    # Delete server
    delete_remote_mail_server('1');
    @servers = list_remote_mail_servers();
    is(scalar @servers, 0, 'No servers after delete');
};

# =========================================
# Test: SPF Record Builder
# =========================================

subtest 'SPF record builder' => sub {
    plan tests => 4;

    # Basic SPF
    my $spf = build_spf_record({
        ip4 => ['1.2.3.4'],
        all => '~all',
    });
    is($spf, 'v=spf1 ip4:1.2.3.4 ~all', 'Basic SPF record');

    # Multiple IPs and includes
    $spf = build_spf_record({
        ip4     => ['1.2.3.4', '5.6.7.8'],
        include => ['_spf.google.com', '_spf.trinsiklabs.com'],
        all     => '-all',
    });
    is($spf,
       'v=spf1 ip4:1.2.3.4 ip4:5.6.7.8 include:_spf.google.com include:_spf.trinsiklabs.com -all',
       'Multi-IP SPF with includes');

    # IPv6
    $spf = build_spf_record({
        ip4 => ['1.2.3.4'],
        ip6 => ['2001:db8::1'],
        all => '~all',
    });
    is($spf, 'v=spf1 ip4:1.2.3.4 ip6:2001:db8::1 ~all', 'SPF with IPv6');

    # Default ~all
    $spf = build_spf_record({ ip4 => ['1.2.3.4'] });
    like($spf, qr/~all$/, 'Default ~all when not specified');
};

# =========================================
# Test: DKIM Record Builder
# =========================================

subtest 'DKIM record builder' => sub {
    plan tests => 3;

    my ($name, $value) = build_dkim_record('example.com', '202307', 'MIIBpubkey==');
    is($name, '202307._domainkey.example.com', 'DKIM record name');
    like($value, qr/^v=DKIM1; k=rsa; p=MIIBpubkey==$/, 'DKIM record value');

    # Different selector
    ($name, $value) = build_dkim_record('test.io', 'default', 'ABCDkey');
    is($name, 'default._domainkey.test.io', 'DKIM with different selector');
};

# =========================================
# Test: DMARC Record Builder
# =========================================

subtest 'DMARC record builder' => sub {
    plan tests => 3;

    my ($name, $value) = build_dmarc_record('example.com', {
        p   => 'none',
        rua => 'mailto:dmarc@example.com',
    });
    is($name, '_dmarc.example.com', 'DMARC record name');
    like($value, qr/v=DMARC1/, 'DMARC contains version');
    like($value, qr/rua=mailto:dmarc\@example.com/, 'DMARC contains rua');
};

# =========================================
# Test: MX Record Builder
# =========================================

subtest 'MX record builder' => sub {
    plan tests => 6;

    # With spam gateway
    my @records = build_mx_records('example.com', {
        host              => '10.0.0.2',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
    });
    is(scalar @records, 3, 'Three records with spam gateway (MX + 2 A)');
    is($records[0]->{'type'}, 'MX', 'First record is MX');
    is($records[0]->{'value'}, 'mg.example.com', 'MX points to spam gateway host');
    is($records[1]->{'value'}, '216.55.103.236', 'A record for spam gateway');

    # Without spam gateway (direct)
    @records = build_mx_records('example.com', {
        host => '10.0.0.2',
    });
    is(scalar @records, 2, 'Two records without spam gateway (MX + A)');
    is($records[0]->{'value'}, 'mail.example.com', 'MX points to mail.domain');
};

# =========================================
# Test: Domain State Management
# =========================================

subtest 'Domain state management' => sub {
    plan tests => 6;

    # Save state
    my %state = (
        server_id          => '1',
        setup_time         => 1700000000,
        dns_configured     => 1,
        postfix_configured => 1,
        dovecot_configured => 1,
    );
    save_domain_state('example.com', \%state);

    # Read state
    my $loaded = get_domain_state('example.com');
    is($loaded->{'server_id'}, '1', 'State server_id');
    is($loaded->{'dns_configured'}, '1', 'State dns flag');
    is($loaded->{'postfix_configured'}, '1', 'State postfix flag');

    # Nonexistent domain
    my $empty = get_domain_state('nonexistent.com');
    ok(!$empty->{'server_id'}, 'Nonexistent domain has no state');

    # Delete state
    delete_domain_state('example.com');
    $loaded = get_domain_state('example.com');
    ok(!$loaded->{'server_id'}, 'State deleted');

    # Domain mail server selection
    my $d = { 'dom' => 'test.com' };
    # No server set on domain, no default configured
    my $sid = get_domain_mail_server($d);
    ok(!$sid, 'No server when none configured');
};

# =========================================
# Test: get_effective_mail_config
# =========================================

subtest 'get_effective_mail_config — server defaults when no overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    my $d = { 'dom' => 'example.com' };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '216.55.103.236', 'Server default spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Server default spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Server default outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 25, 'Server default outgoing_relay_port');
};

subtest 'get_effective_mail_config — full domain overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    my $d = {
        'dom' => 'override.com',
        'remote_mail_spam_gateway'      => '10.0.0.99',
        'remote_mail_spam_gateway_host' => 'spam',
        'remote_mail_outgoing_relay'      => 'relay.other.com',
        'remote_mail_outgoing_relay_port' => 587,
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '10.0.0.99', 'Domain override spam_gateway');
    is($eff->{'spam_gateway_host'}, 'spam', 'Domain override spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'relay.other.com', 'Domain override outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 587, 'Domain override outgoing_relay_port');
};

subtest 'get_effective_mail_config — partial overrides' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    # Domain overrides only spam_gateway, rest should fall through to server
    my $d = {
        'dom' => 'partial.com',
        'remote_mail_spam_gateway' => '10.0.0.50',
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '10.0.0.50', 'Domain override spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Server default spam_gateway_host (no override)');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Server default outgoing_relay (no override)');
    is($eff->{'outgoing_relay_port'}, 25, 'Server default outgoing_relay_port (no override)');
};

# =========================================
# Test: get_effective_mail_config — empty-string override
# =========================================

subtest 'get_effective_mail_config — empty string overrides use server default' => sub {
    plan tests => 4;

    my $server = {
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay      => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        host              => 'vh2.trinsik.io',
    };
    # Domain has all overrides set to empty string (cleared)
    my $d = {
        'dom' => 'cleared.com',
        'remote_mail_spam_gateway'      => '',
        'remote_mail_spam_gateway_host' => '',
        'remote_mail_outgoing_relay'      => '',
        'remote_mail_outgoing_relay_port' => '',
    };

    my $eff = get_effective_mail_config($d, $server);
    is($eff->{'spam_gateway'}, '216.55.103.236', 'Empty string falls back to server spam_gateway');
    is($eff->{'spam_gateway_host'}, 'mg', 'Empty string falls back to server spam_gateway_host');
    is($eff->{'outgoing_relay'}, 'smtp-out.trinsiklabs.com', 'Empty string falls back to server outgoing_relay');
    is($eff->{'outgoing_relay_port'}, 25, 'Empty string falls back to server outgoing_relay_port');
};

# =========================================
# Test: validate_mail_override
# =========================================

subtest 'validate_mail_override — valid inputs' => sub {
    plan tests => 5;

    is(validate_mail_override('spam_gateway', '10.0.0.1'), undef, 'Valid IP accepted');
    is(validate_mail_override('spam_gateway', ''), undef, 'Empty value accepted (clears override)');
    is(validate_mail_override('spam_gateway_host', 'mg'), undef, 'Valid hostname prefix accepted');
    is(validate_mail_override('outgoing_relay', 'smtp-out.trinsiklabs.com'), undef, 'Valid relay hostname accepted');
    is(validate_mail_override('outgoing_relay_port', '587'), undef, 'Valid port accepted');
};

subtest 'validate_mail_override — invalid inputs' => sub {
    plan tests => 10;

    # Bad IPs
    like(validate_mail_override('spam_gateway', '999.1.1.1'),
        qr/Invalid IP/, 'Rejects octet > 255');
    like(validate_mail_override('spam_gateway', 'not-an-ip'),
        qr/Invalid IP/, 'Rejects non-IP string');
    like(validate_mail_override('spam_gateway', "1.2.3.4'; rm -rf /"),
        qr/Invalid IP/, 'Rejects shell injection in IP');

    # Bad hostname prefix
    like(validate_mail_override('spam_gateway_host', '-leading'),
        qr/Invalid hostname prefix/, 'Rejects leading hyphen');
    like(validate_mail_override('spam_gateway_host', 'has spaces'),
        qr/Invalid hostname prefix/, 'Rejects spaces in hostname');
    like(validate_mail_override('spam_gateway_host', 'has.dots'),
        qr/Invalid hostname prefix/, 'Rejects dots in hostname prefix');

    # Bad relay
    like(validate_mail_override('outgoing_relay', 'relay..host.com'),
        qr/Invalid relay hostname/, 'Rejects consecutive dots');
    like(validate_mail_override('outgoing_relay', "host; rm -rf /"),
        qr/Invalid relay hostname/, 'Rejects shell injection in relay');

    # Bad ports
    like(validate_mail_override('outgoing_relay_port', '0'),
        qr/Invalid port/, 'Rejects port 0');
    like(validate_mail_override('outgoing_relay_port', '99999'),
        qr/Invalid port/, 'Rejects port > 65535');
};

# =========================================
# Test: remote_mail_cmd via RPC
# =========================================

subtest 'remote_mail_cmd via RPC' => sub {
    plan tests => 5;

    # Set up a server with webmin credentials
    save_remote_mail_server('rpc1', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    @main::_rpc_calls = ();
    my ($out, $exit) = remote_mail_cmd('rpc1', 'echo hello');
    is($exit, 0, 'Exit code parsed from sentinel');
    like($out, qr/ok/, 'Output returned from RPC');

    # Verify the RPC call was made with backquote_command
    ok(scalar @main::_rpc_calls > 0, 'RPC call was captured');
    is($main::_rpc_calls[-1]{'func'}, 'backquote_command',
       'RPC uses backquote_command');
    like($main::_rpc_calls[-1]{'args'}[0], qr/__RC__/,
       'Command wrapped with sentinel');

    delete_remote_mail_server('rpc1');
};

# =========================================
# Test: _build_rpc_server helper
# =========================================

subtest '_build_rpc_server helper' => sub {
    plan tests => 5;

    my %server = (
        host        => 'vh2.trinsik.io',
        webmin_host => 'webmin.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'admin',
        webmin_pass => 'secret123',
    );

    my $serv = _build_rpc_server(\%server);
    is($serv->{'host'}, 'webmin.trinsik.io', 'Uses webmin_host');
    is($serv->{'port'}, 10000, 'Uses webmin_port');
    is($serv->{'ssl'}, 1, 'Uses webmin_ssl');
    is($serv->{'user'}, 'admin', 'Uses webmin_user');
    is($serv->{'pass'}, 'secret123', 'Uses webmin_pass');
};

# =========================================
# Test: remote_mail_write via RPC
# =========================================

subtest 'remote_mail_write via RPC' => sub {
    plan tests => 4;

    save_remote_mail_server('rpc2', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    # Create a temp local file (remote_mail_write now reads file contents)
    my $tmpfile = "$main::module_config_directory/test-write.pem";
    open(my $fh, '>', $tmpfile) or die;
    print $fh "TEST CERT DATA\n";
    close($fh);

    @main::_files_written = ();
    my $ok = remote_mail_write('rpc2', $tmpfile, '/etc/ssl/remote.pem');
    ok($ok, 'remote_mail_write returns success');
    is(scalar @main::_files_written, 1, 'One file write captured');
    is($main::_files_written[0]{'remote'}, '/etc/ssl/remote.pem',
       'Remote path captured correctly');
    like($main::_files_written[0]{'data'}, qr/TEST CERT DATA/,
       'File data sent inline via RPC');

    unlink($tmpfile);
    delete_remote_mail_server('rpc2');
};

# =========================================
# Test: test_remote_mail_server — RPC only
# =========================================

subtest 'test_remote_mail_server — RPC only' => sub {
    plan tests => 2;

    save_remote_mail_server('rpc3', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    @main::_commands_run = ();
    @main::_rpc_calls = ();
    my $err = test_remote_mail_server('rpc3');
    is($err, undef, 'RPC-only connectivity test passes');

    # Verify NO SSH commands were run (backquote_command is SSH)
    is(scalar @main::_commands_run, 0,
       'No SSH commands run during connectivity test');

    delete_remote_mail_server('rpc3');
};

# =========================================
# Test: ACL
# =========================================

subtest 'ACL checks' => sub {
    plan tests => 1;

    # With wildcard access
    ok(can_edit_domain('anything.com'), 'Wildcard ACL allows all');
};

# =========================================
# Test: _ensure_rpc_session establishes session before RPC calls
# Regression: Without remote_foreign_require(), rpc.cgi receives
# session=undef, tries to open non-existent FIFOs, returns 0 bytes.
# =========================================

subtest '_ensure_rpc_session — establishes session before first RPC call' => sub {
    plan tests => 4;

    save_remote_mail_server('sess1', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    # Reset session tracking state
    %main::_rpc_initialized = ();
    @main::_rpc_require_calls = ();
    @main::_rpc_calls = ();

    remote_mail_cmd('sess1', 'echo test');

    # remote_foreign_require MUST have been called to establish session
    is(scalar @main::_rpc_require_calls, 1,
       'remote_foreign_require called exactly once');
    is($main::_rpc_require_calls[0]{'module'}, 'webmin',
       'Session established for webmin module');

    # The actual backquote_command RPC call should also have been made
    ok(scalar @main::_rpc_calls > 0,
       'remote_foreign_call also made');
    is($main::_rpc_calls[-1]{'func'}, 'backquote_command',
       'RPC call used backquote_command');

    delete_remote_mail_server('sess1');
};

# =========================================
# Test: _ensure_rpc_session is idempotent (one require per server)
# =========================================

subtest '_ensure_rpc_session — idempotent per server' => sub {
    plan tests => 1;

    save_remote_mail_server('sess2', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    %main::_rpc_initialized = ();
    @main::_rpc_require_calls = ();

    # Call remote_mail_cmd three times on the same server
    remote_mail_cmd('sess2', 'echo one');
    remote_mail_cmd('sess2', 'echo two');
    remote_mail_cmd('sess2', 'echo three');

    # remote_foreign_require should still only have been called once
    is(scalar @main::_rpc_require_calls, 1,
       'remote_foreign_require called only once despite 3 RPC calls');

    delete_remote_mail_server('sess2');
};

# =========================================
# Test: _ensure_rpc_session — separate sessions for different servers
# =========================================

subtest '_ensure_rpc_session — separate sessions per server' => sub {
    plan tests => 3;

    save_remote_mail_server('sessA', {
        host        => 'server-a.example.com',
        webmin_host => 'server-a.example.com',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 0,
    });
    save_remote_mail_server('sessB', {
        host        => 'server-b.example.com',
        webmin_host => 'server-b.example.com',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 0,
    });

    %main::_rpc_initialized = ();
    @main::_rpc_require_calls = ();

    remote_mail_cmd('sessA', 'echo a');
    remote_mail_cmd('sessB', 'echo b');

    is(scalar @main::_rpc_require_calls, 2,
       'remote_foreign_require called once per unique server');

    # Verify they were for different hosts
    my @hosts = map { $_->{'server'}{'host'} } @main::_rpc_require_calls;
    ok(grep(/server-a/, @hosts), 'Session established for server A');
    ok(grep(/server-b/, @hosts), 'Session established for server B');

    delete_remote_mail_server('sessA');
    delete_remote_mail_server('sessB');
};

# =========================================
# Test: remote_mail_call establishes session before call
# =========================================

subtest 'remote_mail_call — establishes session' => sub {
    plan tests => 2;

    save_remote_mail_server('sess3', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    %main::_rpc_initialized = ();
    @main::_rpc_require_calls = ();

    remote_mail_call('sess3', 'webmin', 'get_webmin_version');

    is(scalar @main::_rpc_require_calls, 1,
       'remote_mail_call establishes session via remote_foreign_require');
    is($main::_rpc_require_calls[0]{'module'}, 'webmin',
       'Session established for webmin module');

    delete_remote_mail_server('sess3');
};

# =========================================
# Test: remote_mail_write establishes session before write
# =========================================

subtest 'remote_mail_write — establishes session' => sub {
    plan tests => 1;

    save_remote_mail_server('sess4', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    # Create a temp local file (remote_mail_write now reads file contents)
    my $tmpfile = "$main::module_config_directory/test-session.pem";
    open(my $fh, '>', $tmpfile) or die;
    print $fh "SESSION TEST\n";
    close($fh);

    %main::_rpc_initialized = ();
    @main::_rpc_require_calls = ();
    @main::_files_written = ();

    remote_mail_write('sess4', $tmpfile, '/etc/ssl/remote.pem');
    unlink($tmpfile);

    is(scalar @main::_rpc_require_calls, 1,
       'remote_mail_write establishes session via remote_foreign_require');

    delete_remote_mail_server('sess4');
};

# =========================================
# Test: remote_mail_cmd handles multi-line output from RPC
# Regression: backquote_command returns a LIST of lines through the RPC
# FIFO layer.  Without join(), scalar context gives the line count (e.g. 3)
# instead of the actual output content.
# =========================================

subtest 'remote_mail_cmd — multi-line output joined correctly' => sub {
    plan tests => 3;

    save_remote_mail_server('ml1', {
        host        => 'vh2.trinsik.io',
        webmin_host => 'vh2.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'secret',
        default     => 1,
    });

    %main::_rpc_initialized = ();
    @main::_rpc_calls = ();

    my ($out, $exit) = remote_mail_cmd('ml1', 'echo hello');

    # The mock returns ("ok\n", "\n", "__RC__=0\n") — 3 list elements.
    # If code used scalar context: $out would be "3" (the count) — WRONG
    # With join(): $out should contain the actual content — CORRECT
    isnt($out, '3', 'Output is NOT the line count (regression check)');
    like($out, qr/ok/, 'Output contains actual command output');
    is($exit, 0, 'Exit code correctly parsed from multi-line output');

    delete_remote_mail_server('ml1');
};

# =========================================
# Test: ACL — undefined or empty access allows all (root user fix)
# Regression: can_edit_domain() failed for root users because
# $access{'dom'} was undefined, not '*'.
# =========================================

subtest 'ACL — undefined access allows all (root user)' => sub {
    plan tests => 3;

    # Save original and test with undefined
    my $orig = $main::access{'dom'};

    delete $main::access{'dom'};
    ok(can_edit_domain('anything.com'), 'Undefined ACL allows all (root user)');

    $main::access{'dom'} = '';
    ok(can_edit_domain('anything.com'), 'Empty string ACL allows all');

    $main::access{'dom'} = 'specific.com other.com';
    ok(!can_edit_domain('blocked.com'), 'Specific ACL blocks unlisted domain');

    # Restore
    $main::access{'dom'} = $orig;
};

done_testing();
