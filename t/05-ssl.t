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
    plan tests => 5;

    # Create temp cert files
    my $tmpdir = tempdir(CLEANUP => 1);
    open(my $fh, '>', "$tmpdir/ssl.cert") or die;
    print $fh "CERT DATA\n";
    close($fh);
    open($fh, '>', "$tmpdir/ssl.key") or die;
    print $fh "KEY DATA\n";
    close($fh);

    @main::_rpc_calls = ();
    @main::_files_written = ();
    my $d = {
        'dom'       => 'testdomain.com',
        'ssl_cert'  => "$tmpdir/ssl.cert",
        'ssl_key'   => "$tmpdir/ssl.key",
    };
    my $err = sync_remote_mail_ssl($d, '1');
    is($err, undef, 'sync_remote_mail_ssl succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/ssl.*mail|mkdir/, 'Creates remote SSL directory');

    # Verify file transfers via remote_write
    ok(scalar @main::_files_written >= 2, 'At least 2 files written via RPC');
    my @remotes = map { $_->{'remote'} } @main::_files_written;
    ok(grep(/fullchain\.pem/, @remotes), 'fullchain.pem transferred');
    ok(grep(/privkey\.pem/, @remotes), 'privkey.pem transferred');
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
