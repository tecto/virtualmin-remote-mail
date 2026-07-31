#!/usr/bin/perl
# 05-ssl.t — Test SSL sync and disk usage operations
use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);

# Load mock Webmin and library + feature hooks
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# See t/mock-webmin.pl: skips unless the CLI-API architecture is present.
require_cli_api_arch();

# Helper: extract shell commands from RPC calls (backquote_command args)
# and strip backslash escaping for easier regex matching
sub captured_cmds {
    my @cmds;
    foreach my $call (@main::_rpc_calls) {
        if ($call->{'func'} eq 'backquote_command') {
            push(@cmds, $call->{'args'}[0]);
            }
        }
    my $raw = join("\n", @cmds);
    $raw =~ s/\\(.)/$1/g;   # remove backslash escapes
    return $raw;
}

# Set up a test server
save_remote_mail_server('1', {
    host         => 'email1.trinsik.io',
    webmin_host  => 'email1.trinsik.io',
    webmin_port  => 10000,
    webmin_ssl   => 1,
    webmin_user  => 'root',
    webmin_pass  => 'secret',
    dkim_selector => '202307',
    default      => 1,
});

# =========================================
# Test: get_remote_dkim_public_key
# =========================================

subtest 'get_remote_dkim_public_key' => sub {
    plan tests => 1;

    my $key = get_remote_dkim_public_key('1', 'testdomain.com', '202307');
    # Mock returns "ok\n", which has no DKIM key format — returns empty string
    ok(!$key, 'Returns falsy when key file not in expected format');
};

# =========================================
# Test: sync_remote_mail_ssl
# =========================================

subtest 'sync_remote_mail_ssl' => sub {
    plan tests => 9;

    # Create temp cert files
    my $tmpdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmpdir/ssl.cert") or die;
    print $fh "CERT DATA\n";
    close($fh);
    open($fh, '>', "$tmpdir/ssl.key") or die;
    print $fh "KEY DATA\n";
    close($fh);
    open($fh, '>', "$tmpdir/ssl.ca") or die;
    print $fh "CA DATA\n";
    close($fh);

    @main::_rpc_calls = ();
    @main::_files_written = ();
    my $d = {
        'dom'       => 'testdomain.com',
        'ssl_cert'  => "$tmpdir/ssl.cert",
        'ssl_key'   => "$tmpdir/ssl.key",
        'ssl_chain' => "$tmpdir/ssl.ca",
    };
    my $err = sync_remote_mail_ssl($d, '1');
    is($err, undef, 'sync_remote_mail_ssl succeeds');

    # Verify temp directory created on remote
    my $cmds = captured_cmds();
    like($cmds, qr/mkdir -p \/tmp\/\.ssl-sync/, 'Creates temp directory on remote');

    # Verify cert/key/ca files written to temp dir via remote_write
    ok(scalar @main::_files_written >= 2, 'At least 2 files written via RPC');
    my @remotes = map { $_->{'remote'} } @main::_files_written;
    ok(grep(/\.ssl-sync.*cert\.pem/, @remotes), 'cert.pem transferred to temp dir');
    ok(grep(/\.ssl-sync.*key\.pem/, @remotes), 'key.pem transferred to temp dir');
    ok(grep(/\.ssl-sync.*ca\.pem/, @remotes), 'ca.pem transferred when chain provided');

    # Verify install-cert called via virtualmin CLI
    like($cmds, qr/virtualmin install-cert/, 'Calls virtualmin install-cert');

    # Verify RPC calls to sync_dovecot_ssl_cert and sync_postfix_ssl_cert
    my @vs_calls = grep { $_->{'module'} eq 'virtual-server' } @main::_rpc_calls;
    ok((grep { $_->{'func'} eq 'sync_dovecot_ssl_cert' } @vs_calls),
       'Calls sync_dovecot_ssl_cert on remote');
    ok((grep { $_->{'func'} eq 'sync_postfix_ssl_cert' } @vs_calls),
       'Calls sync_postfix_ssl_cert on remote');
};

# =========================================
# Test: sync_remote_mail_ssl with missing cert
# =========================================

subtest 'sync_remote_mail_ssl - missing cert' => sub {
    plan tests => 1;

    my $d = {
        'dom'      => 'testdomain.com',
        'ssl_cert' => '/nonexistent/path/ssl.cert',
        'ssl_key'  => '/nonexistent/path/ssl.key',
    };
    my $err = sync_remote_mail_ssl($d, '1');
    like($err, qr/not found/, 'Reports error for missing certificate');
};

# =========================================
# Test: feature_modify triggers SSL sync on cert change
# =========================================

subtest 'feature_modify - SSL cert change triggers sync' => sub {
    plan tests => 4;

    # Create temp cert files for old and new
    my $tmpdir = tempdir(CLEANUP => 1);
    for my $f (qw(old.cert old.key new.cert new.key)) {
        open(my $fh, '>', "$tmpdir/$f") or die;
        print $fh uc($f) . " DATA\n";
        close($fh);
    }

    # Set up domain state so feature_modify can find the server
    my %state = ( 'server_id' => '1', 'setup_time' => time(),
                  'domain_created' => 1, 'dns_configured' => 1 );
    save_domain_state('ssltest.com', \%state);

    my $oldd = {
        'dom'       => 'ssltest.com',
        'dns'       => 1,
        'ssl_cert'  => "$tmpdir/old.cert",
        'ssl_key'   => "$tmpdir/old.key",
        $main::module_name => 1,
        'remote_mail_server' => '1',
    };
    my $d = {
        'dom'       => 'ssltest.com',
        'dns'       => 1,
        'ssl_cert'  => "$tmpdir/new.cert",
        'ssl_key'   => "$tmpdir/new.key",
        $main::module_name => 1,
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    @main::_files_written = ();
    @main::_progress_messages = ();

    my $ok = feature_modify($d, $oldd);
    is($ok, 1, 'feature_modify returns success');

    # Verify SSL sync progress message was printed
    my @msgs = map { $_->{'msg'} } @main::_progress_messages;
    ok((grep { /SSL/ } @msgs), 'SSL sync progress message printed');

    # Verify install-cert was called (via backquote_command)
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin install-cert/, 'feature_modify calls install-cert on cert change');

    # Verify ssl_synced timestamp was set
    ok($d->{'remote_mail_ssl_synced'}, 'ssl_synced timestamp set on domain');

    delete_domain_state('ssltest.com');
};

subtest 'feature_modify - no SSL sync when cert unchanged' => sub {
    plan tests => 2;

    my $tmpdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmpdir/ssl.cert") or die;
    print $fh "CERT DATA\n";
    close($fh);
    open($fh, '>', "$tmpdir/ssl.key") or die;
    print $fh "KEY DATA\n";
    close($fh);

    my %state = ( 'server_id' => '1', 'setup_time' => time(),
                  'domain_created' => 1, 'dns_configured' => 1 );
    save_domain_state('nochange.com', \%state);

    my $same_d = {
        'dom'       => 'nochange.com',
        'dns'       => 1,
        'ssl_cert'  => "$tmpdir/ssl.cert",
        'ssl_key'   => "$tmpdir/ssl.key",
        $main::module_name => 1,
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    @main::_progress_messages = ();

    my $ok = feature_modify($same_d, $same_d);
    is($ok, 1, 'feature_modify returns success');

    # No SSL-related RPC calls should have been made
    my @vs_calls = grep { $_->{'module'} eq 'virtual-server' &&
                          $_->{'func'} =~ /sync_.*_ssl_cert/ } @main::_rpc_calls;
    is(scalar @vs_calls, 0, 'No SSL sync calls when cert unchanged');

    delete_domain_state('nochange.com');
};

# =========================================
# Test: get_remote_disk_usage
# =========================================

subtest 'get_remote_disk_usage' => sub {
    plan tests => 2;

    my $d = { 'dom' => 'testdomain.com' };
    my $bytes = get_remote_disk_usage($d, '1');
    # Mock returns "ok\n" which won't parse as digits, so 0
    is($bytes, 0, 'Returns 0 when du output is not numeric');

    # Verify caching — file should exist
    ok(-f "$main::module_config_directory/domains/testdomain.com.du",
       'Cache file created');
};

# Clean up
delete_remote_mail_server('1');

done_testing();
