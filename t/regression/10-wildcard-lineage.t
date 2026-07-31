#!/usr/bin/perl
# 10-wildcard-lineage.t
#
# Regression: certbot deploy hook silently no-op'd for every WILDCARD
# certificate. Certbot stores a wildcard lineage under a directory whose name
# carries a literal asterisk (/etc/letsencrypt/live/*.example.com), and the
# hook derived the domain from `basename $RENEWED_LINEAGE` without stripping
# it. Nothing downstream carries that prefix, so all three home-resolution
# tiers failed and the hook exited 0 without delivering the cert.
#
# Production impact: *.smokeandleaf.com renewed on vh1 on 2026-04-30 and the
# hook logged
#     Skip *.smokeandleaf.com (no /home/*.smokeandleaf.com on vh2.trinsik.io)
# The mail server kept serving the old cert until it expired on 2026-07-29.
# The same bug silently stranded *.guidelineroofing.com and
# *.westlakeselect.net, whose vh2 certs expired 2026-04-27 and 2026-04-28 and
# went unnoticed for three months because vh1 itself always looked healthy.
#
# Incident date: 2026-07-31 (discovered; renewal had been failing since April).
# Bug class: external-artifact (deploy-hook shell script).
# Fix artifact: deploy-hooks/sni-sync.sh — `CERT_NAME="${LINEAGE_NAME#\*.}"`.
#
# What this test exercises:
#   (1) wildcard lineage + Virtualmin-owned domain → hook queries Virtualmin
#       for the STRIPPED name and delivers into the resolved home.
#   (2) wildcard lineage + directory fallback      → resolves /home/example.com
#       via tier (b) with no Virtualmin available.
#   (3) delivered filenames use the bare domain, and no path containing a
#       literal '*' is ever created.
#   (4) non-wildcard lineages are unaffected (guards against over-stripping).
#   (5) Virtualmin owns the domain but no <home>/ssl exists → still exit 0, but
#       logged at err priority rather than as a routine skip.

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
# Harness. Mirrors t/regression/20-deploy-hook-home-dir.t, with one difference:
# the mock `virtualmin` records and honours the --domain argument, so a test can
# assert *which* name the hook looked up rather than only that it looked
# something up. That distinction is the whole point of this regression.
# -----------------------------------------------------------------------------

sub stage_sandbox {
    my (%opts) = @_;
    my $sandbox = tempdir('vrm-wild-XXXXXX', TMPDIR => 1, CLEANUP => 1);

    my $lineage = "$sandbox/etc/letsencrypt/live/$opts{cert_name}";
    make_path($lineage);
    _write("$lineage/privkey.pem",
           "-----BEGIN PRIVATE KEY-----\nFAKE_KEY\n-----END PRIVATE KEY-----\n");
    _write("$lineage/cert.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_LEAF\n-----END CERTIFICATE-----\n");
    _write("$lineage/chain.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_INTERMEDIATE\n-----END CERTIFICATE-----\n");
    _write("$lineage/fullchain.pem",
           "-----BEGIN CERTIFICATE-----\nFAKE_LEAF\n-----END CERTIFICATE-----\n" .
           "-----BEGIN CERTIFICATE-----\nFAKE_INTERMEDIATE\n-----END CERTIFICATE-----\n");

    for my $h (@{ $opts{home_dirs} || [] }) {
        make_path("$sandbox/home/$h/ssl");
    }

    my $mock_bin = "$sandbox/mock-bin";
    make_path($mock_bin);
    my $log = "$sandbox/mock.log";

    # Mock `virtualmin`: answers only for the exact domain in $opts{vm_domain},
    # and always records the queried name so the test can assert on it.
    if ($opts{vm_domain}) {
        my $vm_domain = $opts{vm_domain};
        my $vm_home   = $opts{vm_home} // "$sandbox/home/$vm_domain";
        _write("$mock_bin/virtualmin", <<"BASH");
#!/bin/bash
echo "virtualmin \$*" >> "$log"
want=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --domain) want="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ "\$want" = "$vm_domain" ]; then
    echo "Home directory: $vm_home"
fi
exit 0
BASH
    }

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

sub _slurp {
    my ($path) = @_;
    return '' unless -f $path;
    open(my $fh, '<', $path) or return '';
    local $/;
    return <$fh>;
}

sub run_hook {
    my ($lineage, $sandbox, $mock_bin) = @_;
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

    # $lineage contains a literal '*' in the wildcard cases; quote it so the
    # shell cannot glob-expand it before the hook ever sees it.
    my $output = `RENEWED_LINEAGE='$lineage' PATH='$mock_bin':\$PATH bash '$copy' 2>&1`;
    my $exit = $? >> 8;
    return ($output, $exit);
}

# Recursively collect paths under a root, for asterisk-leakage assertions.
sub all_paths {
    my ($root) = @_;
    my @found;
    my @queue = ($root);
    while (my $dir = shift @queue) {
        opendir(my $dh, $dir) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$dir/$e";
            push @found, $p;
            push @queue, $p if -d $p;
        }
        closedir $dh;
    }
    return @found;
}

# -----------------------------------------------------------------------------
# (1) Wildcard lineage, Virtualmin-owned domain.
# -----------------------------------------------------------------------------
subtest 'wildcard lineage resolves via Virtualmin using the stripped name' => sub {
    my ($sb, $lineage, $log, $bin) = stage_sandbox(
        cert_name => '*.example.com',
        vm_domain => 'example.com',
        home_dirs => ['example.com'],
    );

    my ($out, $exit) = run_hook($lineage, $sb, $bin);
    is($exit, 0, 'hook exits 0') or diag($out);

    my $mocklog = _slurp($log);
    like($mocklog, qr/virtualmin list-domains --domain example\.com\b/,
         'Virtualmin queried for the stripped domain');
    unlike($mocklog, qr/--domain \*\./,
           'Virtualmin never queried with the literal asterisk name');

    ok(-f "$sb/home/example.com/ssl/example.com.crt",
       'cert delivered as example.com.crt');
    ok(-f "$sb/home/example.com/ssl/example.com.key",
       'key delivered as example.com.key');
    ok(-f "$sb/home/example.com/ssl.combined",
       'ssl.combined rebuilt');
};

# -----------------------------------------------------------------------------
# (2) Wildcard lineage, no Virtualmin — directory fallback must still work.
# -----------------------------------------------------------------------------
subtest 'wildcard lineage resolves via directory fallback when Virtualmin absent' => sub {
    my ($sb, $lineage, $log, $bin) = stage_sandbox(
        cert_name => '*.example.com',
        home_dirs => ['example.com'],
    );

    my ($out, $exit) = run_hook($lineage, $sb, $bin);
    is($exit, 0, 'hook exits 0') or diag($out);
    ok(-f "$sb/home/example.com/ssl/example.com.crt",
       'tier (b) resolved /home/example.com and delivered the cert');
};

# -----------------------------------------------------------------------------
# (3) No literal asterisk may leak into any created path.
# -----------------------------------------------------------------------------
subtest 'no created path contains a literal asterisk' => sub {
    my ($sb, $lineage, $log, $bin) = stage_sandbox(
        cert_name => '*.example.com',
        vm_domain => 'example.com',
        home_dirs => ['example.com'],
    );
    run_hook($lineage, $sb, $bin);

    my @leaked = grep { m{/home/.*\*} } all_paths("$sb/home");
    is_deeply(\@leaked, [],
              'nothing under home/ carries an asterisk')
        or diag("leaked: @leaked");
};

# -----------------------------------------------------------------------------
# (4) Non-wildcard lineages must be untouched by the stripping.
# -----------------------------------------------------------------------------
subtest 'non-wildcard lineage is unaffected' => sub {
    my ($sb, $lineage, $log, $bin) = stage_sandbox(
        cert_name => 'mail.example.com',
        vm_domain => 'mail.example.com',
        home_dirs => ['mail.example.com'],
    );

    my ($out, $exit) = run_hook($lineage, $sb, $bin);
    is($exit, 0, 'hook exits 0') or diag($out);
    ok(-f "$sb/home/mail.example.com/ssl/mail.example.com.crt",
       'ordinary cert still delivered under its full name');
};

# -----------------------------------------------------------------------------
# (5) Owned-but-undeliverable must be loud, not a routine skip.
# -----------------------------------------------------------------------------
subtest 'Virtualmin owns domain but no ssl dir -> err-priority log, exit 0' => sub {
    my ($sb, $lineage, $log, $bin) = stage_sandbox(
        cert_name => '*.example.com',
        vm_domain => 'example.com',
        vm_home   => '/nonexistent/example.com',
    );

    my ($out, $exit) = run_hook($lineage, $sb, $bin);
    is($exit, 0, 'still exits 0 (other hooks may handle the lineage)')
        or diag($out);

    my $mocklog = _slurp($log);
    like($mocklog, qr/logger .*-p daemon\.err/,
         'undeliverable cert is logged at err priority');
    like($mocklog, qr/NOT delivered/,
         'log states the cert was not delivered');
};

done_testing();
