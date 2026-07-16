#!/bin/bash
# install-pdns-server.sh — Full PowerDNS + Admin UI installer for Kinsmen panel
#
# Installs on a blank AlmaLinux 8/9 server:
#   - MariaDB (PowerDNS zone storage)
#   - PowerDNS authoritative server (primary or secondary mode)
#   - PowerDNS Admin web UI on port 9191
#   - nginx reverse proxy
#   - First-run admin account setup (signup auto-disabled after first account)
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   Primary server (panel API points here, notifies secondaries):
#     bash install-pdns-server.sh --mode primary \
#         --api-key YOUR_KEY \
#         --panel-ip 1.2.3.4 \
#         --secondary-ip 5.6.7.8
#
#   Secondary server (receives zone transfers from primary):
#     bash install-pdns-server.sh --mode secondary \
#         --primary-ip 1.2.3.4 \
#         --primary-ns ns1.thekinsmenservers.com \
#         --api-key YOUR_KEY \
#         --panel-ip 1.2.3.4
#
#   Multiple panel/secondary IPs:
#     --panel-ip 1.2.3.4 --panel-ip 5.6.7.8
#     --secondary-ip 9.10.11.12 --secondary-ip 13.14.15.16
#
# ── Replacing a failed server ─────────────────────────────────────────────────
#
#   If secondary fails → new secondary:
#     1. Run this script on new server: --mode secondary --primary-ip <dns1-ip>
#     2. On primary: add new IP to also-notify + allow-axfr-ips in pdns.conf, restart pdns
#     3. On primary: pdns_control notify-host all <new-secondary-ip>
#     4. Update panel pdns_api_url if needed (it stays pointing at primary)
#
#   If primary fails → promote secondary, then add new secondary:
#     1. On surviving secondary: convert all zones to primary type:
#          pdns_control list-zones | while read z; do pdnsutil change-zone-type "$z" PRIMARY; done
#     2. In panel admin Settings → PowerDNS API URL → change to secondary's IP:8081
#     3. Run this script on new server: --mode secondary --primary-ip <old-secondary-ip>
#     4. On promoted primary: add new server IP to also-notify + allow-axfr-ips, restart pdns

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

MODE="primary"
API_KEY=""
DB_PASS=""
PANEL_IPS=()
SECONDARY_IPS=()
PRIMARY_IP=""
PRIMARY_NS=""
ADMIN_PORT=9191
GUNICORN_PORT=9292
INSTALL_DIR="/opt/pdns-admin"
NGINX_CONF="/etc/nginx/conf.d/pdns-admin.conf"
SECRET_FILE="/etc/pdns-admin.secret"
PDNS_CONF="/etc/pdns/pdns.conf"
DB_NAME="powerdns"
DB_USER="pdns"

# ── Arg parsing ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)         MODE="$2"; shift 2 ;;
        --api-key)      API_KEY="$2"; shift 2 ;;
        --db-pass)      DB_PASS="$2"; shift 2 ;;
        --panel-ip)     PANEL_IPS+=("$2"); shift 2 ;;
        --secondary-ip) SECONDARY_IPS+=("$2"); shift 2 ;;
        --primary-ip)   PRIMARY_IP="$2"; shift 2 ;;
        --primary-ns)   PRIMARY_NS="$2"; shift 2 ;;
        --admin-port)   ADMIN_PORT="$2"; shift 2 ;;
        -h|--help)
            sed -n '/#.*Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ "$MODE" =~ ^(primary|secondary)$ ]] || { echo "--mode must be primary or secondary" >&2; exit 1; }
[[ "$MODE" == "secondary" && -z "$PRIMARY_IP" ]] && { echo "--primary-ip required for secondary mode" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# Generate secrets if not provided
[[ -z "$API_KEY" ]] && API_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)
[[ -z "$DB_PASS" ]] && DB_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo -e "${BOLD}Kinsmen PowerDNS Server Installer${NC}"
echo -e "Mode: ${CYAN}${MODE}${NC}  |  IP: ${SERVER_IP}  |  Admin UI port: ${ADMIN_PORT}"
echo ""

# ── 1. System dependencies ────────────────────────────────────────────────────

hdr "System dependencies"

# Stop anything that might hold port 53
systemctl stop named 2>/dev/null || true
systemctl disable named 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# Node 18+ (default EL8 is Node 10 — too old for frontend build)
NODE_VER=$(node --version 2>/dev/null | grep -oP '\d+' | head -1 || echo "0")
if [[ "$NODE_VER" -lt 18 ]]; then
    info "Upgrading Node.js to 18 (current: ${NODE_VER:-none})..."
    dnf module reset nodejs -y -q 2>/dev/null || true
    dnf module enable nodejs:18 -y -q 2>/dev/null || true
fi

# Python 3.9 (EL8 ships 3.6 which is too old for PowerDNS-Admin)
dnf install -y -q python39 python39-devel python39-pip 2>/dev/null || true

# Build tools + libs
dnf install -y -q \
    gcc gcc-c++ make \
    openssl-devel libffi-devel libxml2-devel libxslt-devel \
    openldap-devel cyrus-sasl-devel \
    sqlite sqlite-devel \
    git curl wget \
    nodejs npm \
    nginx 2>/dev/null || \
dnf install -y \
    gcc gcc-c++ make \
    openssl-devel libffi-devel \
    sqlite git curl wget \
    nodejs npm \
    nginx

npm install -g yarn --quiet 2>/dev/null || true
ok "System dependencies installed (Node $(node --version 2>/dev/null))"

# ── 2. MariaDB ────────────────────────────────────────────────────────────────

hdr "MariaDB"

dnf install -y -q mariadb-server mariadb 2>/dev/null || dnf install -y mariadb-server mariadb
systemctl enable mariadb
systemctl start mariadb
sleep 2

mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8;" 2>/dev/null
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || \
mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';" 2>/dev/null
mysql -e "FLUSH PRIVILEGES;" 2>/dev/null

# PowerDNS MySQL schema
mysql "$DB_NAME" << 'SQLEOF'
CREATE TABLE IF NOT EXISTS domains (
  id                    INT NOT NULL AUTO_INCREMENT,
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INT DEFAULT NULL,
  type                  VARCHAR(8) NOT NULL,
  notified_serial       BIGINT DEFAULT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
  options               VARCHAR(65535) DEFAULT NULL,
  catalog               VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';
CREATE UNIQUE INDEX IF NOT EXISTS name_index ON domains(name);

CREATE TABLE IF NOT EXISTS records (
  id                    BIGINT NOT NULL AUTO_INCREMENT,
  domain_id             INT DEFAULT NULL,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(65535) DEFAULT NULL,
  ttl                   INT DEFAULT NULL,
  prio                  INT DEFAULT NULL,
  disabled              TINYINT(1) DEFAULT 0,
  ordername             VARCHAR(255) BINARY DEFAULT NULL,
  auth                  TINYINT(1) DEFAULT 1,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';
CREATE INDEX IF NOT EXISTS nametype_index ON records(name,type);
CREATE INDEX IF NOT EXISTS domain_id ON records(domain_id);
CREATE INDEX IF NOT EXISTS ordername ON records(ordername);

CREATE TABLE IF NOT EXISTS supermasters (
  ip                    VARCHAR(64) NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' NOT NULL,
  PRIMARY KEY (ip, nameserver)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE TABLE IF NOT EXISTS comments (
  id                    INT NOT NULL AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
  comment               TEXT NOT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE TABLE IF NOT EXISTS domainmetadata (
  id                    INT NOT NULL AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  kind                  VARCHAR(32),
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';
CREATE INDEX IF NOT EXISTS domainidmetaindex ON domainmetadata(domain_id);

CREATE TABLE IF NOT EXISTS cryptokeys (
  id                    INT NOT NULL AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  flags                 INT NOT NULL,
  active                BOOL,
  published             BOOL DEFAULT 1,
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';
CREATE INDEX IF NOT EXISTS domainidindex ON cryptokeys(domain_id);

CREATE TABLE IF NOT EXISTS tsigkeys (
  id                    INT NOT NULL AUTO_INCREMENT,
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255),
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';
CREATE UNIQUE INDEX IF NOT EXISTS namealgoindex ON tsigkeys(name, algorithm);
SQLEOF

ok "MariaDB ready — database '${DB_NAME}' created"

# ── 3. PowerDNS ───────────────────────────────────────────────────────────────

hdr "PowerDNS"

# Try official repo first, fall back to distro
curl -fsSL https://repo.powerdns.com/repo-files/el-auth-49.repo \
    -o /etc/yum.repos.d/pdns.repo 2>/dev/null || warn "Official PowerDNS repo unavailable — using distro packages"

dnf install -y -q pdns pdns-backend-mysql 2>/dev/null || dnf install -y pdns pdns-backend-mysql

# Build webserver-allow-from: always 127.0.0.1, plus all panel IPs
ALLOW_FROM="127.0.0.1"
for ip in "${PANEL_IPS[@]}"; do ALLOW_FROM="${ALLOW_FROM},${ip}"; done
# Also allow secondaries to query API (for admin UI connections)
for ip in "${SECONDARY_IPS[@]}"; do ALLOW_FROM="${ALLOW_FROM},${ip}"; done
[[ -n "$PRIMARY_IP" ]] && ALLOW_FROM="${ALLOW_FROM},${PRIMARY_IP}"

cat > "$PDNS_CONF" << EOF
# PowerDNS Authoritative Server — Kinsmen DNS (${MODE})
setuid=pdns
setgid=pdns

# Network
local-address=0.0.0.0
local-port=53

# Backend
launch=gmysql
gmysql-host=127.0.0.1
gmysql-dbname=${DB_NAME}
gmysql-user=${DB_USER}
gmysql-password=${DB_PASS}

# API
api=yes
api-key=${API_KEY}
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=${ALLOW_FROM}

# Performance
receiver-threads=2
distributor-threads=2
cache-ttl=20
negquery-cache-ttl=60

# Logging
log-dns-queries=no
log-dns-details=no
loglevel=3
EOF

# Primary-specific settings
if [[ "$MODE" == "primary" ]]; then
    ALSO_NOTIFY=""
    ALLOW_AXFR=""
    for ip in "${SECONDARY_IPS[@]}"; do
        ALSO_NOTIFY="${ALSO_NOTIFY:+${ALSO_NOTIFY},}${ip}"
        ALLOW_AXFR="${ALLOW_AXFR:+${ALLOW_AXFR},}${ip}"
    done
    if [[ -n "$ALSO_NOTIFY" ]]; then
        echo "also-notify=${ALSO_NOTIFY}" >> "$PDNS_CONF"
        echo "allow-axfr-ips=${ALLOW_AXFR}" >> "$PDNS_CONF"
    fi
    echo "disable-axfr=no" >> "$PDNS_CONF"
fi

# Secondary-specific settings
if [[ "$MODE" == "secondary" ]]; then
    cat >> "$PDNS_CONF" << EOF

# Secondary mode — receives zone transfers from primary
secondary=yes
autosecondary=yes
EOF

    # Register primary as supermaster so zones auto-transfer
    NS="${PRIMARY_NS:-ns1.thekinsmenservers.com}"
    mysql "$DB_NAME" -e \
        "INSERT IGNORE INTO supermasters (ip, nameserver, account) VALUES ('${PRIMARY_IP}', '${NS}', '');" \
        2>/dev/null && ok "Primary ${PRIMARY_IP} registered as supermaster"
fi

systemctl daemon-reload
systemctl enable pdns
systemctl restart pdns
sleep 2
systemctl is-active pdns >/dev/null && ok "PowerDNS running" || die "PowerDNS failed — run: journalctl -u pdns -n 30"

# Verify API
sleep 1
curl -sf -H "X-API-Key: ${API_KEY}" "http://127.0.0.1:8081/api/v1/servers/localhost" >/dev/null \
    && ok "PowerDNS API responding" \
    || warn "API not responding yet — may need a moment"

# ── 4. PowerDNS Admin UI ──────────────────────────────────────────────────────

hdr "PowerDNS Admin UI"

SERVICE_USER="pdnsadmin"
SERVICE_FILE="/etc/systemd/system/pdns-admin.service"
PDNS_API_URL="http://127.0.0.1:8081/api/v1"

# Service user
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /sbin/nologin -d "$INSTALL_DIR" "$SERVICE_USER"
    ok "Created user $SERVICE_USER"
fi

# Clone or update
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating PowerDNS-Admin..."
    git -C "$INSTALL_DIR" pull -q
else
    info "Cloning PowerDNS-Admin..."
    git clone -q --depth 1 https://github.com/PowerDNS-Admin/PowerDNS-Admin.git "$INSTALL_DIR"
fi
ok "Source ready at $INSTALL_DIR"

# Python venv
info "Setting up Python environment..."
PYTHON_BIN=$(command -v python3.9 || command -v python3.8 || command -v python3)
"$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"
pip install -q --upgrade pip setuptools wheel

# Strip DB drivers that need external dev headers (we use SQLite for the admin app)
CLEANED_REQ=$(mktemp)
grep -v '^--' "$INSTALL_DIR/requirements.txt" \
    | grep -v '^mysqlclient' \
    | grep -v '^psycopg2' \
    > "$CLEANED_REQ"
pip install -q -r "$CLEANED_REQ" || pip install -r "$CLEANED_REQ"
rm -f "$CLEANED_REQ"
ok "Python environment ready"

# Secret key
if [[ ! -f "$SECRET_FILE" ]]; then
    python3 -c "import secrets; print(secrets.token_hex(32))" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi
SECRET_KEY=$(cat "$SECRET_FILE")

# App config
mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data/flask_sessions"

cat > "$INSTALL_DIR/powerdnsadmin/default_config.py" << PYEOF
import os

# Flask
SECRET_KEY = '${SECRET_KEY}'
BIND_ADDRESS = '127.0.0.1'
PORT = ${GUNICORN_PORT}
LOGIN_TITLE = 'Kinsmen DNS Admin'

# SQLite database for admin users/settings (separate from PowerDNS zone DB)
SQLA_DB_USER = ''
SQLA_DB_PASSWORD = ''
SQLA_DB_HOST = ''
SQLA_DB_NAME = '${INSTALL_DIR}/data/pdns-admin.db'
SQLALCHEMY_DATABASE_URI = 'sqlite:///${INSTALL_DIR}/data/pdns-admin.db'
SQLALCHEMY_TRACK_MODIFICATIONS = True

# PowerDNS API connection
PDNS_STATS_URL = '${PDNS_API_URL}/'
PDNS_API_KEY = '${API_KEY}'
PDNS_VERSION = '4.7.0'

# Features
SIGNUP_ENABLED = True
OFFLINE_MODE = False
RECORDS_ALLOW_EDIT = ['A', 'AAAA', 'CNAME', 'MX', 'NS', 'SOA', 'SRV', 'TXT', 'CAA', 'TLSA', 'SSHFP', 'LOC', 'NAPTR', 'ALIAS']

# Session (filesystem required by flask_session_captcha)
SESSION_TYPE = 'filesystem'
SESSION_FILE_DIR = '${INSTALL_DIR}/data/flask_sessions'
SESSION_PERMANENT = False
SESSION_COOKIE_SAMESITE = 'Lax'

# Disabled features
CAPTCHA_ENABLE = False
SAML_ENABLED = False
PYEOF

ok "App configured"

# Build frontend assets
info "Building frontend assets (this may take a few minutes)..."
cd "$INSTALL_DIR"
yarn install 2>&1 | grep -E 'error|warning Resolution' | head -5 || true
yarn build 2>&1 | tail -5 || true

if ls "$INSTALL_DIR/powerdnsadmin/static/generated/"*.js &>/dev/null 2>&1 || \
   ls "$INSTALL_DIR/powerdnsadmin/static/node_modules/@fortawesome" &>/dev/null 2>&1; then
    ok "Frontend assets built"
else
    warn "Frontend build may be incomplete — run 'cd $INSTALL_DIR && yarn build' if UI looks broken"
fi

# Database init
info "Initialising admin database..."
export FLASK_APP=powerdnsadmin/__init__.py
"$INSTALL_DIR/venv/bin/flask" db upgrade 2>/dev/null || \
"$INSTALL_DIR/venv/bin/python3" -c "
from powerdnsadmin import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('DB tables created')
" 2>/dev/null || warn "DB init had warnings — may need manual init on first login"

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
ok "Admin database ready"

# Systemd service
pip install -q gunicorn

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=PowerDNS Admin Web UI
After=network.target pdns.service
Wants=pdns.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
Environment="FLASK_APP=powerdnsadmin/__init__.py"
Environment="FLASK_ENV=production"
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn \
    --workers 2 \
    --bind 127.0.0.1:${GUNICORN_PORT} \
    --timeout 120 \
    --access-logfile ${INSTALL_DIR}/data/access.log \
    --error-logfile ${INSTALL_DIR}/data/error.log \
    "powerdnsadmin:create_app()"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pdns-admin
systemctl restart pdns-admin
ok "pdns-admin service started"

# ── 5. Nginx ──────────────────────────────────────────────────────────────────

hdr "Nginx"

cat > "$NGINX_CONF" << EOF
# PowerDNS Admin — port ${ADMIN_PORT} (nginx) → ${GUNICORN_PORT} (gunicorn)
server {
    listen ${ADMIN_PORT};
    server_name _;
    client_max_body_size 10m;

    location / {
        proxy_pass         http://127.0.0.1:${GUNICORN_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
EOF

# Some setups (e.g. pure-proxy dns servers) don't include conf.d — add include if missing
if ! grep -q 'conf\.d/\*\.conf\|conf\.d/pdns-admin' /etc/nginx/nginx.conf 2>/dev/null; then
    awk -v conf="$NGINX_CONF" '
        /include.*mime\.types/ { print; print "    include " conf ";"; next }
        { print }
    ' /etc/nginx/nginx.conf > /tmp/nginx.conf.tmp && mv /tmp/nginx.conf.tmp /etc/nginx/nginx.conf
fi

systemctl enable nginx
nginx -t 2>/dev/null && systemctl reload nginx || systemctl start nginx
ok "nginx configured — Admin UI on port ${ADMIN_PORT}"

# ── 6. Firewall ───────────────────────────────────────────────────────────────

hdr "Firewall"

if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns  &>/dev/null
    firewall-cmd --permanent --add-port=8081/tcp &>/dev/null
    firewall-cmd --permanent --add-port="${ADMIN_PORT}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    ok "Firewall: ports 53, 8081, ${ADMIN_PORT} opened"
else
    warn "No firewall-cmd found — ensure ports 53 (UDP+TCP), 8081, ${ADMIN_PORT} are reachable"
fi

# ── 7. First-run admin account ────────────────────────────────────────────────

hdr "First-run admin account"

echo ""
echo -e "  ${CYAN}Signup is currently ENABLED.${NC}"
echo -e "  Open the Admin UI and create your admin account:"
echo ""
echo -e "  ${BOLD}http://${SERVER_IP}:${ADMIN_PORT}${NC}"
echo ""
echo -e "  ${YELLOW}Press Enter here once you have created your account...${NC}"
read -r

# Disable signup
sed -i "s/^SIGNUP_ENABLED = True/SIGNUP_ENABLED = False/" \
    "$INSTALL_DIR/powerdnsadmin/default_config.py"

systemctl restart pdns-admin
ok "Signup disabled — only existing accounts can log in"

# ── 8. Summary ────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  PowerDNS Server Ready${NC} (${MODE})"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Server IP:${NC}       ${SERVER_IP}"
echo -e "  ${CYAN}Mode:${NC}            ${MODE}"
echo -e "  ${CYAN}Admin UI:${NC}        http://${SERVER_IP}:${ADMIN_PORT}"
echo -e "  ${CYAN}PowerDNS API:${NC}    http://${SERVER_IP}:8081/api/v1/servers/localhost"
echo -e "  ${CYAN}API Key:${NC}         ${API_KEY}"
echo -e "  ${CYAN}DB:${NC}              MariaDB — database: ${DB_NAME}, user: ${DB_USER}"
echo -e "  ${CYAN}DB Password:${NC}     ${DB_PASS}"
echo ""

if [[ "$MODE" == "primary" ]]; then
    echo -e "  ${YELLOW}Panel setup:${NC}"
    echo -e "    In panel admin → Settings → PowerDNS:"
    echo -e "    • Enable PowerDNS: Yes"
    echo -e "    • API Key: ${API_KEY}"
    echo -e "    • API URL: http://${SERVER_IP}:8081/api/v1/servers/localhost"
    echo ""
    if [[ ${#SECONDARY_IPS[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}Secondaries configured:${NC} ${SECONDARY_IPS[*]}"
        echo -e "    Zones will notify these IPs automatically."
    else
        echo -e "  ${YELLOW}No secondaries configured.${NC}"
        echo -e "    To add one later, edit ${PDNS_CONF} and add:"
        echo -e "    also-notify=<secondary-ip>"
        echo -e "    allow-axfr-ips=<secondary-ip>"
        echo -e "    Then: systemctl restart pdns"
    fi
fi

if [[ "$MODE" == "secondary" ]]; then
    echo -e "  ${YELLOW}Primary server:${NC} ${PRIMARY_IP}"
    echo -e "    This server receives zone transfers automatically."
    echo ""
    echo -e "  ${YELLOW}On the primary server, add to ${PDNS_CONF}:${NC}"
    echo -e "    also-notify=${SERVER_IP}"
    echo -e "    allow-axfr-ips=${SERVER_IP}  (or append ,${SERVER_IP})"
    echo -e "    Then: systemctl restart pdns"
    echo -e "    Then: pdns_control notify-host all ${SERVER_IP}"
fi

echo ""
echo -e "  ${YELLOW}If this server fails and you replace it:${NC}"
echo -e "    Run:  bash install-pdns-server.sh --mode ${MODE} \\"
if [[ "$MODE" == "secondary" ]]; then
    echo -e "              --primary-ip ${PRIMARY_IP} \\"
fi
echo -e "              --api-key ${API_KEY} \\"
echo -e "              --db-pass ${DB_PASS}"
echo ""
echo -e "  ${CYAN}Logs:${NC}"
echo -e "    PowerDNS:   journalctl -u pdns -f"
echo -e "    Admin UI:   tail -f ${INSTALL_DIR}/data/error.log"
echo -e "    nginx:      tail -f /var/log/nginx/error.log"
echo ""
