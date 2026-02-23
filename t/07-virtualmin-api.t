#!/usr/bin/perl
# 07-virtualmin-api.t — Test Virtualmin CLI API wrappers and parsers
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin and library
require "$FindBin::Bin/mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../virtual_feature.pl");

# Helper: extract shell commands from RPC calls (backquote_command args)
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

my $d = { 'dom' => 'example.com', 'dns' => 1 };

# =========================================
# Test: _shell_quote
# =========================================

subtest '_shell_quote — safe quoting' => sub {
    plan tests => 4;

    is(_shell_quote('simple'), "'simple'", 'Simple string quoted');
    is(_shell_quote("it's"), "'it'\\''s'", 'Single quotes escaped');
    is(_shell_quote('has spaces'), "'has spaces'", 'Spaces preserved');
    is(_shell_quote('rm -rf /; echo pwned'),
       "'rm -rf /; echo pwned'",
       'Shell metacharacters neutralized');
};

# =========================================
# Test: parse_multiline_output — empty input
# =========================================

subtest 'parse_multiline_output — empty' => sub {
    plan tests => 3;

    my @result = parse_multiline_output('');
    is(scalar @result, 0, 'Empty string returns empty list');

    @result = parse_multiline_output(undef);
    is(scalar @result, 0, 'Undef returns empty list');

    @result = parse_multiline_output("\n\n");
    is(scalar @result, 0, 'Blank lines return empty list');
};

# =========================================
# Test: parse_multiline_output — single entry
# =========================================

subtest 'parse_multiline_output — single entry' => sub {
    plan tests => 5;

    my $output = <<'EOF';
info
    Real name: Info Account
    Email address: info@example.com
    Home directory: /home/example.com/homes/info
    Shell: /bin/false
EOF

    my @entries = parse_multiline_output($output);
    is(scalar @entries, 1, 'One entry parsed');
    is($entries[0]->{'_name'}, 'info', 'Entry name parsed');
    is($entries[0]->{'real_name'}, 'Info Account', 'Real name parsed');
    is($entries[0]->{'email_address'}, 'info@example.com', 'Email parsed');
    is($entries[0]->{'home_directory'}, '/home/example.com/homes/info',
       'Home directory parsed');
};

# =========================================
# Test: parse_multiline_output — multiple entries
# =========================================

subtest 'parse_multiline_output — multiple entries' => sub {
    plan tests => 5;

    my $output = <<'EOF';
info
    Real name: Info Account
    Email address: info@example.com
admin
    Real name: Admin User
    Email address: admin@example.com
    Forward to: admin@gmail.com
EOF

    my @entries = parse_multiline_output($output);
    is(scalar @entries, 2, 'Two entries parsed');
    is($entries[0]->{'_name'}, 'info', 'First entry name');
    is($entries[0]->{'real_name'}, 'Info Account', 'First entry real name');
    is($entries[1]->{'_name'}, 'admin', 'Second entry name');
    is($entries[1]->{'forward_to'}, 'admin@gmail.com', 'Second entry forward');
};

# =========================================
# Test: parse_multiline_output — domain format
# =========================================

subtest 'parse_multiline_output — domain format' => sub {
    plan tests => 4;

    my $output = <<'EOF';
example.com
    Description: Example Domain
    Username: example
    Features: mail dns
    Home directory: /home/example.com
EOF

    my @entries = parse_multiline_output($output);
    is(scalar @entries, 1, 'One domain entry parsed');
    is($entries[0]->{'_name'}, 'example.com', 'Domain name parsed');
    is($entries[0]->{'description'}, 'Example Domain', 'Description parsed');
    is($entries[0]->{'features'}, 'mail dns', 'Features parsed');
};

# =========================================
# Test: remote_virtualmin_cmd — command construction
# =========================================

subtest 'remote_virtualmin_cmd — create-domain' => sub {
    plan tests => 5;

    @main::_rpc_calls = ();
    %main::_rpc_initialized = ();

    my ($out, $exit) = remote_virtualmin_cmd('1', 'create-domain',
        '--domain', 'newdom.com',
        '--pass', 'secret123',
        '--mail', '--spam', '--virus', '--unix', '--dir',
        '--skip-warnings');

    is($exit, 0, 'Exit code 0');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-domain/, 'Uses virtualmin CLI');
    like($cmds, qr/--domain\s+'newdom\.com'/, 'Domain quoted');
    like($cmds, qr/--pass\s+'secret123'/, 'Password quoted');
    like($cmds, qr/--mail\s+--spam\s+--virus\s+--unix\s+--dir/,
         'Boolean flags passed through');
};

subtest 'remote_virtualmin_cmd — create-user' => sub {
    plan tests => 4;

    @main::_rpc_calls = ();

    remote_virtualmin_cmd('1', 'create-user',
        '--domain', 'example.com',
        '--user', 'john',
        '--pass', 'p@ss w0rd',
        '--real', 'John Doe');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Uses create-user subcommand');
    like($cmds, qr/--domain\s+'example\.com'/, 'Domain passed');
    like($cmds, qr/--user\s+'john'/, 'User passed');
    like($cmds, qr/--pass\s+'p\@ss w0rd'/, 'Password with spaces safely quoted');
};

subtest 'remote_virtualmin_cmd — modify-user flags' => sub {
    plan tests => 6;

    @main::_rpc_calls = ();

    remote_virtualmin_cmd('1', 'modify-user',
        '--domain', 'example.com',
        '--user', 'john',
        '--pass', 'newpass',
        '--add-forward', 'john@gmail.com',
        '--local',
        '--check-spam',
        '--autoreply', 'I am on vacation');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin modify-user/, 'Uses modify-user');
    like($cmds, qr/--pass\s+'newpass'/, 'Password flag');
    like($cmds, qr/--add-forward\s+'john\@gmail\.com'/, 'Forward flag');
    like($cmds, qr/--local/, 'Boolean local flag');
    like($cmds, qr/--check-spam/, 'Boolean check-spam flag');
    like($cmds, qr/--autoreply\s+'I am on vacation'/, 'Autoreply with spaces');
};

subtest 'remote_virtualmin_cmd — delete-user' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();

    remote_virtualmin_cmd('1', 'delete-user',
        '--domain', 'example.com',
        '--user', 'john');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Uses delete-user');
    like($cmds, qr/--domain\s+'example\.com'/, 'Domain passed');
    like($cmds, qr/--user\s+'john'/, 'User passed');
};

# =========================================
# Test: remote_virtualmin_cmd — error handling
# =========================================

subtest 'remote_virtualmin_cmd — error response' => sub {
    plan tests => 2;

    # Configure mock to return error for a specific command
    %main::_mock_cmd_responses = (
        'virtualmin create-domain.*--domain.*fail\.com' => {
            output => 'Failed to create virtual server : A virtual server with the same name already exists',
            exit   => 1,
        },
    );

    my ($out, $exit) = remote_virtualmin_cmd('1', 'create-domain',
        '--domain', 'fail.com', '--pass', 'x', '--mail');
    is($exit, 1, 'Non-zero exit code returned');
    like($out, qr/already exists/, 'Error message returned');

    %main::_mock_cmd_responses = ();
};

# =========================================
# Test: create_remote_mail_user — via virtualmin create-user
# =========================================

subtest 'create_remote_mail_user — constructs create-user command' => sub {
    plan tests => 4;

    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'info', 'password123', {
        real => 'Info Account',
    });
    is($err, undef, 'create succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-user/, 'Uses virtualmin create-user');
    like($cmds, qr/--user\s+'info'/, 'Username passed');
    like($cmds, qr/--real\s+'Info Account'/, 'Real name passed');
};

subtest 'create_remote_mail_user — error propagation' => sub {
    plan tests => 2;

    %main::_mock_cmd_responses = (
        'virtualmin create-user.*--user.*duplicate' => {
            output => 'A user with the same name already exists',
            exit   => 1,
        },
    );

    my $err = create_remote_mail_user($d, '1', 'duplicate', 'pass', {});
    ok($err, 'Error returned on failure');
    like($err, qr/already exists/, 'Error message propagated');

    %main::_mock_cmd_responses = ();
};

# =========================================
# Test: delete_remote_mail_user — via virtualmin delete-user
# =========================================

subtest 'delete_remote_mail_user — constructs delete-user command' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();

    my $err = delete_remote_mail_user($d, '1', 'info');
    is($err, undef, 'delete succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-user/, 'Uses virtualmin delete-user');
    like($cmds, qr/--user\s+'info'/, 'Username passed');
};

# =========================================
# Test: modify_remote_mail_user — various flag combinations
# =========================================

subtest 'modify_remote_mail_user — change password' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();

    my $err = modify_remote_mail_user($d, '1', 'info', {
        pass => 'newpass',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--pass\s+'newpass'/, 'Password flag passed');
};

subtest 'modify_remote_mail_user — rename user' => sub {
    plan tests => 2;

    @main::_rpc_calls = ();

    my $err = modify_remote_mail_user($d, '1', 'oldname', {
        newuser => 'newname',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--newuser\s+'newname'/, 'Newuser flag passed');
};

subtest 'modify_remote_mail_user — forwarding' => sub {
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

subtest 'modify_remote_mail_user — auto-reply and spam' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();

    my $err = modify_remote_mail_user($d, '1', 'info', {
        autoreply  => 'I am on vacation until Monday',
        check_spam => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--autoreply\s+'I am on vacation until Monday'/,
         'Autoreply message passed');
    like($cmds, qr/--check-spam/, 'Check-spam boolean flag');
};

subtest 'modify_remote_mail_user — disable and recovery' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();

    my $err = modify_remote_mail_user($d, '1', 'info', {
        disable  => 1,
        recovery => 'admin@example.com',
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--disable/, 'Disable flag');
    like($cmds, qr/--recovery\s+'admin\@example\.com'/, 'Recovery email');
};

subtest 'modify_remote_mail_user — clear autoreply and recovery' => sub {
    plan tests => 3;

    @main::_rpc_calls = ();

    my $err = modify_remote_mail_user($d, '1', 'info', {
        no_autoreply => 1,
        no_recovery  => 1,
    });
    is($err, undef, 'modify succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/--no-autoreply/, 'No-autoreply flag');
    like($cmds, qr/--no-recovery/, 'No-recovery flag');
};

# =========================================
# Test: list_remote_mail_users — parsed output
# =========================================

subtest 'list_remote_mail_users — parses multiline output' => sub {
    plan tests => 5;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--domain.*example\.com' => {
            output => "info\n    Real name: Info Account\n    Email address: info\@example.com\nadmin\n    Real name: Admin User\n    Email address: admin\@example.com",
            exit   => 0,
        },
    );

    my @users = list_remote_mail_users($d, '1');
    is(scalar @users, 2, 'Two users returned');
    is($users[0]->{'_name'}, 'info', 'First user name');
    is($users[0]->{'real_name'}, 'Info Account', 'First user real name');
    is($users[1]->{'_name'}, 'admin', 'Second user name');
    is($users[1]->{'email_address'}, 'admin@example.com', 'Second user email');

    %main::_mock_cmd_responses = ();
};

subtest 'list_remote_mail_users — empty domain' => sub {
    plan tests => 1;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--domain.*empty\.com' => {
            output => '',
            exit   => 0,
        },
    );

    my $d_empty = { 'dom' => 'empty.com' };
    my @users = list_remote_mail_users($d_empty, '1');
    is(scalar @users, 0, 'Empty user list');

    %main::_mock_cmd_responses = ();
};

# =========================================
# Test: get_remote_mail_user — single user lookup
# =========================================

subtest 'get_remote_mail_user — returns single user hash' => sub {
    plan tests => 5;

    %main::_mock_cmd_responses = (
        'virtualmin list-users.*--user.*info' => {
            output => "info\n    Real name: Info Account\n    Email address: info\@example.com\n    Home directory: /home/example.com/homes/info\n    Forward to: info\@gmail.com",
            exit   => 0,
        },
    );

    my $user = get_remote_mail_user($d, '1', 'info');
    ok($user, 'User returned');
    is($user->{'_name'}, 'info', 'Username');
    is($user->{'real_name'}, 'Info Account', 'Real name');
    is($user->{'email_address'}, 'info@example.com', 'Email');
    is($user->{'forward_to'}, 'info@gmail.com', 'Forward');

    %main::_mock_cmd_responses = ();
};

subtest 'get_remote_mail_user — user not found' => sub {
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
# Test: feature_setup uses virtualmin create-domain
# =========================================

subtest 'feature_setup — uses virtualmin create-domain' => sub {
    plan tests => 5;

    my $d_setup = {
        'dom'  => 'setup-api.com',
        'dns'  => 1,
        'pass' => 'domainpass',
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    @main::_progress_messages = ();
    %main::_rpc_initialized = ();

    my $ok = feature_setup($d_setup);
    is($ok, 1, 'feature_setup succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-domain/, 'Calls virtualmin create-domain');
    like($cmds, qr/--domain\s+'setup-api\.com'/, 'Domain name passed');
    like($cmds, qr/--mail/, 'Mail feature enabled');

    # Check state uses new format
    my $state = get_domain_state('setup-api.com');
    ok($state->{'domain_created'}, 'State records domain_created');

    # Clean up
    feature_delete($d_setup);
    delete_domain_state('setup-api.com');
};

# =========================================
# Test: feature_delete uses virtualmin delete-domain
# =========================================

subtest 'feature_delete — uses virtualmin delete-domain' => sub {
    plan tests => 3;

    save_domain_state('del-api.com', {
        server_id => '1',
        domain_created => 1,
        dns_configured => 1,
    });

    my $d_del = {
        'dom'  => 'del-api.com',
        'dns'  => 1,
        'remote_mail_server' => '1',
        'remote_mail_dkim_enabled' => 1,
    };

    @main::_rpc_calls = ();

    my $ok = feature_delete($d_del);
    is($ok, 1, 'feature_delete succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-domain/, 'Calls virtualmin delete-domain');
    like($cmds, qr/--domain\s+'del-api\.com'/, 'Domain name passed');
};

# =========================================
# Test: feature_disable/enable uses virtualmin API
# =========================================

subtest 'feature_disable — uses virtualmin disable-domain' => sub {
    plan tests => 2;

    my $d_dis = {
        'dom' => 'disable-api.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    my $ok = feature_disable($d_dis);
    is($ok, 1, 'feature_disable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin disable-domain/, 'Calls virtualmin disable-domain');
};

subtest 'feature_enable — uses virtualmin enable-domain' => sub {
    plan tests => 2;

    my $d_en = {
        'dom' => 'enable-api.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    my $ok = feature_enable($d_en);
    is($ok, 1, 'feature_enable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin enable-domain/, 'Calls virtualmin enable-domain');
};

# Clean up
delete_remote_mail_server('1');

done_testing();
