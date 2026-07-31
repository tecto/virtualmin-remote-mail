#!/bin/bash
# sni-sync.sh — Certbot deploy hook for the virtualmin-remote-mail plugin.
#
# Installed at: /etc/letsencrypt/renewal-hooks/deploy/virtualmin-remote-mail-sni-sync.sh
# Fires after certbot successfully renews a cert.
#
# What it does:
#   1. Resolves the home directory the renewed cert "belongs to" (see below).
#   2. Copies the renewed cert/key/chain into <home>/ssl/<cert_name>.{crt,key,ca}.
#   3. Rebuilds <home>/ssl.combined as `key + leaf + intermediate (+ ca)` so
#      Dovecot's `local_name { ssl_cert = </home/.../ssl.combined }` blocks
#      see a full chain (Apple Mail rejects leaf-only chains — see §5.1).
#   4. Runs `postmap -F hash:/etc/postfix/sni_map` (the `-F` flag base64-encodes
#      file contents into the hash; plain `postmap` would store paths and
#      re-read at lookup time — different semantics, brittle. See §5.2).
#   5. Restarts (not reloads) Postfix and Dovecot — Dovecot SNI in particular
#      won't re-pick the ssl_cert file path on SIGHUP.
#
# Home-directory resolution (THIS is the bug class the regression tests cover):
#
#   The cert's `CERT_NAME` (basename of $RENEWED_LINEAGE) does NOT always equal
#   the Virtualmin user's home-directory name. Example:
#       cert "vh2.trinsik.io"    →  Virtualmin user home: /home/vh2
#       cert "mail.example.com"  →  Virtualmin user home: /home/mail.example.com
#
#   Earlier versions of this hook hard-coded `HOME_DIR=/home/$CERT_NAME` and
#   silently exit-0'd when that path did not exist. Production impact: vh2's
#   own renewed cert never got copied into /home/vh2/ssl/, Postfix kept serving
#   the expiring leaf-only cert until users started reporting SSL errors.
#
# This hook first normalises a wildcard lineage name ("*.example.com" →
# "example.com"), then resolves home in three tiered ways:
#   (a) `virtualmin list-domains --domain $CERT_NAME --simple-multiline`
#       — authoritative if a Virtualmin domain owns the cert.
#   (b) /home/$CERT_NAME if it exists as a directory (legacy fallback).
#   (c) /home/${CERT_NAME%%.*} (first dot-segment) — for FQDN certs whose
#       Virtualmin user home is just the short name (the vh2 case).
#
# If none resolve, the hook logs and exits 0 (no error — other hooks may handle
# this lineage). It distinguishes two cases when logging, because they need
# very different responses:
#   - Virtualmin does not know this cert at all  → genuinely not ours, skip.
#   - Virtualmin DOES own the domain but no home/ssl dir was found → the cert
#     should have been delivered and was not. Logged at err priority so it
#     surfaces in monitoring instead of vanishing into a silent exit 0, which
#     is how two domains served expired mail certs for three months.
#
# The hook is intended to be idempotent: running it twice against the same
# lineage produces identical files.

set -euo pipefail

# certbot sets RENEWED_LINEAGE in the environment when invoking deploy hooks.
# If absent (manual invocation without args), exit cleanly.
LINEAGE="${RENEWED_LINEAGE:-}"
[ -z "$LINEAGE" ] && exit 0
[ ! -d "$LINEAGE" ] && exit 0

LINEAGE_NAME=$(basename "$LINEAGE")

# Wildcard lineages are stored on disk with a literal asterisk:
# /etc/letsencrypt/live/*.example.com. Nothing downstream carries that prefix
# — not the Virtualmin domain name, not the home directory, not the SNI map
# entries or the <home>/ssl/<name>.{crt,key,ca} filenames — so normalise it
# away before resolving anything.
#
# Leaving it in place makes ALL THREE resolution tiers below fail: (a) queries
# Virtualmin for a domain named "*.example.com" which does not exist, (b) tests
# the quoted literal path /home/*.example.com/ssl, and (c) reduces to "*" and
# tests /home/*/ssl. The hook then exit-0s and the cert is never delivered.
# That is the smokeandleaf.com incident; see t/regression/10-wildcard-lineage.t.
CERT_NAME="${LINEAGE_NAME#\*.}"

# --- Home directory resolution (tiered) ----------------------------------

HOME_DIR=""

# (a) Ask Virtualmin authoritatively.
# VM_OWNS_DOMAIN records whether Virtualmin knows this domain at all, which is
# what separates "not our cert" from "our cert, delivery failed" further down.
VM_OWNS_DOMAIN=0
if command -v virtualmin >/dev/null 2>&1; then
    home_from_vm=$(virtualmin list-domains --domain "$CERT_NAME" --simple-multiline 2>/dev/null \
                   | awk -F': ' '/^Home directory:/ {print $2; exit}')
    if [ -n "$home_from_vm" ]; then
        VM_OWNS_DOMAIN=1
        if [ -d "$home_from_vm/ssl" ]; then
            HOME_DIR="$home_from_vm"
        fi
    fi
fi

# (b) Legacy fallback: cert name matches directory name (mail.example.com case).
if [ -z "$HOME_DIR" ] && [ -d "/home/$CERT_NAME/ssl" ]; then
    HOME_DIR="/home/$CERT_NAME"
fi

# (c) Hostname fallback: first dot-segment of the FQDN (vh2.trinsik.io → vh2).
if [ -z "$HOME_DIR" ]; then
    short="${CERT_NAME%%.*}"
    if [ -n "$short" ] && [ "$short" != "$CERT_NAME" ] && [ -d "/home/$short/ssl" ]; then
        HOME_DIR="/home/$short"
    fi
fi

if [ -z "$HOME_DIR" ]; then
    if [ "$VM_OWNS_DOMAIN" = "1" ]; then
        # Virtualmin owns this domain, so the cert was meant to land somewhere
        # and did not. Do not let this look like a routine skip.
        logger -p daemon.err -t virtualmin-remote-mail-sni-sync \
            "cert '$CERT_NAME' (lineage '$LINEAGE_NAME') belongs to a Virtualmin domain but no <home>/ssl directory was found — certificate NOT delivered"
    else
        logger -t virtualmin-remote-mail-sni-sync \
            "no Virtualmin domain owns cert '$CERT_NAME' (lineage '$LINEAGE_NAME') — skipping"
    fi
    exit 0
fi

# --- Required source files in the lineage --------------------------------

FULLCHAIN="$LINEAGE/fullchain.pem"
PRIVKEY="$LINEAGE/privkey.pem"
CHAIN="$LINEAGE/chain.pem"

if [ ! -f "$FULLCHAIN" ] || [ ! -f "$PRIVKEY" ]; then
    logger -t virtualmin-remote-mail-sni-sync \
        "missing fullchain or privkey in $LINEAGE — skipping"
    exit 0
fi

# --- Copy cert artifacts -------------------------------------------------

DEST_SSL="$HOME_DIR/ssl"
mkdir -p "$DEST_SSL"

cp "$FULLCHAIN" "$DEST_SSL/$CERT_NAME.crt"
cp "$PRIVKEY"   "$DEST_SSL/$CERT_NAME.key"
[ -f "$CHAIN" ] && cp "$CHAIN" "$DEST_SSL/$CERT_NAME.ca"

# ssl.combined MUST contain leaf + intermediate to satisfy Apple Mail's strict
# chain validation. fullchain.pem already includes leaf + intermediates, so
# concatenating privkey + fullchain gives us key + every cert in the chain.
cat "$PRIVKEY" "$FULLCHAIN" > "$HOME_DIR/ssl.combined"

# Dovecot's local_name block sometimes reads /home/<u>/ssl.key directly.
cp "$PRIVKEY" "$HOME_DIR/ssl.key"

# --- Ownership and permissions -------------------------------------------

DOMAIN_USER=$(stat -c '%U' "$HOME_DIR" 2>/dev/null || echo root)

chown "$DOMAIN_USER:$DOMAIN_USER" \
    "$DEST_SSL/$CERT_NAME.crt" \
    "$DEST_SSL/$CERT_NAME.key" \
    "$HOME_DIR/ssl.combined" \
    "$HOME_DIR/ssl.key" 2>/dev/null || true
[ -f "$DEST_SSL/$CERT_NAME.ca" ] && \
    chown "$DOMAIN_USER:$DOMAIN_USER" "$DEST_SSL/$CERT_NAME.ca" 2>/dev/null || true

chmod 600 "$DEST_SSL/$CERT_NAME.key" "$HOME_DIR/ssl.combined" "$HOME_DIR/ssl.key"

# --- Refresh Postfix SNI map (-F base64-encodes contents) ----------------

if [ -f /etc/postfix/sni_map ]; then
    postmap -F hash:/etc/postfix/sni_map
fi

# --- Restart (not reload) — Dovecot SNI needs full restart --------------

systemctl restart postfix 2>/dev/null || true
systemctl restart dovecot 2>/dev/null || true

logger -t virtualmin-remote-mail-sni-sync \
    "synced $CERT_NAME (lineage $LINEAGE_NAME) to $HOME_DIR"
