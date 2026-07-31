# virtualmin-remote-mail

A Virtualmin plugin that manages email services on a remote mail server. When a domain is created on the web hosting server and this feature is enabled, the plugin delegates all mail operations to a remote Virtualmin instance via its CLI API, and manages DNS records and SSL certificates locally.

## Architecture

This plugin is designed for a split-server setup:

- **vh1** (web/DNS server): Runs Virtualmin, Nginx, PHP-FPM, MariaDB. Manages domains and DNS.
- **email1** (mail server): Runs Virtualmin, Postfix, Dovecot, SpamAssassin, ClamAV. Handles all email.

Communication uses **Webmin RPC** (`remote_foreign_call`) for all remote operations. The plugin calls Virtualmin's CLI API (`virtualmin create-domain`, `create-user`, etc.) on email1 to manage domains and users, rather than configuring Postfix/Dovecot directly.

## What It Does

When the "Remote Mail Server" feature is enabled for a domain:

1. **Domain** (on email1): Creates domain via `virtualmin create-domain --mail --spam --virus` — this handles Unix users, Postfix, Dovecot, SpamAssassin, ClamAV, and all other mail configuration
2. **DKIM** (on email1): Generates DKIM signing key via `virtualmin modify-mail --generate-dkim-key`
3. **DNS** (on vh1): Creates MX, SPF, DKIM, DMARC records and mail host A records
4. **SSL** (vh1 → email1): Syncs SSL certificates to the remote mail server

User management (create, edit, delete, forwarding, auto-reply, spam filtering, etc.) is handled via `virtualmin create-user`, `modify-user`, and `delete-user` on email1.

When the feature is removed, `virtualmin delete-domain` cleans up everything on email1, and DNS records are removed on vh1.

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh | bash
```

This downloads the module from GitHub, packages it, installs it into Webmin, and registers it as a Virtualmin plugin automatically.

## Manual Installation

```bash
# On the web server (vh1):
cd /usr/share/webmin
tar xzf virtualmin-remote-mail.wbm.gz

# Or copy directly:
cp -r virtualmin-remote-mail /usr/share/webmin/

# Register in Virtualmin:
# System Settings → Features and Plugins → enable "Remote Mail Server"
```

## Prerequisites

1. Virtualmin and Webmin installed on both servers
2. email1 registered in vh1's Webmin Servers Index (Webmin → Servers → Webmin Servers Index)
3. Webmin RPC credentials configured for email1

## Configuration

After installation, go to the module page and add a remote mail server with:

- Mail server hostname and Webmin RPC credentials
- Spam gateway IP (optional, for inbound filtering)
- Outgoing relay server (for sender-dependent transports)
- DKIM selector name

## Testing

```bash
cd /usr/share/webmin/virtualmin-remote-mail

# Run unit + regression tests (no server access needed)
prove -r t/

# Run integration tests (requires real servers)
REMOTE_MAIL_INTEGRATION=1 prove t/06-integration.t
```

Regression tests for previously-shipped production bugs live in `t/regression/`.
Each file leads with a header citing the incident, root cause, and fix
artifact, and is verified to fail against the buggy version and pass against
the fix (red-green verification protocol).

## File Structure

```
module.info                    # Module metadata (hidden plugin)
defaultacl                     # Default ACL
config / config.info           # Module configuration
virtualmin-remote-mail-lib.pl  # Core library (RPC, Virtualmin API wrappers)
virtual_feature.pl             # Virtualmin feature hooks
edit.cgi                       # Main module page
edit_servers.cgi               # Add/edit mail servers
save_server.cgi                # Save server config
edit_domain.cgi                # Per-domain mail settings
edit_user.cgi                  # Add/edit remote mail user
save_domain.cgi                # Per-domain actions (overrides, SSL, users)
cgi_args.pl                    # URL argument defaults
log_parser.pl                  # Webmin action log parser
lang/en                        # Language strings
help/feat.html                 # Feature help page
t/                             # Test suite (incl. t/regression/ for prior-bug guards)
deploy-hooks/                  # Certbot deploy hook shipped for the mail server
```

## Certbot Deploy Hook (mail server)

When the mail server (vh2) terminates its own Let's Encrypt cert — for its
hostname or for any domain whose certs are renewed locally rather than synced
from vh1 — install the deploy hook at `deploy-hooks/sni-sync.sh`. It runs after
each successful renewal and:

1. Resolves the renewed cert's home directory via three tiered strategies:
   `virtualmin list-domains` (authoritative), then `/home/<cert-name>` (when
   the cert name matches the Virtualmin user name), then `/home/<short>` where
   `<short>` is the FQDN's first dot-segment (the hostname-cert case — e.g.
   cert `vh2.trinsik.io` → home `/home/vh2`).
2. Copies cert/key/chain into `<home>/ssl/<cert-name>.{crt,key,ca}`.
3. Rebuilds `<home>/ssl.combined` as `key + leaf + chain` (Dovecot's
   `local_name { ssl_cert = </home/...> }` blocks read this file directly, so
   the chain must be inside it — Apple Mail rejects leaf-only chains).
4. Refreshes the Postfix SNI map with `postmap -F` (base64-encoded contents,
   NOT plain `postmap`).
5. Restarts (not reloads) Postfix and Dovecot.

Install on the mail server:

```bash
curl -sL https://raw.githubusercontent.com/trinsiklabs/virtualmin-remote-mail/main/install.sh \
    | bash -s -- --install-deploy-hook
```

The regression test `t/regression/20-deploy-hook-home-dir.t` guards the home-
directory resolution logic; an earlier hook version hard-coded
`HOME_DIR=/home/$CERT_NAME` and silently no-op'd when the cert name didn't
match a home directory (incident: 2026-05-13, vh2's own cert).

## Feature Hooks

The plugin implements the full Virtualmin feature lifecycle:

| Hook | Purpose |
|------|---------|
| `feature_setup` | Creates domain on email1 via Virtualmin API + DNS + DKIM + SSL |
| `feature_delete` | Deletes domain on email1 + DNS cleanup |
| `feature_modify` | Handles domain rename and override changes |
| `feature_disable` / `feature_enable` | Suspend/unsuspend via Virtualmin API |
| `feature_validate` | Verifies remote domain and DNS state |
| `feature_clash` | Prevents conflict with local mail feature |
| `feature_depends` | Requires DNS feature |
| `feature_backup` / `feature_restore` | Domain backup/restore support |

## License

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full text.
