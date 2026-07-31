#!/usr/bin/perl
# 30-shell-injection-guard.t
#
# Guard: the mailbox-management functions build shell commands by string
# interpolation and run them as root on the mail server over SSH, e.g.
#
#     my $userdir = "${home}/${maildir}/${user}";
#     my $cmd = "mkdir -p ${userdir}/{cur,new,tmp} && chmod -R 700 ${userdir}";
#     &remote_mail_ssh($server_id, $cmd);
#
# remote_mail_ssh quotemeta's the outer argv, so the local shell is safe, but
# $command is handed to the REMOTE shell verbatim. A mailbox name containing
# shell metacharacters therefore executes as root on the mail server.
#
# History: the build deployed on vh1 through 2026-07 had no validation at all
# on this path. It was not exploitable only because nothing called these
# functions -- the user-management UI (edit_user.cgi) existed solely in the
# other architecture generation. Restoring that UI without restoring the
# validation first would have turned a dormant defect into a live one, so the
# validation helpers were ported forward ahead of it.
#
# Bug class: latent-injection (validation absent, path unreachable).
# Fix artifact: validate_mail_username / validate_domain_name in
#               virtualmin-remote-mail-lib.pl, called at the top of
#               create_remote_mail_user and delete_remote_mail_user.
#
# What this test asserts:
#   (1) the validators reject shell metacharacters and traversal
#   (2) they accept ordinary well-formed values
#   (3) create/delete_remote_mail_user REFUSE a malicious name and issue no
#       remote command at all -- the payload never reaches the wire

use strict;
use warnings;
use FindBin;
use Test::More;

require "$FindBin::Bin/../mock-webmin.pl";
load_plugin_lib("$FindBin::Bin/../../virtualmin-remote-mail-lib.pl");
$main::domains_dir = "$main::module_config_directory/domains";
load_plugin_feature("$FindBin::Bin/../../virtual_feature.pl");

save_remote_mail_server('1', {
    host        => 'mail.example.com',
    ssh_host    => 'mail.example.com',
    ssh_user    => 'root',
    webmin_host => 'mail.example.com',
    webmin_port => 10000,
    webmin_user => 'root',
    webmin_pass => 'secret',
    default     => 1,
});

# Payloads that would execute as root on the mail server if interpolated.
my @evil_users = (
    'bob; touch /tmp/pwned',
    'bob && rm -rf /',
    'bob$(id)',
    'bob`id`',
    'bob | tee /etc/passwd',
    "bob\nid",
    '../../etc/passwd',
);

my @evil_domains = (
    'example.com; touch /tmp/pwned',
    'example.com$(id)',
    '../../../etc',
    'example..com',
    'exa mple.com',
);

subtest 'validate_mail_username rejects shell metacharacters' => sub {
    plan tests => scalar(@evil_users);
    foreach my $u (@evil_users) {
        my $shown = $u; $shown =~ s/\n/\\n/g;
        ok(defined(validate_mail_username($u)),
           "rejected: $shown");
    }
};

subtest 'validate_domain_name rejects injection and traversal' => sub {
    plan tests => scalar(@evil_domains);
    foreach my $d (@evil_domains) {
        ok(defined(validate_domain_name($d)), "rejected: $d");
    }
};

subtest 'validators accept ordinary values' => sub {
    plan tests => 4;
    ok(!defined(validate_mail_username('bob')),      'plain username accepted');
    ok(!defined(validate_mail_username('bob.smith')),'dotted username accepted');
    ok(!defined(validate_domain_name('example.com')),'plain domain accepted');
    ok(!defined(validate_domain_name('sub.example.co.uk')),
       'multi-label domain accepted');
};

# The behavioural assertion: a rejected name must produce no remote command.
subtest 'create_remote_mail_user issues no remote command for a bad username' => sub {
    plan tests => 3;

    my $d = { 'dom' => 'example.com' };
    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'bob; touch /tmp/pwned', 'pw', {});
    ok(defined($err) && $err ne '', 'returns an error');

    my @ssh = grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls;
    is(scalar(@ssh), 0, 'no command was sent to the mail server');

    my $all = join("\n", map { $_->{'args'}[0] // '' } @main::_rpc_calls);
    unlike($all, qr/touch/, 'payload never appears in any issued command');
};

subtest 'delete_remote_mail_user issues no remote command for a bad username' => sub {
    plan tests => 2;

    my $d = { 'dom' => 'example.com' };
    @main::_rpc_calls = ();

    my $err = delete_remote_mail_user($d, '1', 'bob$(id)');
    ok(defined($err) && $err ne '', 'returns an error');

    my @ssh = grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls;
    is(scalar(@ssh), 0, 'no command was sent to the mail server');
};

subtest 'a bad domain is also refused' => sub {
    plan tests => 2;

    my $d = { 'dom' => 'example.com; id' };
    @main::_rpc_calls = ();

    my $err = create_remote_mail_user($d, '1', 'bob', 'pw', {});
    ok(defined($err) && $err ne '', 'returns an error');

    my @ssh = grep { $_->{'func'} eq 'backquote_command' } @main::_rpc_calls;
    is(scalar(@ssh), 0, 'no command was sent to the mail server');
};

done_testing();
