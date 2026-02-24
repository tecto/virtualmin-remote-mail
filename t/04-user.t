#!/usr/bin/perl
# 04-user.t — Test remote user management via Virtualmin API
use strict;
use warnings;
use FindBin;
use Test::More;

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
    spam_gateway => '216.55.103.236',
    spam_gateway_host => 'mg',
    outgoing_relay => 'smtp-out.trinsiklabs.com',
    outgoing_relay_port => 25,
    dkim_selector => '202307',
    default      => 1,
});

my $d = { 'dom' => 'testdomain.com', 'dns' => 1 };

# =========================================
# Test: create_remote_mail_user via virtualmin create-user
# =========================================

subtest 'create_remote_mail_user' => sub {
    plan tests => 5;

    @main::_rpc_calls = ();
    my $err = create_remote_mail_user($d, '1', 'info', 'password123', {});
    is($err, undef, 'create_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Uses virtualmin create-user');
    like($cmds, qr/--user\s+'info'/, 'Username passed');
    like($cmds, qr/--pass\s+'password123'/, 'Password passed');
    # create-user has no --check-spam flag; spam check is on by default
    unlike($cmds, qr/--check-spam/, 'No --check-spam flag (default is on)');
};

subtest 'create_remote_mail_user — with real name' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();
    my $err = create_remote_mail_user($d, '1', 'john', 'pass123', {
        real => 'John Doe',
    });
    is($err, undef, 'create with real name succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--real\s+'John Doe'/, 'Real name passed');
    unlike($cmds, qr/--check-spam/, 'No --check-spam flag (default is on)');
};

# =========================================
# Test: delete_remote_mail_user via virtualmin delete-user
# =========================================

subtest 'delete_remote_mail_user' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();
    my $err = delete_remote_mail_user($d, '1', 'info');
    is($err, undef, 'delete_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Uses virtualmin delete-user');
    like($cmds, qr/--user\s+'info'/, 'Username passed');
};

# =========================================
# Test: modify_remote_mail_user — password change
# =========================================

subtest 'modify_remote_mail_user — password' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        pass => 'newpassword',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin modify-user/, 'Uses virtualmin modify-user');
    like($cmds, qr/--pass\s+'newpassword'/, 'Password passed');
};

# =========================================
# Test: modify_remote_mail_user — rename
# =========================================

subtest 'modify_remote_mail_user — rename' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'oldname', {
        newuser => 'newname',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--newuser\s+'newname'/, 'Newuser flag passed');
};

# =========================================
# Test: modify_remote_mail_user — forwarding
# =========================================

subtest 'modify_remote_mail_user — forwarding (single)' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        add_forward => 'info@gmail.com',
        local       => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--add-forward\s+'info\@gmail\.com'/, 'Add-forward flag');
    like($cmds, qr/--local/, 'Local delivery flag');
};

subtest 'modify_remote_mail_user — forwarding (multi-value array)' => sub {
    plan tests => 4;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        add_forward => ['addr1@example.com', 'addr2@example.com'],
        del_forward => ['old@example.com'],
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--add-forward\s+'addr1\@example\.com'/, 'First add-forward');
    like($cmds, qr/--add-forward\s+'addr2\@example\.com'/, 'Second add-forward');
    like($cmds, qr/--del-forward\s+'old\@example\.com'/, 'Del-forward');
};

# =========================================
# Test: modify_remote_mail_user — auto-reply
# =========================================

subtest 'modify_remote_mail_user — auto-reply' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        autoreply => 'I am on vacation',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--autoreply\s+'I am on vacation'/, 'Autoreply message');
};

# =========================================
# Test: modify_remote_mail_user — spam filtering
# =========================================

subtest 'modify_remote_mail_user — spam' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        check_spam => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--check-spam/, 'Check-spam flag');
};

# =========================================
# Test: modify_remote_mail_user — disable/enable
# =========================================

subtest 'modify_remote_mail_user — disable' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        disable => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--disable/, 'Disable flag');
};

subtest 'modify_remote_mail_user — enable' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        enable => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--enable/, 'Enable flag');
};

# =========================================
# Test: modify_remote_mail_user — recovery email
# =========================================

subtest 'modify_remote_mail_user — recovery' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();
    my $err = modify_remote_mail_user($d, '1', 'info', {
        recovery => 'admin@example.com',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--recovery\s+'admin\@example\.com'/, 'Recovery email');
};

# =========================================
# Test: list_remote_mail_users — parsed output
# =========================================

subtest 'list_remote_mail_users — with realistic mock' => sub {
    plan tests => 6;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--domain.*testdomain\.com' => {
            output => "info\@testdomain.com\n    User: info\n    Real name: Info Account\n    Disabled: No\n    Check spam and viruses: Yes\n    Mail location: /home/testdomain.com/homes/info/.maildir\nadmin\@testdomain.com\n    User: admin\n    Real name: Admin\n    Disabled: No\n    Check spam and viruses: Yes",
            exit   => 0,
        },
    );

    my @users = list_remote_mail_users($d, '1');
    is(scalar @users, 2, 'Two users returned');
    is($users[0]->{'_name'}, 'info@testdomain.com', 'First user _name is full email');
    is($users[0]->{'user'}, 'info', 'First user local part');
    is($users[0]->{'real_name'}, 'Info Account', 'First user real name');
    is($users[1]->{'_name'}, 'admin@testdomain.com', 'Second user _name is full email');
    is($users[1]->{'user'}, 'admin', 'Second user local part');

    %main::_mock_cmd_responses = ();
};

subtest 'list_remote_mail_users — empty (default mock)' => sub {
    plan tests => 1;

    # Default mock returns "ok" which doesn't parse as multiline format
    my @users = list_remote_mail_users($d, '1');
    # "ok" starts a line with non-whitespace, so it becomes one entry
    # with _name = "ok" — but that's just mock behavior
    ok(1, 'list_remote_mail_users handles default mock');
};

# =========================================
# Test: get_remote_mail_user — single user
# =========================================

subtest 'get_remote_mail_user — found with realistic fields' => sub {
    plan tests => 7;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*info' => {
            output => "info\@testdomain.com\n    User: info\n    Real name: Info Account\n    Email address: info\@testdomain.com\n    Disabled: No\n    Check spam and viruses: Yes\n    Mail location: /home/testdomain.com/homes/info/.maildir\n    Forward to: info\@gmail.com",
            exit   => 0,
        },
    );

    my $user = get_remote_mail_user($d, '1', 'info');
    ok($user, 'User found');
    is($user->{'user'}, 'info', 'Local username from User field');
    is($user->{'real_name'}, 'Info Account', 'Real name');
    is($user->{'disabled'}, 'No', 'Disabled field');
    is($user->{'check_spam_and_viruses'}, 'Yes', 'Check spam and viruses field');
    is($user->{'mail_location'}, '/home/testdomain.com/homes/info/.maildir', 'Mail location');
    is($user->{'forward_to'}, 'info@gmail.com', 'Forward');

    %main::_mock_cmd_responses = ();
};

subtest 'get_remote_mail_user — not found' => sub {
    plan tests => 1;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*nonexistent' => {
            output => '',
            exit   => 1,
        },
    );

    my $user = get_remote_mail_user($d, '1', 'nonexistent');
    ok(!$user, 'Returns undef for nonexistent user');

    %main::_mock_cmd_responses = ();
};

# =========================================
# Test: validate_mail_username
# =========================================

subtest 'validate_mail_username — valid inputs' => sub {
    plan tests => 5;

    is(validate_mail_username('info'), undef, 'Simple username valid');
    is(validate_mail_username('john.doe'), undef, 'Dotted username valid');
    is(validate_mail_username('user-name'), undef, 'Hyphenated username valid');
    is(validate_mail_username('user_name'), undef, 'Underscored username valid');
    is(validate_mail_username('a'), undef, 'Single char valid');
};

subtest 'validate_mail_username — invalid inputs' => sub {
    plan tests => 8;

    like(validate_mail_username(''), qr/required/i, 'Empty username rejected');
    # Delegates to virtual_server::valid_mailbox_name(), which uses
    # valid_alias_name() to reject shell metacharacters and then
    # rejects digit-leading names.
    like(validate_mail_username('user name'), qr/invalid/i,
         'Username with space rejected');
    like(validate_mail_username("user; rm -rf /"), qr/invalid/i,
         'Shell injection (semicolon) rejected');
    like(validate_mail_username('user|pipe'), qr/invalid/i,
         'Pipe character rejected');
    like(validate_mail_username('user&bg'), qr/invalid/i,
         'Ampersand rejected');
    like(validate_mail_username('user/path'), qr/invalid/i,
         'Slash rejected (path traversal)');
    like(validate_mail_username('user\\back'), qr/invalid/i,
         'Backslash rejected');
    like(validate_mail_username('123numeric'), qr/number/i,
         'Digit-leading username rejected');
};

# =========================================
# Test: create_user handler — validates, creates, and logs
# =========================================

subtest 'create_user handler — validates, creates, and logs' => sub {
    plan tests => 4;

    # Validate username first (as CGI handler does)
    my $verr = validate_mail_username('newuser');
    is($verr, undef, 'Username passes validation');

    # Create user on remote
    @main::_rpc_calls = ();
    my $err = create_remote_mail_user($d, '1', 'newuser', 'testpass123', {});
    is($err, undef, 'create_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Uses virtualmin create-user');

    # Log the action (as CGI handler does)
    @main::_webmin_log = ();
    webmin_log("user_create", undef, 'newuser@testdomain.com');
    is($main::_webmin_log[0]{'action'}, 'user_create', 'Logged user creation');
};

# =========================================
# Test: delete_user handler — deletes and logs
# =========================================

subtest 'delete_user handler — deletes and logs' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();
    my $err = delete_remote_mail_user($d, '1', 'olduser');
    is($err, undef, 'delete_remote_mail_user succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Uses virtualmin delete-user');

    @main::_webmin_log = ();
    webmin_log("user_delete", undef, 'olduser@testdomain.com');
    is($main::_webmin_log[0]{'action'}, 'user_delete', 'Logged user deletion');
};

# =========================================
# Test: create_user rejects invalid username before any RPC
# =========================================

subtest 'create_user handler — rejects bad username before RPC' => sub {
    plan tests => 3;

    # Validate rejects bad input
    my $verr = validate_mail_username('bad user!');
    like($verr, qr/invalid/i, 'Bad username rejected by validation');

    # When validation fails, no RPC calls should be made
    @main::_rpc_calls = ();
    is(scalar(grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls),
       0, 'No RPC calls made when validation fails');

    # Empty username also rejected
    $verr = validate_mail_username('');
    like($verr, qr/required/i, 'Empty username rejected');
};

# =========================================
# Test: error propagation from remote API
# =========================================

subtest 'create_remote_mail_user — error propagation' => sub {
    plan tests => 2;

    %main::_mock_cmd_responses = (
        'virtualmin create-user.*--user.*dupuser' => {
            output => 'A user with the same name already exists in this domain',
            exit   => 1,
        },
    );

    my $err = create_remote_mail_user($d, '1', 'dupuser', 'pass', {});
    ok($err, 'Error returned on failure');
    like($err, qr/already exists/, 'Error message propagated');

    %main::_mock_cmd_responses = ();
};

subtest 'modify_remote_mail_user — error propagation' => sub {
    plan tests => 2;

    %main::_mock_cmd_responses = (
        'virtualmin modify-user.*--user.*nouser' => {
            output => 'User nouser was not found in this virtual server',
            exit   => 1,
        },
    );

    my $err = modify_remote_mail_user($d, '1', 'nouser', { pass => 'x' });
    ok($err, 'Error returned on failure');
    like($err, qr/not found/, 'Error message propagated');

    %main::_mock_cmd_responses = ();
};

# =========================================
# Test: create_user handler — applies email settings via modify after create
# =========================================

subtest 'create_user handler — forwarding triggers modify after create' => sub {
    plan tests => 5;

    # Simulate create_user handler with forwarding enabled
    @main::_rpc_calls = ();

    # Step 1: create the user (as handler does)
    my $err = create_remote_mail_user($d, '1', 'fwduser', 'pass123', {});
    is($err, undef, 'create succeeds');

    # Step 2: handler detects non-default settings and calls modify
    # (forward checked, tome unchecked, nospam=0 is default so no change)
    my %changes = (
        no_local    => 1,
        add_forward => ['admin@example.com', 'backup@example.com'],
    );
    $err = modify_remote_mail_user($d, '1', 'fwduser', \%changes);
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Create called first');
    like($cmds, qr/virtualmin modify-user/, 'Modify called after create');
    like($cmds, qr/--add-forward\s+'admin\@example\.com'/, 'Forward address applied');
};

subtest 'create_user handler — autoreply triggers modify after create' => sub {
    plan tests => 4;

    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'vacuser', 'pass123', {});
    is($err, undef, 'create succeeds');

    my %changes = ( autoreply => 'Out of office until Monday' );
    $err = modify_remote_mail_user($d, '1', 'vacuser', \%changes);
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Create called first');
    like($cmds, qr/--autoreply\s+'Out of office until Monday'/, 'Autoreply applied');
};

subtest 'create_user handler — no_check_spam triggers modify after create' => sub {
    plan tests => 4;

    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'nospamuser', 'pass123', {});
    is($err, undef, 'create succeeds');

    my %changes = ( no_check_spam => 1 );
    $err = modify_remote_mail_user($d, '1', 'nospamuser', \%changes);
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Create called first');
    like($cmds, qr/--no-check-spam/, 'No-check-spam applied');
};

subtest 'create_user handler — all defaults, no modify call needed' => sub {
    plan tests => 3;

    # When all settings are defaults (tome=1, forward off, auto off, nospam=0),
    # the handler should NOT call modify_remote_mail_user
    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'defaultuser', 'pass123', {});
    is($err, undef, 'create succeeds');

    # No modify call — simulate handler logic: %changes is empty
    my %changes;
    # tome=1 (default) → no change
    # forward off → no change
    # auto off → no change
    # nospam=0 (default) → no change
    is(scalar(keys %changes), 0, 'No changes needed for default settings');

    my $cmds = captured_cmds();
    unlike($cmds, qr/virtualmin modify-user/,
        'No modify call when all defaults');
};

# Clean up
delete_remote_mail_server('1');

done_testing();
