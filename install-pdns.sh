#!/bin/bash
# install-pdns.sh — Install PowerDNS Authoritative Server on AlmaLinux 8/9
#
# Usage:
#   bash install-pdns.sh [--api-key KEY] [--ns1 dns1.example.com] [--ns2 dns2.example.com]
#
# Installs:
#   - PowerDNS authoritative server with SQLite backend
#   - API enabled on port 8081 (localhost only — nginx proxies externally if needed)
#   - Firewall rules for DNS (port 53 UDP/TCP)
#   - Logrotate

set -euo pipefail

API_KEY=""
NS1=""
NS2=""
PDNS_CONF="/etc/pdns/pdns.conf"
SQLITE_DB="/var/lib/pdns/pdns.sqlite3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key) API_KEY="$2"; shift 2 ;;
        --ns1)     NS1="$2"; shift 2 ;;
        --ns2)     NS2="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

# Generate API key if not provided
if [[ -z "$API_KEY" ]]; then
    API_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    warn "No --api-key given — generated: $API_KEY"
    warn "Save this key — it won't be shown again"
fi

# ── Install PowerDNS ──────────────────────────────────────────────────────────

info "Adding PowerDNS repo..."
# Disable RHEL's own bind/unbound from catching port 53
systemctl stop named 2>/dev/null || true
systemctl disable named 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true

curl -fsSL https://repo.powerdns.com/repo-files/el-auth-49.repo \
    -o /etc/yum.repos.d/pdns.repo 2>/dev/null || {
    # Fallback: use distro packages (may be older)
    warn "PowerDNS repo unavailable — using distro packages"
}

info "Installing PowerDNS and SQLite backend..."
dnf install -y -q pdns pdns-backend-sqlite sqlite 2>/dev/null || \
dnf install -y pdns pdns-backend-sqlite sqlite

ok "PowerDNS installed: $(pdns_server --version 2>&1 | head -1)"

# ── SQLite database ───────────────────────────────────────────────────────────

info "Initialising SQLite database..."
mkdir -p "$(dirname "$SQLITE_DB")"

# Schema from PowerDNS docs
sqlite3 "$SQLITE_DB" << 'SQLEOF'
CREATE TABLE IF NOT EXISTS domains (
  id                    INTEGER PRIMARY KEY,
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INTEGER DEFAULT NULL,
  type                  VARCHAR(8) NOT NULL,
  notified_serial       INTEGER DEFAULT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
  options               VARCHAR(65535) DEFAULT NULL,
  catalog               VARCHAR(255) DEFAULT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS name_index ON domains(name);

CREATE TABLE IF NOT EXISTS records (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER DEFAULT NULL,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(65535) DEFAULT NULL,
  ttl                   INTEGER DEFAULT NULL,
  prio                  INTEGER DEFAULT NULL,
  disabled              BOOLEAN DEFAULT 0,
  ordername             VARCHAR(255),
  auth                  BOOL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS rec_name_index ON records(name);
CREATE INDEX IF NOT EXISTS nametype_index ON records(name,type);
CREATE INDEX IF NOT EXISTS domain_id ON records(domain_id);

CREATE TABLE IF NOT EXISTS supermasters (
  ip                    VARCHAR(64) NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) NOT NULL,
  PRIMARY KEY(ip, nameserver)
);

CREATE TABLE IF NOT EXISTS comments (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER NOT NULL,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INTEGER NOT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  comment               VARCHAR(65535) NOT NULL
);

CREATE TABLE IF NOT EXISTS domainmetadata (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER NOT NULL,
  kind                  VARCHAR(32),
  content               TEXT
);
CREATE INDEX IF NOT EXISTS domainmetaidindex ON domainmetadata(domain_id);

CREATE TABLE IF NOT EXISTS cryptokeys (
  id                    INTEGER PRIMARY KEY,
  domain_id             INTEGER NOT NULL,
  flags                 INTEGER NOT NULL,
  active                BOOL,
  published             BOOL DEFAULT 1,
  content               TEXT
);
CREATE INDEX IF NOT EXISTS domainidindex ON cryptokeys(domain_id);

CREATE TABLE IF NOT EXISTS tsigkeys (
  id                    INTEGER PRIMARY KEY,
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255)
);
CREATE UNIQUE INDEX IF NOT EXISTS namealgoindex ON tsigkeys(name, algorithm);
SQLEOF

chown pdns:pdns "$SQLITE_DB" 2>/dev/null || chown root:root "$SQLITE_DB"
chmod 640 "$SQLITE_DB"
ok "SQLite database ready at $SQLITE_DB"

# ── Configuration ─────────────────────────────────────────────────────────────

info "Writing /etc/pdns/pdns.conf..."

# Determine server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

cat > "$PDNS_CONF" << EOF
# PowerDNS Authoritative Server — Kinsmen DNS
setuid=pdns
setgid=pdns

# Network
local-address=0.0.0.0
local-port=53

# Backend
launch=gsqlite3
gsqlite3-database=$SQLITE_DB
gsqlite3-pragma-synchronous=1

# API (localhost only)
api=yes
api-key=$API_KEY
webserver=yes
webserver-address=127.0.0.1
webserver-port=8081
webserver-allow-from=127.0.0.1,::1

# Performance
receiver-threads=2
distributor-threads=2
cache-ttl=20
negquery-cache-ttl=60

# Logging
log-dns-queries=no
log-dns-details=no
loglevel=3

# Zone transfers (allow panel servers to pull if needed)
disable-axfr=no
EOF

ok "Configuration written"

# ── Enable and start ──────────────────────────────────────────────────────────

info "Starting PowerDNS..."
systemctl daemon-reload
systemctl enable pdns
systemctl restart pdns
sleep 2
systemctl is-active pdns >/dev/null && ok "PowerDNS is running" || die "PowerDNS failed to start — check: journalctl -u pdns"

# Verify API
sleep 1
curl -sf -H "X-API-Key: $API_KEY" "http://127.0.0.1:8081/api/v1/servers/localhost" >/dev/null && ok "API responding" || warn "API not responding yet — may take a moment"

# ── Firewall ──────────────────────────────────────────────────────────────────

if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns &>/dev/null
    firewall-cmd --permanent --add-port=8081/tcp &>/dev/null
    firewall-cmd --reload &>/dev/null
    ok "Firewall: port 53 (DNS) and 8081 (API) opened"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
ok "PowerDNS installed and running"
echo ""
echo -e "  ${CYAN}API URL:${NC}     http://127.0.0.1:8081/api/v1/servers/localhost"
echo -e "  ${CYAN}API Key:${NC}     $API_KEY"
echo -e "  ${CYAN}DB:${NC}          $SQLITE_DB"
echo ""
echo "  Next steps:"
echo "    Install web UI:  bash install-pdns-admin.sh"
echo "    Restore zones:   bash pdns-restore-zones.sh --backup-dir <backup> --host localhost --api-key $API_KEY"
echo ""
echo -e "  ${YELLOW}Save the API key above — add it to your panel_settings (pdns_api_key).${NC}"
