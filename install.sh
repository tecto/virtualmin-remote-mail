#!/bin/bash
# install.sh — Install virtualmin-remote-mail from GitHub.
#
# Two modes:
#   1. (default — run on vh1) install the Webmin plugin into Virtualmin.
#        curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash
#   2. --install-deploy-hook  (run on the mail server vh2) install the certbot
#      deploy hook only. Use this when vh2 also terminates Let's Encrypt for
#      its own hostname or any domain whose certs are renewed locally.
#        curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh \
#            | bash -s -- --install-deploy-hook
set -e

REPO="https://github.com/trinsiklabs/virtualmin-remote-mail.git"
TMPDIR=$(mktemp -d)
# Single quotes so $TMPDIR is expanded when the trap fires, not when it is set
# (SC2064). Expanding early would bake in an unquoted path.
trap 'rm -rf "$TMPDIR"' EXIT

MODE="plugin"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --install-deploy-hook) MODE="--install-deploy-hook" ;;
        --force)               FORCE=1 ;;
        "")                    ;;
        *) echo "error: unknown option '$arg'" >&2; exit 1 ;;
    esac
done

echo "Downloading virtualmin-remote-mail..."
git clone --depth 1 "$REPO" "$TMPDIR/virtualmin-remote-mail" 2>/dev/null

if [ "$MODE" = "--install-deploy-hook" ]; then
    # vh2-mode: install the certbot deploy hook only.
    HOOK_SRC="$TMPDIR/virtualmin-remote-mail/deploy-hooks/sni-sync.sh"
    HOOK_DST="/etc/letsencrypt/renewal-hooks/deploy/virtualmin-remote-mail-sni-sync.sh"
    if [ ! -f "$HOOK_SRC" ]; then
        echo "error: deploy hook not found in repo at deploy-hooks/sni-sync.sh" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$HOOK_DST")"
    install -m 0755 "$HOOK_SRC" "$HOOK_DST"
    echo "Installed deploy hook: $HOOK_DST"
    echo "It will fire after the next certbot renewal."
    echo "Test it manually with:"
    echo "  sudo env RENEWED_LINEAGE=/etc/letsencrypt/live/<cert-name> bash -x $HOOK_DST"
    exit 0
fi

# --- Guard against silently overwriting a divergent install ------------------
#
# This installer clones main and copies over whatever is already on the server.
# If the server is running code that was never committed, an ordinary
# `curl | bash` destroys it with no warning. That is not hypothetical: in
# 2026-07 vh1 was found running a build roughly three months and ~2300 lines
# ahead of main, which this script would have silently reverted.
#
# So: always back up, and refuse to overwrite a divergent install unless the
# caller explicitly passes --force.

INSTALLED="/usr/share/webmin/virtualmin-remote-mail"
# Paths that live in the repo but are never installed, so they must not count
# as divergence.
DIFF_EXCLUDES=(-x '.git' -x '.github' -x 't' -x 'deploy-hooks' -x 'patches'
               -x '.gitignore' -x 'install.sh')

if [ -d "$INSTALLED" ]; then
    BACKUP="/root/virtualmin-remote-mail.backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar czf "$BACKUP" -C "$(dirname "$INSTALLED")" \
            "$(basename "$INSTALLED")" 2>/dev/null; then
        echo "Backed up current install to $BACKUP"
    else
        echo "warning: could not back up $INSTALLED" >&2
    fi

    if ! diff -rq "${DIFF_EXCLUDES[@]}" \
            "$INSTALLED" "$TMPDIR/virtualmin-remote-mail" >/dev/null 2>&1; then
        echo ""
        echo "The installed module differs from $REPO (main):"
        diff -rq "${DIFF_EXCLUDES[@]}" \
            "$INSTALLED" "$TMPDIR/virtualmin-remote-mail" 2>&1 | sed 's/^/  /'
        echo ""
        if [ "$FORCE" != "1" ]; then
            cat >&2 <<EOF
error: refusing to overwrite a divergent install.

The running code is not the same as main. If the server is ahead, installing
would discard work that was never committed. Reconcile first -- commit the
server's version, or confirm main is genuinely newer -- then re-run with:

    ... | bash -s -- --force

A backup of the current install is at:
    $BACKUP
EOF
            exit 1
        fi
        echo "--force given: proceeding despite divergence."
    fi
fi

echo "Packaging module..."
tar czf "$TMPDIR/virtualmin-remote-mail.wbm.gz" \
    --exclude='.git' --exclude='.github' --exclude='t' --exclude='.gitignore' \
    --exclude='deploy-hooks' --exclude='patches' --exclude='install.sh' \
    -C "$TMPDIR" virtualmin-remote-mail/

echo "Installing module..."
/usr/share/webmin/install-module.pl "$TMPDIR/virtualmin-remote-mail.wbm.gz"

# Register as Virtualmin plugin if not already present
CONFIG="/etc/webmin/virtual-server/config"
if [ -f "$CONFIG" ]; then
    if ! grep -q 'virtualmin-remote-mail' "$CONFIG"; then
        sed -i 's/^plugins=.*/& virtualmin-remote-mail/' "$CONFIG"
        echo "Registered as Virtualmin plugin."
    fi
fi

echo ""
echo "Done! Next steps:"
echo "  1. Configure a remote mail server at:"
echo "     Webmin > Servers > Remote Mail Server"
echo "  2. Enable for a domain:"
echo "     virtualmin enable-feature --domain example.com --virtualmin-remote-mail"
echo "  3. On the mail server (vh2), install the certbot deploy hook:"
echo "     curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh \\"
echo "         | bash -s -- --install-deploy-hook"
