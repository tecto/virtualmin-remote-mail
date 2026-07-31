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

MODE=${1:-plugin}

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

echo "Packaging module..."
tar czf "$TMPDIR/virtualmin-remote-mail.wbm.gz" \
    --exclude='.git' --exclude='t' --exclude='.gitignore' \
    --exclude='install.sh' \
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
