# WordPress Server Migration

Migrate a WordPress site from one server to another using [`scripts/migration.sh`](scripts/migration.sh), with a Cloudflare-fronted origin, optional Let's Encrypt TLS on the origin, and a safe **staging → verify → cutover** domain workflow.

```
┌──────────┐        ┌────────────┐         ┌─────────────────────────┐
│ Visitors │ ─────▶ │ Cloudflare │ ──────▶ │ WP Origin (NEW server)  │
└──────────┘  HTTPS └────────────┘  HTTPS  │ /var/www/html           │
                     (proxied)   (Let's     └─────────────────────────┘
                                  Encrypt)
```

The script pulls files + database **from the OLD server onto the NEW server** (it runs *on the new server*), takes a local safety backup first, and rewrites URLs from the old domain to the new domain.

---

## Table of Contents

1. [How the script works](#how-the-script-works)
2. [Prerequisites](#prerequisites)
3. [Configuration](#configuration)
4. [Running the migration](#running-the-migration)
5. [Cloudflare setup (origin behind CF)](#cloudflare-setup)
6. [Let's Encrypt on the origin (optional)](#lets-encrypt-on-the-origin-optional)
7. [Domain workflow: staging → verify → production cutover](#domain-workflow)
8. [Rollback](#rollback)
9. [Troubleshooting](#troubleshooting)

---

## How the script works

Run **on the NEW (destination) server**, from a shell that can SSH into the OLD server. Steps performed by [`scripts/migration.sh`](scripts/migration.sh):

| Step | Action |
|------|--------|
| 0 | **Local safety backup** of the new server's current DB (`wp db export`) + files (`tar`) into `BACKUP_PATH`. |
| 1 | **Export DB on old server** to `remote-db.sql` via SSH + WP-CLI. |
| 2 | **`rsync` files** old → new, with `--delete` (clean file set, prevents "Cannot redeclare" PHP errors). Excludes `wp-config.php` and `.htaccess` so the new server keeps its own config. |
| 3 | **Import DB** on the new server (`wp db import`, 512M memory limit). |
| 4 | **Search-replace URLs** `OLD_DOMAIN` → `NEW_DOMAIN` across the database. |
| 5 | **Cleanup** temporary `remote-db.sql` on both servers. |

> ⚠️ **Destructive by design.** Step 0's backup protects you, but `rsync --delete` will remove files on the new server that don't exist on the old one, and the DB import overwrites the new server's database. Read [Rollback](#rollback) before running.

---

## Prerequisites

**On both servers**
- A working WordPress install at the configured paths.
- [WP-CLI](https://wp-cli.org/) installed and on `$PATH` (`wp --info`).
- PHP CLI with enough memory (script uses `-d memory_limit=512M` for import).

**On the new server (where you run the script)**
- `rsync`, `tar`, `ssh` available.
- SSH key access to the old server (key referenced by `SSH_KEY`).
- Write access to `NEW_PATH` and `BACKUP_PATH`.

**SSH key check**
```bash
ssh -i ~/.ssh/id_ed25519 root@<OLD_SERVER_IP> "wp --info --allow-root"
```
This should print WP-CLI info from the old server without prompting for a password.

---

## Configuration

Edit the variables at the top of [`scripts/migration.sh`](scripts/migration.sh):

```bash
OLD_USER="root"                       # username on the OLD server
OLD_IP="<OLD_SERVER_IP>"              # OLD server IP
OLD_PATH="/var/www/html"              # WP path on OLD server
NEW_PATH="/var/www/html"              # WP path on NEW server
SSH_KEY="~/.ssh/id_ed25519"           # private key for SSH to OLD server

OLD_DOMAIN="https://www.avm.edu.in"   # current production URL
NEW_DOMAIN="https://new.avm.edu.in"   # staging URL for verification
BACKUP_PATH="/root/backup"            # local backup dir on NEW server
```

> **Notes**
> - `--allow-root` is used because the script runs WP-CLI as root. If you run as a non-root web user, drop `--allow-root`.
> - `wp-config.php` and `.htaccess` are intentionally **not** synced. Make sure the new server's `wp-config.php` has correct DB credentials, table prefix, salts, and `WP_HOME`/`WP_SITEURL` if hardcoded.
> - The search-replace does **not** handle serialized data edge cases beyond WP-CLI's built-in handling; WP-CLI's `search-replace` is serialization-aware, so this is generally safe.

---

## Running the migration

```bash
# On the NEW server
chmod +x scripts/migration.sh
./scripts/migration.sh
```

**Recommended dry run of the file sync first** (no changes made):
```bash
rsync -avzn -e "ssh -i ~/.ssh/id_ed25519" --delete \
  --exclude 'wp-config.php' --exclude '.htaccess' \
  root@<OLD_SERVER_IP>:/var/www/html/ /var/www/html/
```
The `-n` flag makes it a dry run — review what would be deleted/transferred before committing.

After the script finishes, flush caches:
```bash
wp cache flush --allow-root
wp rewrite flush --allow-root
```

---

## Cloudflare setup

Goal: **Visitors → Cloudflare (proxied) → your WP origin server.**

1. **Add the site to Cloudflare** and point your registrar's nameservers at Cloudflare (one-time, for the zone `avm.edu.in`).
2. **DNS records** (DNS tab):
   - `new` → A record → **new server IP** → **Proxied** (orange cloud) — staging host.
   - `www` → A/CNAME → currently still pointing at the **old** server until cutover.
3. **SSL/TLS mode** (SSL/TLS → Overview): set to **Full (strict)** once the origin has a valid Let's Encrypt cert. Use **Full** (not strict) if the origin only has a self-signed cert temporarily. Avoid **Flexible** — it causes redirect loops with WordPress configured for HTTPS.
4. **Always Use HTTPS**: On (SSL/TLS → Edge Certificates).
5. Because traffic is proxied, the origin sees Cloudflare IPs. To log real visitor IPs, restore them via [`mod_cloudflare` / `mod_remoteip`](https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/) and trust Cloudflare's IP ranges.

> **Origin lock-down (recommended):** once everything works through Cloudflare, restrict the origin firewall to only accept ports 80/443 from [Cloudflare's IP ranges](https://www.cloudflare.com/ips/), so nobody can bypass Cloudflare by hitting the IP directly.

---

## Let's Encrypt on the origin (optional)

Even behind Cloudflare, a real cert on the origin lets you use SSL mode **Full (strict)** (encrypted + validated origin). Two options:

### Option A — Cloudflare Origin Certificate (simplest)
Cloudflare can issue a 15-year origin cert (SSL/TLS → Origin Server → Create Certificate). Install it on the origin and set SSL mode to **Full (strict)**. No renewal hassle. This is **not** Let's Encrypt but achieves the same end and is easier behind CF.

### Option B — Let's Encrypt via Certbot
Because the hostname is proxied (orange cloud), the HTTP-01 challenge can fail. Two ways around it:

**B1. Temporarily grey-cloud during issuance**
```bash
sudo apt install certbot python3-certbot-apache   # or -nginx
# In Cloudflare, set the DNS record to "DNS only" (grey cloud) temporarily
sudo certbot --apache -d new.avm.edu.in
# Re-enable the proxy (orange cloud) afterward
```

**B2. DNS-01 challenge with the Cloudflare plugin (keeps proxy on)**
```bash
sudo apt install certbot python3-certbot-dns-cloudflare
# Create an API token (Zone:DNS:Edit) and store it:
#   ~/.secrets/cloudflare.ini  →  dns_cloudflare_api_token = <token>
sudo chmod 600 ~/.secrets/cloudflare.ini
sudo certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials ~/.secrets/cloudflare.ini \
  -d new.avm.edu.in -d www.avm.edu.in
```
Then point your web server (Apache/Nginx) at the issued cert and reload. Certbot installs a renewal timer automatically — verify with:
```bash
sudo certbot renew --dry-run
```

After the cert is live, set Cloudflare **SSL/TLS → Full (strict)**.

---

## Domain workflow

Three-phase plan to migrate `www.avm.edu.in` → new server with zero/minimal downtime.

### Phase 1 — Stage on `new.avm.edu.in`
1. Configure the script with `NEW_DOMAIN="https://new.avm.edu.in"` (as shipped).
2. In Cloudflare, create `new` → A → new server IP (proxied).
3. Run [`scripts/migration.sh`](scripts/migration.sh). This copies prod content and rewrites URLs to the staging domain.
4. Ensure `wp-config.php` on the new server has matching DB creds; optionally pin:
   ```bash
   wp option update home "https://new.avm.edu.in" --allow-root
   wp option update siteurl "https://new.avm.edu.in" --allow-root
   ```

### Phase 2 — Verify
- Browse `https://new.avm.edu.in` — pages, media, menus, forms, login/admin.
- Check for mixed-content or hardcoded old-domain URLs:
  ```bash
  wp search-replace 'www.avm.edu.in' 'new.avm.edu.in' --dry-run --allow-root
  ```
- Verify permalinks, plugins, and any CDN/cache settings.
- Confirm TLS: `curl -I https://new.avm.edu.in` returns 200 over HTTPS.

> 💡 Avoid having two live copies indexed by Google. Temporarily add `X-Robots-Tag: noindex` (or Cloudflare rule) on `new.avm.edu.in` while staging.

### Phase 3 — Cutover to production `www.avm.edu.in`
Once verified, switch the database back to the production domain and move DNS:

1. **Rewrite URLs back to production** (run on the new server):
   ```bash
   wp search-replace 'https://new.avm.edu.in' 'https://www.avm.edu.in' --allow-root
   wp option update home 'https://www.avm.edu.in' --allow-root
   wp option update siteurl 'https://www.avm.edu.in' --allow-root
   wp cache flush --allow-root
   wp rewrite flush --allow-root
   ```
2. **Update DNS in Cloudflare:** change `www` (and apex `@` if used) A/CNAME to point at the **new server IP**, proxied (orange cloud).
   - Lower the TTL to the minimum (or "Auto") **before** cutover to speed propagation.
3. **Confirm** `https://www.avm.edu.in` now serves from the new origin (check via Cloudflare cache purge, then a hard refresh).
4. **Purge Cloudflare cache:** Caching → Configuration → Purge Everything.
5. Keep the `new.avm.edu.in` record for a few days as a fallback, then remove it (and its noindex rule).

> **Tip:** to flip the production domain in one script run instead, set `NEW_DOMAIN="https://www.avm.edu.in"` and run the migration directly — but only do this *after* you've validated the process on staging, since it overwrites prod URLs immediately.

---

## Rollback

The script's Step 0 writes timestamped backups to `BACKUP_PATH` on the new server:

```
/root/backup/local_db_<TIMESTAMP>.sql
/root/backup/local_files_<TIMESTAMP>.tar.gz
```

To restore the new server to its pre-migration state:
```bash
cd /var/www/html
wp db import /root/backup/local_db_<TIMESTAMP>.sql --allow-root
tar -xzf /root/backup/local_files_<TIMESTAMP>.tar.gz -C /var/www/html
wp cache flush --allow-root
```

To roll back **production DNS**, repoint `www` in Cloudflare back to the old server IP. Because DNS is fronted by Cloudflare, propagation to visitors is typically seconds-to-minutes (set a low TTL beforehand).

> The **old server is left untouched** by this script (only a temporary `remote-db.sql` is created and removed). It remains your ultimate fallback until you decommission it.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `Cannot redeclare function …` after sync | Stale plugin/theme files. The `--delete` rsync flag fixes this; ensure it ran. |
| Redirect loop / "too many redirects" | Cloudflare SSL mode set to **Flexible**. Switch to **Full** or **Full (strict)**. |
| Mixed-content warnings | Hardcoded `http://` or old-domain URLs. Re-run `wp search-replace` for the variants (`http://`, `https://`, with/without `www`). |
| Origin IP exposed | Lock firewall to Cloudflare IP ranges; ensure no DNS record is grey-clouded. |
| `wp: command not found` over SSH | WP-CLI not on `$PATH` in the non-interactive SSH shell. Use a full path or `php $(which wp)`. |
| Real visitor IPs all show Cloudflare | Configure `mod_remoteip`/`mod_cloudflare` and trust CF ranges. |
| DB import out of memory | Raise `memory_limit` in the `php -d` flag, or import via `mysql` directly. |
| Let's Encrypt HTTP-01 fails | Hostname is proxied; grey-cloud temporarily (B1) or use DNS-01 (B2). |

---

## Quick checklist

- [ ] SSH key works to old server, WP-CLI present on both
- [ ] Variables in `migration.sh` configured
- [ ] Cloudflare `new` record created (proxied)
- [ ] Dry-run rsync reviewed
- [ ] Run `migration.sh`, flush caches
- [ ] Verify `new.avm.edu.in` fully
- [ ] (Optional) Origin cert installed, SSL mode Full (strict)
- [ ] Search-replace back to `www`, update DNS, purge cache
- [ ] Keep backups + old server until confident, then decommission
