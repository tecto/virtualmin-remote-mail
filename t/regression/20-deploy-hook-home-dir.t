#!/usr/bin/perl
# 20-deploy-hook-home-dir.t
#
# Regression: certbot deploy hook silently no-op'd when the cert name did not
# match the Virtualmin user's home-directory name. Production impact: vh2's
# own renewed cert (cert name "vh2.trinsik.io", home directory /home/vh2) was
# never copied into /home/vh2/ssl/. Postfix kept serving an expiring leaf-only
# cert until users started reporting SSL errors.
#
# Incident date: 2026-05-13.
# Bug class: external-artifact (deploy-hook shell script).
# Verification protocol: fixture replay — see t/fixtures/deploy-hook/.
# Fix commit / artifact: deploy-hooks/sni-sync.sh in this repo (canonical
# version with the three-tiered home-directory resolution).
#
# What this test exercises:
#   (1) cert name == home dir (mail.example.com → /home/mail.example.com) →
#       cert files land in /home/mail.example.com/ssl/.
#   (2) cert name != home dir (vh2.trinsik.io → /home/vh2)               →
#       cert files land in /home/vh2/ssl/ via the (c) fallback. This is the
#       case the previous hook silently dropped.
#   (3) virtualmin lookup overrides directory-name guessing                →
#       authoritative path wins over fallbacks.
#   (4) no candidate home found                                            →
#       hook exits 0 cleanly, does NOT die, logs via `logger`.
#   (5) ssl.combined contains ≥ 2 BEGIN CERTIFICATE blocks (leaf + chain) →
#       see also the smokeandleaf.com regression in t/regression/10-*.
#   (6) postmap is invoked with -F (NOT plain postmap hash:) when sni_map
#       is present.

use strict;
use warnings;
use FindBin;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $hook = abs_path("$FindBin::Bin/../../deploy-hooks/sni-sync.sh");
plan skip_all => "deploy hook not found at $hook" unless -x $hook;

# -----------------------------------------------------------------------------
# Test harness: stage a fake $RENEWED_LINEAGE, a fake home-tree, and mock
# `virtualmin`, `postmap`, `systemctl`, `chown`, `logger` on PATH so the hook
# can run unprivileged inside the test sandbox.
# -----------------------------------------------------------------------------

sub stage_sandbox {
    my (%opts) = @_;
    my $sandbox = tempdir('vrm-hook-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    # Fake LE lineage with valid-looking PEM bytes (multiple cert blocks in
    # fullchain so the ssl.combined assertion is meaningful).
    my $lineage = "$sandbox/etc/letsencrypt/live/$opts{cert_name}";
    make_path($lineage);
    _write("$lineage/privkey.pem",
           "-----BEGIN PRIVATE KEY-----\nFAKE_KEY\n-----END PRIVATE KEY-----\n");
    _write("$lineage/cert.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_LEAF\n-----END CERTIFICATE-----\n");
    _write("$lineage/chain.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_INTERMEDIATE\n-----END CERTIFICATE-----\n" .
           "-----BEGIN CERTIFICATE-----\nFAKE_ROOT\n-----END CERTIFICATE-----\n");
    _write("$lineage/fullchain.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_LEAF\n-----END CERTIFICATE-----\n" .
           "-----BEGIN CERTIFICATE-----\nFAKE_INTERMEDIATE\n-----END CERTIFICATE-----\n" .
           "-----BEGIN CERTIFICATE-----\nFAKE_ROOT\n-----END CERTIFICATE-----\n");

    # Fake $HOME tree.
    if ($opts{home_dirs}) {
        for my $h (@{$opts{home_dirs}}) {
            make_path("$sandbox/home/$h/ssl");
        }
    }

    # Fake sni_map (a single line; postmap -F would base64-encode the leaf).
    if ($opts{with_sni_map}) {
        make_path("$sandbox/etc/postfix");
        _write("$sandbox/etc/postfix/sni_map", "$opts{cert_name} /tmp/x.key /tmp/x.crt\n");
    }

    # Mock binaries on PATH.
    my $mock_bin = "$sandbox/mock-bin";
    make_path($mock_bin);
    my $log = "$sandbox/mock.log";

    # `virtualmin list-domains --domain X --simple-multiline` — returns a
    # Home directory: line if and only if $opts{vm_home} is set.
    my $vm_home = $opts{vm_home} // '';
    _write("$mock_bin/virtualmin", <<"BASH");
#!/bin/bash
echo "virtualmin \$*" >> "$log"
if [ -n "$vm_home" ] && [ "\$1" = "list-domains" ]; then
    echo "Home directory: $vm_home"
fi
exit 0
BASH

    for my $name (qw(postmap systemctl chown logger)) {
        _write("$mock_bin/$name", "#!/bin/bash\necho \"$name \$*\" >> \"$log\"\nexit 0\n");
    }
    chmod 0755, glob "$mock_bin/*";

    return ($sandbox, $lineage, $log, $mock_bin);
}

sub _write {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub run_hook {
    my ($lineage, $sandbox, $mock_bin) = @_;
    # Override absolute paths in the hook script by running it under
    # `bash` with a shim that redirects /home → $sandbox/home and
    # /etc/postfix → $sandbox/etc/postfix. We do this by editing a copy.
    my $copy = "$sandbox/hook.sh";
    open(my $in,  '<', $hook) or die $!;
    open(my $out, '>', $copy) or die $!;
    while (<$in>) {
        s{/home/}{$sandbox/home/}g;
        s{/etc/postfix/}{$sandbox/etc/postfix/}g;
        s{/etc/letsencrypt/}{$sandbox/etc/letsencrypt/}g;
        print $out $_;
    }
    close $in; close $out;
    chmod 0755, $copy;

    my $output = `RENEWED_LINEAGE=$lineage PATH=$mock_bin:\$PATH bash $copy 2>&1`;
    my $exit = $? >> 8;
    return ($output, $exit);
}

# -----------------------------------------------------------------------------
# Test (1): cert name == home dir (the smokeandleaf.com / mail.example.com case)
# -----------------------------------------------------------------------------

subtest 'cert name matches home dir → files land correctly' => sub {
    plan tests => 5;

    my ($sb, $lin, $log, $bin) = stage_sandbox(
        cert_name    => 'mail.example.com',
        home_dirs    => ['mail.example.com'],
        with_sni_map => 1,
    );

    my ($out, $exit) = run_hook($lin, $sb, $bin);

    is($exit, 0, 'hook exits 0') or diag($out);
    ok(-f "$sb/home/mail.example.com/ssl/mail.example.com.crt",
       'leaf cert copied to <home>/ssl/<cert_name>.crt');
    ok(-f "$sb/home/mail.example.com/ssl.combined",
       'ssl.combined created at home root');

    my $combined = do { local (@ARGV, $/) = "$sb/home/mail.example.com/ssl.combined"; <> };
    my $count = () = $combined =~ /-----BEGIN CERTIFICATE-----/g;
    cmp_ok($count, '>=', 2,
           "ssl.combined has >= 2 BEGIN CERTIFICATE blocks (got $count) — full chain present");

    my $logtext = do { local (@ARGV, $/) = $log; <> };
    like($logtext, qr/postmap -F hash:.*sni_map/,
         'postmap invoked with -F flag (not plain postmap)');
};

# -----------------------------------------------------------------------------
# Test (2): cert name != home dir (the vh2.trinsik.io case — production bug)
# -----------------------------------------------------------------------------

subtest 'cert name != home dir → resolves via hostname fallback' => sub {
    plan tests => 4;

    my ($sb, $lin, $log, $bin) = stage_sandbox(
        cert_name    => 'vh2.trinsik.io',
        home_dirs    => ['vh2'],                 # /home/vh2 exists, /home/vh2.trinsik.io does NOT
        with_sni_map => 1,
    );

    my ($out, $exit) = run_hook($lin, $sb, $bin);

    is($exit, 0, 'hook exits 0') or diag($out);
    ok(-f "$sb/home/vh2/ssl/vh2.trinsik.io.crt",
       'leaf cert copied to /home/vh2/ssl/<cert_name>.crt (NOT /home/vh2.trinsik.io)')
       or diag("contents of $sb/home/vh2/ssl: " . `ls $sb/home/vh2/ssl 2>&1`);
    ok(-f "$sb/home/vh2/ssl.combined",
       'ssl.combined created at /home/vh2/ssl.combined');

    # Crucially, the buggy hook would have produced NO files here. Assert that
    # /home/vh2.trinsik.io was NOT created by the hook.
    ok(! -d "$sb/home/vh2.trinsik.io",
       'hook did not create /home/vh2.trinsik.io (no spurious dir)');
};

# -----------------------------------------------------------------------------
# Test (3): virtualmin lookup is authoritative
# -----------------------------------------------------------------------------

subtest 'virtualmin list-domains result wins over directory guessing' => sub {
    plan tests => 3;

    # Stage TWO candidate home dirs:
    #   /home/foo.example.com and /home/foo. Virtualmin says foo.example.com.
    # The hook MUST honour the virtualmin answer.
    my ($sb, $lin, $log, $bin) = stage_sandbox(
        cert_name => 'foo.example.com',
        home_dirs => ['foo.example.com', 'foo'],
        vm_home   => undef,  # set below to absolute sandbox path
    );

    # Re-write the virtualmin mock to return an absolute path inside the sandbox.
    my $authoritative = "$sb/home/foo.example.com";
    open(my $vmh, '>', "$bin/virtualmin") or die $!;
    print $vmh <<"BASH";
#!/bin/bash
echo "virtualmin \$*" >> "$log"
if [ "\$1" = "list-domains" ]; then
    echo "Home directory: $authoritative"
fi
exit 0
BASH
    close $vmh;
    chmod 0755, "$bin/virtualmin";

    my ($out, $exit) = run_hook($lin, $sb, $bin);
    is($exit, 0, 'hook exits 0') or diag($out);
    ok(-f "$authoritative/ssl/foo.example.com.crt",
       'cert landed in virtualmin-reported home');
    ok(! -f "$sb/home/foo/ssl/foo.example.com.crt",
       'cert did NOT land in the short-name fallback /home/foo');
};

# -----------------------------------------------------------------------------
# Test (4): no candidate home — hook exits 0 (NOT non-zero) and logs
# -----------------------------------------------------------------------------

subtest 'no home candidate → exit 0 (silent skip) + logger entry' => sub {
    plan tests => 3;

    my ($sb, $lin, $log, $bin) = stage_sandbox(
        cert_name => 'orphan.example.com',
        home_dirs => [],                # nothing on disk
    );

    my ($out, $exit) = run_hook($lin, $sb, $bin);
    is($exit, 0, 'hook exits 0 even with no home (other hooks may handle)');
    ok(! -f "$sb/home/orphan.example.com/ssl/orphan.example.com.crt",
       'no spurious files written');

    my $logtext = -f $log ? do { local (@ARGV, $/) = $log; <> } : '';
    like($logtext, qr/logger.*no home directory resolved/i,
         'logger called with explanatory message');
};

# -----------------------------------------------------------------------------
# Test (5): idempotency — running twice produces identical state
# -----------------------------------------------------------------------------

subtest 'running hook twice is idempotent' => sub {
    plan tests => 2;

    my ($sb, $lin, $log, $bin) = stage_sandbox(
        cert_name    => 'mail.example.com',
        home_dirs    => ['mail.example.com'],
        with_sni_map => 1,
    );

    run_hook($lin, $sb, $bin);
    my $hash1 = `find $sb/home/mail.example.com -type f -exec sha256sum {} \\; 2>/dev/null | sort | sha256sum`;
    run_hook($lin, $sb, $bin);
    my $hash2 = `find $sb/home/mail.example.com -type f -exec sha256sum {} \\; 2>/dev/null | sort | sha256sum`;

    is($hash1, $hash2, 'state hash unchanged between two runs');
    isnt($hash1, '', 'hash is non-empty (sanity)');
};

# -----------------------------------------------------------------------------
# Test (6): RENEWED_LINEAGE unset → exit 0 (manual invocation, no args)
# -----------------------------------------------------------------------------

subtest 'unset RENEWED_LINEAGE → exit 0 (does not crash)' => sub {
    plan tests => 1;
    my $exit = system("env -u RENEWED_LINEAGE bash $hook >/dev/null 2>&1");
    is($exit >> 8, 0, 'unset RENEWED_LINEAGE → exit 0');
};

done_testing();
