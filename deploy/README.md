# Server configuration for the hosted backend

These are the exact files running on the production VPS, copied out so the
host can be rebuilt without reverse-engineering a live box. Editing a file
here does **not** change the server — copy it over and reload the unit.

Host: `srv2047744.hstgr.cloud` (Hostinger VPS, Mumbai, Ubuntu 26.04, 1 vCPU / 3.8 GB)

| File | Goes to |
|---|---|
| `nginx-ispoon.conf` | `/etc/nginx/sites-available/ispoon` |
| `ispoon-backend.service` | `/etc/systemd/system/` |
| `ispoon-deploy{.service,.timer}` | `/etc/systemd/system/` |
| `ispoon-deploy` | `/usr/local/bin/` (mode 755) |
| `fail2ban-jail.local` | `/etc/fail2ban/jail.local` |

## What is deliberate here

**TLS works without owning a domain.** Hostinger gives the VPS an
`srv*.hstgr.cloud` name with both forward and reverse DNS pointing at the
box, so Let's Encrypt HTTP-01 validates against it. A bare IP could not get
a certificate.

**The API binds `127.0.0.1:5000` only.** nginx terminates TLS and proxies in.
`assertSafeListenConfig` in `src/config/security.js` would refuse a wildcard
bind against a Neon `DATABASE_URL` anyway.

**Secrets are not here and never should be.** They live in
`/etc/ispoon/production.env` (mode 600, owned by `ispoon`), outside the git
tree, so a bad checkout cannot expose or overwrite them. Rotating a
credential is an edit there plus `systemctl restart ispoon-backend` — no
commit, no redeploy.

**The unit uses `node --env-file=`, not systemd `EnvironmentFile=`.**
`FIREBASE_PRIVATE_KEY` is a quoted value containing literal `\n` escapes, and
systemd applies its own C-escape processing inside double quotes, which
corrupts the key. Node's parser handles it correctly.

**Every git command in `ispoon-deploy` runs as the `ispoon` user.** Running
some as root was the original bug: git refuses to act on a repository owned by
another user ("dubious ownership") unless the path is in `safe.directory`, and
root's `~/.gitconfig` is unreachable under systemd because systemd does not
set `HOME`. It worked by hand from a login shell and failed every time from
the timer.

**Deploy is a 2-minute poll, not a webhook.** Nothing inbound to secure, no
shared secret to leak, nothing to re-point if the host changes. It restarts
the API only when a commit touches `ispoon-backend/`, runs `npm ci` only when
the lockfile moved, and rolls back to the previous commit if
`/api/health/ready` does not come up.

**`Connection ""`, not `Connection "upgrade"`.** The backend has no
websockets. Sending an upgrade header on every request forced nginx to close
the upstream connection each time, defeating `keepalive 32`.

**`gzip_types` must name `application/json` explicitly.** nginx's default is
`text/html` only, so API responses went out uncompressed. Measured on a 29 KB
payload: 29,062 -> 8,156 bytes.

## Known gaps

- Password SSH is still enabled and root login is permitted. fail2ban covers
  brute force (5 strikes, 1 h ban) but key-only auth is the real fix.
- `fail2ban-jail.local` whitelists the admin network in `ignoreip`. From any
  other network, five failed passwords means an hour's wait.
- The database is in Singapore while the server is in Mumbai: ~59 ms per
  query, and Neon suspends its compute when idle, so the first request after a
  long gap can take 0.5-1.2 s. Co-locating the two is the only real fix.
