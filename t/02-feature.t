#!/usr/bin/perl
# 02-feature.t — Test feature hooks with mocked Webmin
use strict;
use warnings;
use FindBin;
use Test::More;

# Load mock Webmin
require "$FindBin::Bin/mock-webmin.pl";

# Load library and feature hooks
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

# =========================================
# Test: Metadata hooks
# =========================================

subtest 'Feature metadata' => sub {
    plan tests => 5;

    my $name = feature_name();
    ok($name, 'feature_name returns a value');

    my $losing = feature_losing();
    ok($losing, 'feature_losing returns a value');

    my $label = feature_label(0);
    ok($label, 'feature_label returns for display');

    my $label2 = feature_label(1);
    ok($label2, 'feature_label returns for edit');

    my $hlink = feature_hlink();
    is($hlink, 'feat', 'feature_hlink returns feat');
};

# =========================================
# Test: feature_check
# =========================================

subtest 'feature_check' => sub {
    plan tests => 2;

    # No servers configured — should return error
    my $err = feature_check();
    ok($err, 'feature_check fails with no servers');

    # Add a server
    save_remote_mail_server('1', {
        host        => 'email1.trinsik.io',
        webmin_host => 'email1.trinsik.io',
        default     => 1,
    });
    $err = feature_check();
    is($err, undef, 'feature_check passes with a server configured');

    # Clean up
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_depends
# =========================================

subtest 'feature_depends' => sub {
    plan tests => 2;

    # Domain without DNS
    my $d = { 'dom' => 'test.com', 'dns' => 0 };
    my $err = feature_depends($d);
    ok($err, 'feature_depends fails without DNS');

    # Domain with DNS
    $d->{'dns'} = 1;
    $err = feature_depends($d);
    is($err, undef, 'feature_depends passes with DNS');
};

# =========================================
# Test: feature_clash
# =========================================

subtest 'feature_clash' => sub {
    plan tests => 2;

    # Domain with local mail
    my $d = { 'dom' => 'test.com', 'mail' => 1 };
    my $err = feature_clash($d);
    ok($err, 'feature_clash detects local mail conflict');

    # Domain without local mail
    $d->{'mail'} = 0;
    $err = feature_clash($d);
    is($err, undef, 'feature_clash passes without local mail');
};

# =========================================
# Test: feature_suitable
# =========================================

subtest 'feature_suitable' => sub {
    plan tests => 3;

    ok(feature_suitable(undef, undef, undef), 'Suitable for top-level domain');
    ok(!feature_suitable(undef, { 'dom' => 'alias' }, undef), 'Not suitable for alias');
    ok(!feature_suitable(undef, undef, { 'dom' => 'sub' }), 'Not suitable for subdomain');
};

# =========================================
# Test: feature_validate (new state format)
# =========================================

subtest 'feature_validate' => sub {
    plan tests => 4;

    my $d = { 'dom' => 'test.com' };

    # No state file — should fail
    my $err = feature_validate($d);
    ok($err, 'validate fails with no state');

    # Partial state (missing domain_created)
    save_domain_state('test.com', { server_id => '1', dns_configured => 1 });
    $err = feature_validate($d);
    ok($err, 'validate fails without domain_created');

    # Complete state
    save_domain_state('test.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });
    $err = feature_validate($d);
    is($err, undef, 'validate passes with complete state');

    # Missing DNS
    save_domain_state('test.com', { server_id => '1', domain_created => 1 });
    $err = feature_validate($d);
    ok($err, 'validate fails without dns_configured');

    delete_domain_state('test.com');
};

# =========================================
# Test: feature_import
# =========================================

subtest 'feature_import' => sub {
    plan tests => 2;

    is(feature_import('nostate.com'), 0, 'Import returns 0 for unknown domain');

    save_domain_state('imported.com', { server_id => '1' });
    is(feature_import('imported.com'), 1, 'Import returns 1 for known domain');

    delete_domain_state('imported.com');
};

# =========================================
# Test: feature_backup and feature_restore
# =========================================

subtest 'Backup and restore' => sub {
    plan tests => 3;

    # Create state
    save_domain_state('backup.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });

    my $d = { 'dom' => 'backup.com' };
    my $backup_file = "$main::module_config_directory/test-backup";

    # Backup
    @main::_progress_messages = ();
    my $ok = feature_backup($d, $backup_file);
    is($ok, 1, 'Backup succeeds');

    # Delete state and restore
    delete_domain_state('backup.com');
    $ok = feature_restore($d, $backup_file);
    is($ok, 1, 'Restore succeeds');

    # Verify restored state
    my $state = get_domain_state('backup.com');
    is($state->{'server_id'}, '1', 'Restored state matches');

    delete_domain_state('backup.com');
    unlink($backup_file);
};

# =========================================
# Test: feature_setup — uses virtualmin create-domain
# =========================================

subtest 'feature_setup lifecycle' => sub {
    plan tests => 6;

    # Configure a server
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

    my $d = {
        'dom' => 'lifecycle.com',
        'dns' => 1,
        'pass' => 'domainpass',
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    @main::_progress_messages = ();
    %main::_rpc_initialized = ();

    my $ok = feature_setup($d);
    is($ok, 1, 'feature_setup returns success');

    # Verify virtualmin create-domain was called
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin create-domain/, 'Uses virtualmin create-domain');

    # Check that state was saved with new format
    my $state = get_domain_state('lifecycle.com');
    ok($state->{'server_id'}, 'State file has server_id');
    ok($state->{'domain_created'}, 'State records domain_created');
    ok($state->{'dns_configured'}, 'State records dns_configured');

    # Verify progress messages were emitted
    ok(scalar @main::_progress_messages > 0, 'Progress messages were output');

    # Clean up: run feature_delete
    feature_delete($d);
    my $empty_state = get_domain_state('lifecycle.com');
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_setup passes correct flags to create-domain
# =========================================

subtest 'feature_setup command flags' => sub {
    plan tests => 4;

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

    my $d = {
        'dom' => 'flags-test.com',
        'dns' => 1,
        'pass' => 'testpass',
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    %main::_rpc_initialized = ();

    feature_setup($d);

    my $cmds = captured_cmds();
    like($cmds, qr/--mail/, 'Mail feature flag');
    like($cmds, qr/--spam/, 'Spam feature flag');
    like($cmds, qr/--virus/, 'Virus feature flag');
    like($cmds, qr/--skip-warnings/, 'Skip warnings flag');

    feature_delete($d);
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_inputs_parse with overrides
# =========================================

subtest 'feature_inputs_parse stores overrides in domain hash' => sub {
    plan tests => 5;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        default      => 1,
    });

    my $d = { 'dom' => 'parse-test.com', 'dns' => 1 };
    my $input_name = $main::module_name;
    $input_name =~ s/[^A-Za-z0-9]/_/g;

    my %in = (
        $input_name."_server"             => '1',
        $input_name."_ovr_spam_gateway"   => '10.0.0.50',
        $input_name."_ovr_spam_gateway_host" => 'spamgw',
        $input_name."_ovr_outgoing_relay" => 'relay.test.com',
        $input_name."_ovr_outgoing_relay_port" => '587',
    );

    my $err = feature_inputs_parse($d, \%in);
    is($err, undef, 'feature_inputs_parse succeeds');
    is($d->{'remote_mail_spam_gateway'}, '10.0.0.50', 'spam_gateway stored');
    is($d->{'remote_mail_spam_gateway_host'}, 'spamgw', 'spam_gateway_host stored');
    is($d->{'remote_mail_outgoing_relay'}, 'relay.test.com', 'outgoing_relay stored');
    is($d->{'remote_mail_outgoing_relay_port'}, '587', 'outgoing_relay_port stored');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_inputs_parse rejects invalid overrides
# =========================================

subtest 'feature_inputs_parse rejects bad input' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        default      => 1,
    });

    my $d = { 'dom' => 'bad-input.com', 'dns' => 1 };
    my $input_name = $main::module_name;
    $input_name =~ s/[^A-Za-z0-9]/_/g;

    # Bad IP
    my %in = (
        $input_name."_server"           => '1',
        $input_name."_ovr_spam_gateway" => 'not-an-ip',
    );
    my $err = feature_inputs_parse($d, \%in);
    like($err, qr/Invalid IP/, 'Rejects bad IP in spam_gateway');

    # Bad port
    %in = (
        $input_name."_server"                  => '1',
        $input_name."_ovr_outgoing_relay_port" => '99999',
    );
    $err = feature_inputs_parse($d, \%in);
    like($err, qr/Invalid port/, 'Rejects bad port');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_args_parse with overrides
# =========================================

subtest 'feature_args_parse stores overrides' => sub {
    plan tests => 3;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        default      => 1,
    });

    my $d = { 'dom' => 'cli-test.com', 'dns' => 1 };
    my %args = (
        $main::module_name."-server"        => '1',
        $main::module_name."-spam-gateway"  => '10.0.0.99',
        $main::module_name."-outgoing-relay-port" => '2525',
    );

    my $err = feature_args_parse($d, \%args);
    is($err, undef, 'feature_args_parse succeeds');
    is($d->{'remote_mail_spam_gateway'}, '10.0.0.99', 'CLI spam_gateway stored');
    is($d->{'remote_mail_outgoing_relay_port'}, '2525', 'CLI outgoing_relay_port stored');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_args_parse rejects invalid CLI input
# =========================================

subtest 'feature_args_parse rejects bad CLI input' => sub {
    plan tests => 1;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        default      => 1,
    });

    my $d = { 'dom' => 'cli-bad.com', 'dns' => 1 };
    my %args = (
        $main::module_name."-server"       => '1',
        $main::module_name."-spam-gateway" => "1.2.3.4'; rm -rf /",
    );

    my $err = feature_args_parse($d, \%args);
    like($err, qr/Invalid IP/, 'CLI rejects shell injection in IP');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_delete uses virtualmin delete-domain
# =========================================

subtest 'feature_delete cleanup including override keys' => sub {
    plan tests => 9;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        dkim_selector => '202307',
        default      => 1,
    });

    # Create state as if setup ran
    save_domain_state('delete-test.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });

    my $d = {
        'dom' => 'delete-test.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_dkim_enabled' => 1,
        'remote_mail_spam_gateway' => '10.0.0.50',
        'remote_mail_spam_gateway_host' => 'spamgw',
        'remote_mail_outgoing_relay' => 'relay.test.com',
        'remote_mail_outgoing_relay_port' => '587',
    };

    @main::_rpc_calls = ();
    my $ok = feature_delete($d);
    is($ok, 1, 'feature_delete returns success');

    # Verify virtualmin delete-domain was called
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-domain/, 'Uses virtualmin delete-domain');

    # Verify state was removed
    my $state = get_domain_state('delete-test.com');
    ok(!$state->{'server_id'}, 'State file removed after delete');

    # Verify domain hash fields cleaned up
    ok(!$d->{'remote_mail_server'}, 'Domain server field cleared');
    ok(!$d->{'remote_mail_dkim_enabled'}, 'Domain DKIM field cleared');
    ok(!$d->{'remote_mail_spam_gateway'}, 'Override spam_gateway cleared');
    ok(!$d->{'remote_mail_spam_gateway_host'}, 'Override spam_gateway_host cleared');
    ok(!$d->{'remote_mail_outgoing_relay'}, 'Override outgoing_relay cleared');
    ok(!$d->{'remote_mail_outgoing_relay_port'}, 'Override outgoing_relay_port cleared');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_modify (domain rename)
# =========================================

subtest 'feature_modify domain rename' => sub {
    plan tests => 3;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        dkim_selector => '202307',
        default      => 1,
    });

    save_domain_state('old-name.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });

    my $oldd = {
        'dom' => 'old-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };
    my $newd = {
        'dom' => 'new-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    @main::_rpc_calls = ();
    my $ok = feature_modify($newd, $oldd);
    is($ok, 1, 'feature_modify succeeds');

    # Should have called virtualmin modify-domain for the rename
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin modify-domain/, 'Calls virtualmin modify-domain');

    # Should have state for new domain, not old
    my $new_state = get_domain_state('new-name.com');
    ok($new_state->{'server_id'}, 'State exists for renamed domain');

    delete_domain_state('new-name.com');
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_modify preserves overrides during domain rename
# =========================================

subtest 'feature_modify with overrides' => sub {
    plan tests => 4;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        spam_gateway => '216.55.103.236',
        spam_gateway_host => 'mg',
        dkim_selector => '202307',
        default      => 1,
    });

    save_domain_state('ovr-old.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });

    my $oldd = {
        'dom' => 'ovr-old.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_spam_gateway' => '10.0.0.99',
        'remote_mail_spam_gateway_host' => 'spamgw',
    };
    my $newd = {
        'dom' => 'ovr-new.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_spam_gateway' => '10.0.0.99',
        'remote_mail_spam_gateway_host' => 'spamgw',
    };

    @main::_rpc_calls = ();
    my $ok = feature_modify($newd, $oldd);
    is($ok, 1, 'feature_modify with overrides succeeds');

    # State should exist for new domain
    my $state = get_domain_state('ovr-new.com');
    ok($state->{'server_id'}, 'State exists for renamed domain');

    # Overrides should still be on the domain hash
    is($newd->{'remote_mail_spam_gateway'}, '10.0.0.99', 'Override preserved after rename');
    is($newd->{'remote_mail_spam_gateway_host'}, 'spamgw', 'Override host preserved after rename');

    delete_domain_state('ovr-new.com');
    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_modify re-provisions when overrides change (no rename)
# =========================================

subtest 'feature_modify re-provisions on override change' => sub {
    plan tests => 4;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        spam_gateway => '216.55.103.236',
        spam_gateway_host => 'mg',
        outgoing_relay => 'smtp-out.trinsiklabs.com',
        outgoing_relay_port => 25,
        dkim_selector => '202307',
        default      => 1,
    });

    save_domain_state('same-name.com', {
        server_id => '1',
        dns_configured => 1,
        domain_created => 1,
    });

    # Old domain: no overrides
    my $oldd = {
        'dom' => 'same-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
    };

    # New domain: same name but with overrides added
    my $newd = {
        'dom' => 'same-name.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_spam_gateway' => '10.0.0.77',
        'remote_mail_outgoing_relay' => 'new-relay.io',
        'remote_mail_outgoing_relay_port' => '2525',
    };

    @main::_rpc_calls = ();
    @main::_progress_messages = ();
    my $ok = feature_modify($newd, $oldd);
    is($ok, 1, 'feature_modify triggers on override change');

    # Should have produced progress messages (re-provisioning happened)
    ok(scalar @main::_progress_messages > 0, 'Re-provisioning happened');

    # State should be updated
    my $state = get_domain_state('same-name.com');
    ok($state->{'dns_configured'}, 'DNS still configured after override change');
    ok($state->{'domain_created'}, 'Domain still created after override change');

    delete_domain_state('same-name.com');
    delete_remote_mail_server('1');
};

subtest 'feature_modify skips when no changes' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        default      => 1,
    });

    my $d = {
        'dom' => 'unchanged.com',
        'dns' => 1,
        'remote_mail_server' => '1',
        'remote_mail_spam_gateway' => '10.0.0.1',
    };
    # Same values in both old and new
    my $oldd = { %$d };

    @main::_progress_messages = ();
    my $ok = feature_modify($d, $oldd);
    is($ok, 1, 'feature_modify succeeds with no changes');
    is(scalar @main::_progress_messages, 0, 'No re-provisioning when nothing changed');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_disable uses virtualmin disable-domain
# =========================================

subtest 'feature_disable' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        default      => 1,
    });

    my $d = { 'dom' => 'disable-test.com', 'dns' => 1,
              'remote_mail_server' => '1' };

    @main::_rpc_calls = ();
    my $ok = feature_disable($d);
    is($ok, 1, 'feature_disable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin disable-domain/, 'Uses virtualmin disable-domain');

    delete_remote_mail_server('1');
};

# =========================================
# Test: feature_enable uses virtualmin enable-domain
# =========================================

subtest 'feature_enable' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        default      => 1,
    });

    my $d = { 'dom' => 'enable-test.com', 'dns' => 1,
              'remote_mail_server' => '1' };

    @main::_rpc_calls = ();
    my $ok = feature_enable($d);
    is($ok, 1, 'feature_enable succeeds');

    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin enable-domain/, 'Uses virtualmin enable-domain');

    delete_remote_mail_server('1');
};

# =========================================
# Test: rollback_setup cleans up partial state
# =========================================

subtest 'rollback_setup' => sub {
    plan tests => 2;

    save_remote_mail_server('1', {
        host         => 'email1.trinsik.io',
        webmin_host  => 'email1.trinsik.io',
        webmin_user  => 'root',
        webmin_pass  => 'secret',
        dkim_selector => '202307',
        default      => 1,
    });

    save_domain_state('rollback.com', {
        server_id => '1',
        domain_created => 1,
        dns_configured => 1,
    });

    my $d = { 'dom' => 'rollback.com', 'dns' => 1 };
    my %state = (
        domain_created => 1,
        dns_configured => 1,
    );

    @main::_rpc_calls = ();
    rollback_setup($d, '1', \%state);

    # Rollback should call virtualmin delete-domain
    my $cmds = captured_cmds();
    like($cmds, qr/virtualmin delete-domain/, 'Rollback deletes domain on email1');

    my $cleaned = get_domain_state('rollback.com');
    ok(!$cleaned->{'server_id'}, 'State removed after rollback');

    delete_remote_mail_server('1');
};

done_testing();
