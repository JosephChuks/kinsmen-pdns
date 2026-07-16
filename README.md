# Kinsmen PowerDNS Stack

Self-contained PowerDNS authoritative server installer — same pattern as the Kinsmen Web Panel.  
Tested on **AlmaLinux 8/9**.

---

## Install on a new server

### 1 — PowerDNS authoritative server

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JosephChuks/kinsmen-pdns/main/install-pdns.sh) \
    --api-key YOUR_SECRET_KEY \
    --ns1 dns1.thekinsmenservers.com \
    --ns2 dns2.thekinsmenservers.com
```

Leave off `--api-key` and a random one is generated and printed.

### 2 — PowerDNS-Admin web UI (optional, port 9191)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/JosephChuks/kinsmen-pdns/main/install-pdns-admin.sh)
```

---

## Zone backup and restore

### Backup all zones from a running server

```bash
# Run from your desktop — SSH key access to dns1 required
bash pdns-backup-zones.sh --host dns1 --api-key YOUR_KEY --output-dir /backups/pdns-$(date +%Y%m%d)
```

### Restore zones to a new server

```bash
# After install-pdns.sh has run on the new server:
bash pdns-restore-zones.sh \
    --backup-dir /backups/pdns-20260716 \
    --host NEW_SERVER_IP \
    --api-key NEW_SERVER_API_KEY
```

Existing zones are skipped unless you pass `--force`.

---

## Automated daily backup (cron on dns1)

```bash
# Add to /etc/cron.d/pdns-backup on dns1:
0 3 * * * root bash /opt/pdns-backup.sh >> /var/log/pdns-backup.log 2>&1
```

---

## Emergency recovery checklist

1. Provision new server (AlmaLinux 8/9)
2. `bash install-pdns.sh --api-key SAME_OR_NEW_KEY`
3. `bash install-pdns-admin.sh` (optional)
4. `bash pdns-restore-zones.sh --backup-dir <latest-backup> --host NEW_IP --api-key KEY`
5. Update glue records at registrar: point `dns1.thekinsmenservers.com` → new server IP
6. Run `bash pdns-fix-markers.sh` from desktop to update panel DB markers pointing to new NS

DNS propagates within TTL (usually 300s for our zones).
