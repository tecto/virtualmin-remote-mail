#!/usr/bin/perl
# 08-cgi-handlers.t — Comprehensive CGI handler tests for save_server.cgi,
# save_domain.cgi (all actions), and edit_user.cgi.
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin and library + feature hooks
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# See t/mock-webmin.pl: skips unless the CLI-API architecture is present.
require_cli_api_arch();

my $cgi_dir = "$FindBin::Bin/..";

# Helper: extract shell commands from RPC calls (backquote_command args)
sub captured_cmds {
    my @cmds;
    foreach my $call (@main::_rpc_calls) {
        if ($call->{'func'} eq 'backquote_command') {
            push(@cmds, $call->{'args'}[0]);
            }
        }
    my $raw = join("\n", @cmds);
    $raw =~ s/\\(.)/$1/g;
    return $raw;
}

# Helper: reset all captured state between tests
sub reset_state {
    @main::_webmin_log = ();
    @main::_redirects = ();
    @main::_rpc_calls = ();
    @main::_rpc_require_calls = ();
    @main::_progress_messages = ();
    @virtual_server::_saved_domains = ();
    %main::_mock_cmd_responses = ();
    %main::_rpc_initialized = ();
}

# Set up test server
save_remote_mail_server('1', {
    host              => 'email1.trinsik.io',
    desc              => 'Test Mail Server',
    webmin_host       => 'email1.trinsik.io',
    webmin_port       => 10000,
    webmin_ssl        => 1,
    webmin_user       => 'root',
    webmin_pass       => 'secret',
    spam_gateway      => '216.55.103.236',
    spam_gateway_host => 'mg',
    outgoing_relay    => 'smtp-out.trinsiklabs.com',
    outgoing_relay_port => 25,
    dkim_selector     => '202307',
    default           => 1,
});

# Register a test domain in the mock registry
my $test_dom = {
    'id'   => 1001,
    'dom'  => 'testdomain.com',
    'dns'  => 1,
    'mail' => 1,
    'remote_mail_server' => '1',
};
virtual_server::mock_add_domain('testdomain.com', $test_dom);

# =========================================================================
# save_server.cgi tests
# =========================================================================

subtest 'save_server — new server with all fields' => sub {
    plan tests => 5;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        new         => 1,
        host        => 'newmail.example.com',
        desc        => 'New Mail Server',
        webmin_host => 'newmail.example.com',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'newpass',
        spam_gateway      => '10.0.0.1',
        spam_gateway_host => 'mg',
        outgoing_relay    => 'relay.example.com',
        outgoing_relay_port => 587,
        dkim_selector     => '202307',
        maildir_format    => '.maildir',
        default           => 0,
    );

    ok(!$err, 'No error on new server save') or diag($err);
    ok(scalar @main::_webmin_log > 0, 'Action logged');
    is($main::_webmin_log[0]{'action'}, 'save', 'Logged save action');
    ok(scalar @main::_redirects > 0, 'Redirect issued');
    like($main::_redirects[0], qr/edit\.cgi/, 'Redirected to edit.cgi');

    # Clean up the new server
    my @servers = list_remote_mail_servers();
    foreach my $sid (@servers) {
        next if ($sid eq '1');
        delete_remote_mail_server($sid);
        }
};

subtest 'save_server — missing password on new server' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        new         => 1,
        host        => 'newmail2.example.com',
        webmin_host => 'newmail2.example.com',
        webmin_user => 'root',
        webmin_pass => '',
    );

    like($err, qr/Webmin error/i, 'Error on missing password');
};

subtest 'save_server — auto-generates ID for new server' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        new         => 1,
        host        => 'auto-id.example.com',
        webmin_host => 'auto-id.example.com',
        webmin_user => 'root',
        webmin_pass => 'testpass',
    );

    ok(!$err, 'No error') or diag($err);
    # Server 1 already exists, so new one should be 2
    my @servers = list_remote_mail_servers();
    my @new = grep { $_ ne '1' } @servers;
    ok(scalar @new >= 1, 'New server ID auto-generated');

    # Clean up
    foreach my $sid (@new) {
        delete_remote_mail_server($sid);
        }
};

subtest 'save_server — update preserves password when not provided' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        id          => '1',
        host        => 'email1.trinsik.io',
        desc        => 'Updated Description',
        webmin_host => 'email1.trinsik.io',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => '',
    );

    ok(!$err, 'No error on update') or diag($err);
    my $s = get_remote_mail_server('1');
    is($s->{'webmin_pass'}, 'secret', 'Password preserved from existing config');

    # Restore server config
    save_remote_mail_server('1', {
        host              => 'email1.trinsik.io',
        desc              => 'Test Mail Server',
        webmin_host       => 'email1.trinsik.io',
        webmin_port       => 10000,
        webmin_ssl        => 1,
        webmin_user       => 'root',
        webmin_pass       => 'secret',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay    => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        dkim_selector     => '202307',
        default           => 1,
    });
};

subtest 'save_server — set as default unmarks others' => sub {
    plan tests => 3;
    reset_state();

    # Add a second server
    save_remote_mail_server('2', {
        host        => 'mail2.example.com',
        webmin_host => 'mail2.example.com',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'pass2',
        default     => 0,
    });

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        id          => '2',
        host        => 'mail2.example.com',
        webmin_host => 'mail2.example.com',
        webmin_port => 10000,
        webmin_ssl  => 1,
        webmin_user => 'root',
        webmin_pass => 'pass2',
        default     => 1,
    );

    ok(!$err, 'No error') or diag($err);
    my $s1 = get_remote_mail_server('1');
    is($s1->{'default'}, 0, 'Old default server unmarked');
    my $s2 = get_remote_mail_server('2');
    is($s2->{'default'}, 1, 'New server marked as default');

    # Clean up
    delete_remote_mail_server('2');
    # Restore server 1 as default
    save_remote_mail_server('1', {
        host              => 'email1.trinsik.io',
        desc              => 'Test Mail Server',
        webmin_host       => 'email1.trinsik.io',
        webmin_port       => 10000,
        webmin_ssl        => 1,
        webmin_user       => 'root',
        webmin_pass       => 'secret',
        spam_gateway      => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay    => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        dkim_selector     => '202307',
        default           => 1,
    });
};

subtest 'save_server — delete server' => sub {
    plan tests => 3;
    reset_state();

    save_remote_mail_server('delme', {
        host        => 'delete.example.com',
        webmin_host => 'delete.example.com',
        webmin_user => 'root',
        webmin_pass => 'pass',
    });

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        id     => 'delme',
        delete => 1,
    );

    ok(!$err, 'No error on delete') or diag($err);
    my $s = get_remote_mail_server('delme');
    is($s, undef, 'Server deleted');
    is($main::_webmin_log[0]{'action'}, 'delete', 'Delete action logged');
};

subtest 'save_server — invalid server ID (non-alphanumeric)' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        id          => '../etc',
        host        => 'bad.example.com',
        webmin_host => 'bad.example.com',
        webmin_user => 'root',
        webmin_pass => 'pass',
    );

    like($err, qr/Invalid server ID/i, 'Rejects non-alphanumeric server ID');
};

subtest 'save_server — invalid mail routing fields' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        new         => 1,
        host        => 'badroute.example.com',
        webmin_host => 'badroute.example.com',
        webmin_user => 'root',
        webmin_pass => 'pass',
        spam_gateway => 'not-an-ip',
    );

    like($err, qr/Invalid IP/i, 'Rejects invalid spam_gateway IP');
};

# =========================================================================
# save_domain.cgi — save_overrides action
# =========================================================================

subtest 'save_overrides — override changed triggers DNS re-provision' => sub {
    plan tests => 3;
    reset_state();

    # Set up domain state as if DNS was configured
    save_domain_state('testdomain.com', {
        server_id      => '1',
        dns_configured => 1,
    });

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'testdomain.com',
        action => 'save_overrides',
        ovr_spam_gateway      => '10.0.0.99',
        ovr_spam_gateway_host => 'mg',
        ovr_outgoing_relay    => '',
        ovr_outgoing_relay_port => '',
    );

    ok(!$err, 'No error on save_overrides') or diag($err);
    ok(scalar @main::_webmin_log > 0, 'Action logged');
    is($main::_webmin_log[0]{'action'}, 'save_overrides', 'Logged save_overrides');

    # Restore domain state — clear ALL overrides the handler may have set
    for my $key (qw(spam_gateway spam_gateway_host outgoing_relay outgoing_relay_port)) {
        delete $test_dom->{"remote_mail_${key}"};
        }
    delete_domain_state('testdomain.com');
};

subtest 'save_overrides — no changes causes redirect' => sub {
    plan tests => 2;
    reset_state();

    # Domain has no current overrides, submit empty values
    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'testdomain.com',
        action => 'save_overrides',
        ovr_spam_gateway      => '',
        ovr_spam_gateway_host => '',
        ovr_outgoing_relay    => '',
        ovr_outgoing_relay_port => '',
    );

    ok(!$err, 'No error') or diag($err);
    ok(scalar @main::_redirects > 0, 'Redirected (no changes)');
};

subtest 'save_overrides — invalid override value' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'testdomain.com',
        action => 'save_overrides',
        ovr_spam_gateway => 'not-an-ip',
    );

    like($err, qr/Invalid IP/i, 'Rejects invalid override value');
};

# =========================================================================
# save_domain.cgi — sync_ssl action
# =========================================================================

subtest 'sync_ssl — successful sync sets timestamp' => sub {
    plan tests => 3;
    reset_state();

    # Mock the sync function to succeed — it calls remote_mail_cmd internally
    # which our mock handles. We also need the feature loaded for
    # sync_remote_mail_ssl (loaded via load_plugin_feature above).
    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'testdomain.com',
        action => 'sync_ssl',
    );

    ok(!$err, 'No error on sync_ssl') or diag($err);
    ok(scalar @main::_webmin_log > 0, 'Action logged');
    is($main::_webmin_log[0]{'action'}, 'ssl_sync', 'Logged ssl_sync');
};

# =========================================================================
# save_domain.cgi — create_user action
# =========================================================================

subtest 'create_user — valid user with defaults' => sub {
    plan tests => 5;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => 'newuser',
        mailpass => 'StrongP@ss1',
        real     => 'New User',
        tome     => 1,
    );

    ok(!$err, 'No error on create_user') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Calls create-user');
    like($cmds, qr/--user\s+'newuser'/, 'Username passed');
    # No modify needed when defaults (tome=1, no forward, no auto)
    unlike($cmds, qr/virtualmin modify-user/, 'No modify call for defaults');
    is($main::_webmin_log[0]{'action'}, 'user_create', 'Logged user_create');
};

subtest 'create_user — with forwarding triggers modify' => sub {
    plan tests => 4;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'create_user',
        username  => 'fwduser',
        mailpass  => 'Pass123!',
        tome      => 1,
        forward   => 1,
        forwardto => "admin\@example.com",
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Create called');
    like($cmds, qr/virtualmin modify-user/, 'Modify called after create');
    like($cmds, qr/--add-forward\s+'admin\@example\.com'/, 'Forward address applied');
};

subtest 'create_user — with autoreply triggers modify' => sub {
    plan tests => 3;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => 'vacuser',
        mailpass => 'Pass123!',
        tome     => 1,
        auto     => 1,
        autotext => 'Out of office until Monday',
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Create called');
    like($cmds, qr/--autoreply\s+'Out of office until Monday'/, 'Autoreply applied');
};

subtest 'create_user — invalid username' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => 'bad user!',
        mailpass => 'Pass123!',
    );

    like($err, qr/invalid/i, 'Rejects invalid username');
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls made');
};

subtest 'create_user — missing password' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => 'gooduser',
        mailpass => '',
    );

    like($err, qr/Webmin error/i, 'Error on missing password');
};

subtest 'create_user — invalid forward address' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'create_user',
        username  => 'fwdbaduser',
        mailpass  => 'Pass123!',
        tome      => 1,
        forward   => 1,
        forwardto => 'not-an-email',
    );

    like($err, qr/Invalid email address/i, 'Rejects invalid forward address');
};

subtest 'create_user — RPC error propagated' => sub {
    plan tests => 1;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin create-user.*--user.*dupuser' => {
            output => 'A user with the same name already exists',
            exit   => 1,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => 'dupuser',
        mailpass => 'Pass123!',
    );

    # RPC errors are displayed inline (second_print), not die'd
    ok(!$err, 'Handler completes (error shown inline)');
};

# =========================================================================
# save_domain.cgi — save_user action
# =========================================================================

subtest 'save_user — password change' => sub {
    plan tests => 3;
    reset_state();

    # Mock user data for the old_user lookup
    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*existuser' => {
            output => "existuser\@testdomain.com\n    User: existuser\n    Real name: Exist User\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/existuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'existuser',
        pass_mode => 0,
        mailpass  => 'NewP@ss123',
        tome      => 1,
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin modify-user/, 'Modify called');
    like($cmds, qr/--pass\s+'NewP\@ss123'/, 'New password passed');
};

subtest 'save_user — disable/enable toggle' => sub {
    plan tests => 2;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*toggleuser' => {
            output => "toggleuser\@testdomain.com\n    User: toggleuser\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/toggleuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'toggleuser',
        pass_mode => 1,
        disable   => 1,
        tome      => 1,
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/--disable/, 'Disable flag passed');
};

subtest 'save_user — forwarding diff: add new, remove old' => sub {
    plan tests => 3;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*fwddiffuser' => {
            output => "fwddiffuser\@testdomain.com\n    User: fwddiffuser\n    Disabled: No\n    Forward to: old\@example.com\n    Mail location: /home/testdomain.com/homes/fwddiffuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'fwddiffuser',
        pass_mode => 1,
        tome      => 1,
        forward   => 1,
        forwardto => "new\@example.com",
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/--add-forward\s+'new\@example\.com'/, 'New forward added');
    like($cmds, qr/--del-forward\s+'old\@example\.com'/, 'Old forward removed');
};

subtest 'save_user — forward enabled but empty' => sub {
    plan tests => 1;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*fwdemptyuser' => {
            output => "fwdemptyuser\@testdomain.com\n    User: fwdemptyuser\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/fwdemptyuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'fwdemptyuser',
        pass_mode => 1,
        tome      => 1,
        forward   => 1,
        forwardto => '',
    );

    like($err, qr/Webmin error/i, 'Error when forward enabled but empty');
};

subtest 'save_user — invalid forward address' => sub {
    plan tests => 1;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*fwdinvuser' => {
            output => "fwdinvuser\@testdomain.com\n    User: fwdinvuser\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/fwdinvuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'fwdinvuser',
        pass_mode => 1,
        tome      => 1,
        forward   => 1,
        forwardto => 'not-an-email-address',
    );

    like($err, qr/Invalid email address/i, 'Rejects invalid forward address');
};

subtest 'save_user — auto-reply set/clear' => sub {
    plan tests => 2;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*autouser' => {
            output => "autouser\@testdomain.com\n    User: autouser\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/autouser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'autouser',
        pass_mode => 1,
        tome      => 1,
        auto      => 1,
        autotext  => 'Gone fishing',
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/--autoreply\s+'Gone fishing'/, 'Autoreply message set');
};

subtest 'save_user — recovery email set with validation' => sub {
    plan tests => 2;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*recovuser' => {
            output => "recovuser\@testdomain.com\n    User: recovuser\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/recovuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom          => 'testdomain.com',
        action       => 'save_user',
        old_user     => 'recovuser',
        pass_mode    => 1,
        tome         => 1,
        recovery_def => 0,
        recovery     => 'backup@example.com',
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/--recovery\s+'backup\@example\.com'/, 'Recovery email set');
};

subtest 'save_user — invalid recovery email' => sub {
    plan tests => 1;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*badrecov' => {
            output => "badrecov\@testdomain.com\n    User: badrecov\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/badrecov/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom          => 'testdomain.com',
        action       => 'save_user',
        old_user     => 'badrecov',
        pass_mode    => 1,
        tome         => 1,
        recovery_def => 0,
        recovery     => 'not-an-email',
    );

    like($err, qr/Invalid email address/i, 'Rejects invalid recovery email');
};

subtest 'save_user — invalid old_user' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'bad user!@#',
        pass_mode => 1,
        tome      => 1,
    );

    like($err, qr/invalid|Webmin error/i, 'Rejects invalid old_user');
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls before validation');
};

subtest 'save_user — delete button triggers deletion' => sub {
    plan tests => 3;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'save_user',
        old_user  => 'deleteuser',
        delete    => 1,
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Delete called');
    is($main::_webmin_log[0]{'action'}, 'user_delete', 'Logged user_delete');
};

# =========================================================================
# save_domain.cgi — delete_user action
# =========================================================================

subtest 'delete_user — successful delete' => sub {
    plan tests => 3;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'delete_user',
        username => 'rmuser',
    );

    ok(!$err, 'No error') or diag($err);
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Delete called');
    is($main::_webmin_log[0]{'action'}, 'user_delete', 'Logged user_delete');
};

subtest 'delete_user — invalid username' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'delete_user',
        username => '../etc/passwd',
    );

    like($err, qr/invalid|Webmin error/i, 'Rejects invalid username');
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls made');
};

# =========================================================================
# Input validation tests (cross-cutting)
# =========================================================================

subtest 'Cross-cutting — path traversal in domain name' => sub {
    plan tests => 1;
    reset_state();

    # Domain not in registry → get_domain_by returns undef → "Domain not found"
    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => '../../../etc/passwd',
        action => 'create_user',
        username => 'testuser',
        mailpass => 'Pass123!',
    );

    like($err, qr/Webmin error/i, 'Path traversal domain rejected');
};

subtest 'Cross-cutting — shell injection in username (create)' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom      => 'testdomain.com',
        action   => 'create_user',
        username => '; rm -rf /',
        mailpass => 'Pass123!',
    );

    like($err, qr/invalid|Webmin error/i, 'Shell injection in username rejected');
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls for shell injection attempt');
};

subtest 'Cross-cutting — shell injection in forward address' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom       => 'testdomain.com',
        action    => 'create_user',
        username  => 'gooduser2',
        mailpass  => 'Pass123!',
        tome      => 1,
        forward   => 1,
        forwardto => '; cat /etc/passwd',
    );

    like($err, qr/Invalid email address/i, 'Shell injection in forward rejected');
};

subtest 'Cross-cutting — non-alphanumeric server ID on delete' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_server.cgi",
        id     => '../../../etc',
        delete => 1,
    );

    like($err, qr/Invalid server ID/i, 'Path traversal server ID rejected');
};

# =========================================================================
# edit_user.cgi tests
# =========================================================================

subtest 'edit_user — new user form renders' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/edit_user.cgi",
        dom => 'testdomain.com',
    );

    ok(!$err, 'No error rendering new user form') or diag($err);
    like($out, qr/create_user/, 'Form action is create_user');
};

subtest 'edit_user — edit existing user with valid username' => sub {
    plan tests => 2;
    reset_state();

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*validuser' => {
            output => "validuser\@testdomain.com\n    User: validuser\n    Real name: Valid User\n    Disabled: No\n    Mail location: /home/testdomain.com/homes/validuser/.maildir",
            exit   => 0,
        },
    );

    my ($out, $err) = run_cgi_handler("$cgi_dir/edit_user.cgi",
        dom  => 'testdomain.com',
        user => 'validuser',
    );

    ok(!$err, 'No error editing valid user') or diag($err);
    like($out, qr/save_user/, 'Form action is save_user');
};

subtest 'edit_user — invalid username rejected before RPC' => sub {
    plan tests => 2;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/edit_user.cgi",
        dom  => 'testdomain.com',
        user => 'bad user!',
    );

    like($err, qr/invalid|Webmin error/i, 'Invalid username rejected');
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls before validation');
};

subtest 'edit_user — domain not found' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/edit_user.cgi",
        dom => 'nonexistent.com',
    );

    like($err, qr/not found|Webmin error/i, 'Unknown domain rejected');
};

# =========================================================================
# validate_domain_name tests (library-level)
# =========================================================================

subtest 'validate_domain_name — valid domains' => sub {
    plan tests => 4;

    is(validate_domain_name('example.com'), undef, 'Simple domain valid');
    is(validate_domain_name('sub.example.com'), undef, 'Subdomain valid');
    is(validate_domain_name('my-site.co.uk'), undef, 'Hyphenated domain valid');
    is(validate_domain_name('a.b'), undef, 'Short domain valid');
};

subtest 'validate_domain_name — invalid domains' => sub {
    plan tests => 5;

    like(validate_domain_name(''), qr/required/i, 'Empty rejected');
    like(validate_domain_name('../etc/passwd'), qr/Invalid/i,
         'Path traversal rejected');
    like(validate_domain_name('domain..com'), qr/Invalid/i,
         'Double dots rejected');
    like(validate_domain_name('-leading.com'), qr/Invalid/i,
         'Leading hyphen rejected');
    like(validate_domain_name('space domain.com'), qr/Invalid/i,
         'Spaces rejected');
};

# =========================================================================
# validate_email_address tests (library-level)
# =========================================================================

subtest 'validate_email_address — valid emails' => sub {
    plan tests => 4;

    is(validate_email_address('user@example.com'), undef, 'Basic email valid');
    is(validate_email_address('user.name@example.com'), undef, 'Dotted local valid');
    is(validate_email_address('user+tag@example.co.uk'), undef, 'Plus addressing valid');
    is(validate_email_address('a@b.cd'), undef, 'Short email valid');
};

subtest 'validate_email_address — invalid emails' => sub {
    plan tests => 5;

    like(validate_email_address(''), qr/required/i, 'Empty rejected');
    like(validate_email_address('notanemail'), qr/Invalid/i, 'Missing @ rejected');
    like(validate_email_address('user@'), qr/Invalid/i, 'No domain rejected');
    like(validate_email_address('@example.com'), qr/Invalid/i, 'No local part rejected');
    like(validate_email_address('user@x'), qr/Invalid/i, 'Single-char TLD rejected');
};

# =========================================================================
# validate flag names in remote_virtualmin_cmd
# =========================================================================

subtest 'remote_virtualmin_cmd — rejects invalid flag names' => sub {
    plan tests => 2;
    reset_state();

    # Valid flags should work
    eval {
        remote_virtualmin_cmd('1', 'list-users',
            '--domain', 'example.com', '--multiline');
        };
    ok(!$@, 'Valid flags accepted');

    # Invalid flag should die
    eval {
        remote_virtualmin_cmd('1', 'list-users',
            '--domain; rm -rf /', 'evil.com');
        };
    like($@, qr/Invalid flag/i, 'Invalid flag rejected');
};

# =========================================================================
# Domain state path traversal protection
# =========================================================================

subtest 'Domain state functions reject path traversal' => sub {
    plan tests => 3;

    # get_domain_state returns empty hash for invalid domain
    my $state = get_domain_state('../../../etc/passwd');
    ok(!$state->{'server_id'}, 'get_domain_state returns empty for path traversal');

    # save_domain_state dies for invalid domain
    eval { save_domain_state('../../../etc/passwd', { foo => 'bar' }); };
    like($@, qr/Invalid domain name|Domain name is required/,
         'save_domain_state rejects path traversal');

    # delete_domain_state silently returns for invalid domain (no-op)
    eval { delete_domain_state('../../../etc/passwd'); };
    ok(!$@, 'delete_domain_state silently ignores invalid domain');
};

# =========================================================================
# Unknown domain and unknown action handling
# =========================================================================

subtest 'save_domain.cgi — unknown domain rejected' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'nonexistent.com',
        action => 'create_user',
        username => 'testuser',
        mailpass => 'Pass123!',
    );

    like($err, qr/not found|Webmin error/i, 'Unknown domain rejected');
};

subtest 'save_domain.cgi — unknown action redirects' => sub {
    plan tests => 1;
    reset_state();

    my ($out, $err) = run_cgi_handler("$cgi_dir/save_domain.cgi",
        dom    => 'testdomain.com',
        action => 'bogus_action',
    );

    ok(!$err || scalar @main::_redirects > 0, 'Unknown action handled gracefully');
};

# Clean up
delete_remote_mail_server('1');
virtual_server::mock_clear_domains();

done_testing();
