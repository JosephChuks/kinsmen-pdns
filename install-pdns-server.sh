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
NGINX_CONF="/etc/nginx/nginx.conf"
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

# ── 5. Nginx (DNS proxy + KP Shield + Admin UI) ───────────────────────────────

hdr "Nginx"

# njs module (KP Shield)
dnf install -y -q nginx-module-njs 2>/dev/null || \
    dnf install -y -q nginx-mod-http-js 2>/dev/null || \
    warn "nginx njs module not found — KP Shield will be inactive (install nginx-module-njs manually)"

# Generate shield HMAC secret
if [[ ! -f /etc/nginx/kp_shield_secret ]]; then
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 > /etc/nginx/kp_shield_secret
    chmod 600 /etc/nginx/kp_shield_secret
fi

# Main nginx config — DNS proxy (port 80/443) + KP Shield + Admin UI (port 9191)
cat > /etc/nginx/nginx.conf << 'NGINXEOF'
load_module modules/ngx_http_js_module.so;

user  nginx;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    map_hash_max_size   8192;
    map_hash_bucket_size 128;

    js_import kp_shield from /etc/nginx/kp_shield.js;

    map $host $backend_80 {
        include /etc/nginx/proxy_http_map.conf;
        default "";
    }

    map $host $kp_shield_status {
        include /etc/nginx/kp_shield_map.conf;
    }

    server {
        listen 80 default_server;
        server_name _;

        error_page 502 503 504 /kp-down.html;

        location = /kp-down.html {
            root /var/www/kp-dns-error;
            internal;
            add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        }

        # Shield verify endpoint (must be before the main proxy location)
        location = /.kp-verify {
            client_body_in_single_buffer on;
            client_max_body_size 4k;
            js_content kp_shield.verify;
        }

        # Internal auth-request check location
        location = /_kp-check {
            internal;
            js_content kp_shield.check;
        }

        location / {
            if ($backend_80 = "") {
                return 503;
            }

            # Capture URI before auth_request subrequest changes $uri
            set $kp_req_uri $request_uri;

            auth_request      /_kp-check;
            error_page 401  = @kp_challenge;
            error_page 502 503 504 /kp-down.html;

            proxy_pass         http://$backend_80;
            proxy_http_version 1.1;
            proxy_set_header   Connection        "";
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_connect_timeout 15s;
            proxy_read_timeout    60s;
            proxy_send_timeout    30s;
        }

        # Named location served when auth_request returns 401
        location @kp_challenge {
            js_content kp_shield.challenge;
        }
    }

    # PowerDNS Admin UI
    server {
        listen 9191;
        server_name _;
        client_max_body_size 10m;

        location / {
            proxy_pass         http://127.0.0.1:GUNICORN_PORT_PLACEHOLDER;
            proxy_set_header   Host $host;
            proxy_set_header   X-Real-IP $remote_addr;
            proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout 120s;
        }
    }
}

stream {
    map_hash_max_size   8192;
    map_hash_bucket_size 128;

    map $ssl_preread_server_name $backend_443 {
        include /etc/nginx/proxy_stream_map.conf;
        default "";
    }

    server {
        listen 443;
        proxy_pass $backend_443;
        ssl_preread on;
        proxy_protocol on;
        proxy_connect_timeout 15s;
        proxy_timeout 600s;
    }
}
NGINXEOF

# Substitute the actual gunicorn port (can't use variables inside 'EOF' heredoc)
sed -i "s/GUNICORN_PORT_PLACEHOLDER/${GUNICORN_PORT}/" /etc/nginx/nginx.conf

# KP Shield njs module
cat > /etc/nginx/kp_shield.js << 'JSEOF'
/**
 * kp_shield.js — KP Bot Shield via nginx njs
 *
 * check(r)     — auth_request handler: 204 = allow, 401 = challenge needed
 * challenge(r) — serve the PoW HTML challenge page (on 401)
 * verify(r)    — handle POST solution, set cookie, redirect
 *
 * Map $host $kp_shield_status value format:  "difficulty:N"
 * Cookie __kp_shield = <ts>.<hmac-sha256(secret, host:ts)>  — valid 24 h
 */

import crypto from 'crypto';
import fs     from 'fs';

var _secret = null;
function getSecret() {
    if (!_secret) {
        try {
            _secret = fs.readFileSync('/etc/nginx/kp_shield_secret', 'utf8').trim();
        } catch (e) {
            _secret = 'kp-shield-fallback-change-me';
        }
    }
    return _secret;
}

var COOKIE_NAME   = '__kp_shield';
var COOKIE_TTL    = 86400;   // 24 h
var CHALLENGE_TTL = 300;     // 5 min

function hmac(host, ts) {
    return crypto.createHmac('sha256', getSecret())
                 .update(host + ':' + ts)
                 .digest('hex');
}

function getCookieValue(r) {
    var raw = r.headersIn.cookie || '';
    var re  = new RegExp('(?:^|;\\s*)' + COOKIE_NAME + '=([^;]+)');
    var m   = raw.match(re);
    return m ? decodeURIComponent(m[1]) : null;
}

function validateCookie(r, host) {
    var val = getCookieValue(r);
    if (!val) return false;
    var dot = val.indexOf('.');
    if (dot < 1) return false;
    var ts  = val.slice(0, dot);
    var sig = val.slice(dot + 1);
    var now = Math.floor(Date.now() / 1000);
    if (now - parseInt(ts, 10) > COOKIE_TTL) return false;
    return sig === hmac(host, ts);
}

function issueCookie(r, host) {
    var ts  = String(Math.floor(Date.now() / 1000));
    var sig = hmac(host, ts);
    var val = ts + '.' + sig;
    var exp = new Date(Date.now() + COOKIE_TTL * 1000).toUTCString();
    r.headersOut['Set-Cookie'] =
        COOKIE_NAME + '=' + encodeURIComponent(val) +
        '; Path=/; Expires=' + exp +
        '; HttpOnly; SameSite=Lax';
}

function canonicalHost(r) {
    return (r.headersIn.host || '').toLowerCase().replace(/:\d+$/, '');
}

function parseDifficulty(status) {
    var m = (status || '').match(/difficulty:(\d+)/);
    return m ? parseInt(m[1], 10) : 4;
}

// Returns null = whole site, or array of path prefixes to protect
function parsePaths(status) {
    var pipe = (status || '').indexOf('|');
    if (pipe < 0) return null;
    var parts = status.slice(pipe + 1).split('|');
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i].trim();
        if (p) out.push(p);
    }
    return out.length ? out : null;
}

// Strip query string from a URI
function uriPath(uri) {
    var q = uri.indexOf('?');
    return q >= 0 ? uri.slice(0, q) : uri;
}

function parseQuery(str) {
    var out = {};
    var pairs = (str || '').split('&');
    for (var i = 0; i < pairs.length; i++) {
        var pair = pairs[i];
        var eq = pair.indexOf('=');
        if (eq > 0) {
            try {
                var k = decodeURIComponent(pair.slice(0, eq));
                var v = decodeURIComponent(pair.slice(eq + 1).replace(/\+/g, ' '));
                out[k] = v;
            } catch (_) {}
        }
    }
    return out;
}

// ── check — auth_request handler ──────────────────────────────────────────────

function check(r) {
    var status = r.variables.kp_shield_status || '';
    if (!status) { r.return(204); return; }

    // Path-based protection: only block matching paths
    var paths = parsePaths(status);
    if (paths !== null) {
        // $kp_req_uri is set in location / before auth_request fires
        var reqPath = uriPath(r.variables.kp_req_uri || r.variables.request_uri || '/');
        var matched = false;
        for (var i = 0; i < paths.length; i++) {
            if (reqPath === paths[i] || reqPath.indexOf(paths[i] + '/') === 0) {
                matched = true;
                break;
            }
        }
        if (!matched) { r.return(204); return; }
    }

    var host = canonicalHost(r);
    if (validateCookie(r, host)) { r.return(204); return; }
    r.return(401);
}

// ── challenge — serve PoW HTML ────────────────────────────────────────────────

function challenge(r) {
    var host       = canonicalHost(r);
    var status     = r.variables.kp_shield_status || 'difficulty:4';
    var difficulty = parseDifficulty(status);
    // nginx generates a cryptographically random $request_id per-request
    var seed = crypto.createHash('sha256').update(
        (r.variables.request_id || '') + String(Date.now())
    ).digest('hex').slice(0, 32);
    var ts         = String(Math.floor(Date.now() / 1000));
    var token      = crypto.createHash('sha256').update(seed + ts).digest('hex');
    var returnTo   = encodeURIComponent(r.variables.request_uri || '/');

    r.headersOut['Content-Type']  = 'text/html; charset=utf-8';
    r.headersOut['Cache-Control'] = 'no-store';
    r.headersOut['X-Robots-Tag']  = 'noindex';
    r.return(200, buildPage(token, ts, seed, difficulty, returnTo, host));
}

// ── verify — handle PoW POST ──────────────────────────────────────────────────

function verify(r) {
    if (r.method !== 'POST') { r.return(405); return; }

    var body  = parseQuery(r.requestText || '');
    var token = body.token  || '';
    var ts    = body.ts     || '';
    var seed  = body.seed   || '';
    var nonce = body.nonce  || '';
    var ret   = body['return'] || '/';

    var now = Math.floor(Date.now() / 1000);
    if (Math.abs(now - parseInt(ts, 10)) > CHALLENGE_TTL) {
        r.return(400, 'Challenge expired — please reload.');
        return;
    }

    var expected = crypto.createHash('sha256').update(seed + ts).digest('hex');
    if (token !== expected) {
        r.return(400, 'Invalid challenge token.');
        return;
    }

    var status     = r.variables.kp_shield_status || 'difficulty:4';
    var difficulty = parseDifficulty(status);
    var prefix     = '';
    for (var i = 0; i < difficulty; i++) prefix += '0';

    var pow = crypto.createHash('sha256').update(token + '.' + nonce).digest('hex');
    if (pow.slice(0, difficulty) !== prefix) {
        r.return(400, 'Proof-of-work failed.');
        return;
    }

    var host = canonicalHost(r);
    issueCookie(r, host);
    r.headersOut['Location'] = ret.charAt(0) === '/' ? ret : '/';
    r.return(302);
}

// ── HTML page ─────────────────────────────────────────────────────────────────

function buildPage(token, ts, seed, difficulty, returnTo, host) {
    var tokenJSON = JSON.stringify(token);
    return '<!DOCTYPE html>\n' +
'<html lang="en"><head>\n' +
'<meta charset="utf-8">\n' +
'<meta name="viewport" content="width=device-width,initial-scale=1">\n' +
'<title>Security Check</title>\n' +
'<style>\n' +
'*{box-sizing:border-box;margin:0;padding:0}\n' +
'body{font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif;\n' +
'     background:#0f172a;color:#e2e8f0;min-height:100vh;\n' +
'     display:flex;align-items:center;justify-content:center}\n' +
'.card{background:#1e293b;border:1px solid #334155;border-radius:16px;\n' +
'      padding:40px 48px;max-width:420px;width:90%;text-align:center;\n' +
'      box-shadow:0 25px 50px rgba(0,0,0,.5)}\n' +
'.logo{font-size:42px;margin-bottom:16px}\n' +
'h1{font-size:20px;font-weight:600;margin-bottom:8px;color:#f1f5f9}\n' +
'p{font-size:14px;color:#94a3b8;margin-bottom:28px;line-height:1.5}\n' +
'.spinner{width:48px;height:48px;border:4px solid #334155;\n' +
'         border-top-color:#6366f1;border-radius:50%;\n' +
'         animation:spin 0.8s linear infinite;margin:0 auto 20px}\n' +
'@keyframes spin{to{transform:rotate(360deg)}}\n' +
'.bar-wrap{background:#334155;border-radius:8px;height:6px;margin-bottom:16px;overflow:hidden}\n' +
'.bar{height:100%;background:linear-gradient(90deg,#6366f1,#8b5cf6);\n' +
'     border-radius:8px;width:0%;transition:width .3s ease}\n' +
'.status{font-size:13px;color:#64748b;min-height:20px}\n' +
'.host{font-size:12px;color:#475569;margin-top:24px;\n' +
'      padding-top:16px;border-top:1px solid #334155}\n' +
'.done{display:none}\n' +
'.done .ck{font-size:48px;margin-bottom:12px}\n' +
'.done h2{font-size:18px;font-weight:600;color:#4ade80}\n' +
'</style></head><body>\n' +
'<div class="card">\n' +
'  <div class="logo">\u{1f6e1}️</div>\n' +
'  <h1>Security Check</h1>\n' +
'  <p>Verifying your browser.<br>This only takes a moment.</p>\n' +
'  <div id="checking">\n' +
'    <div class="spinner"></div>\n' +
'    <div class="bar-wrap"><div class="bar" id="bar"></div></div>\n' +
'    <div class="status" id="st">Initializing…</div>\n' +
'  </div>\n' +
'  <div class="done" id="done">\n' +
'    <div class="ck">✅</div>\n' +
'    <h2>Verified!</h2>\n' +
'    <p style="color:#94a3b8;margin-top:8px">Redirecting…</p>\n' +
'  </div>\n' +
'  <div class="host">' + host + '</div>\n' +
'  <form id="f" method="POST" action="/.kp-verify" style="display:none">\n' +
'    <input name="token"  value="' + token + '">\n' +
'    <input name="ts"     value="' + ts + '">\n' +
'    <input name="seed"   value="' + seed + '">\n' +
'    <input name="nonce"  id="nc" value="">\n' +
'    <input name="return" value="' + decodeURIComponent(returnTo) + '">\n' +
'  </form>\n' +
'</div>\n' +
'<script>\n' +
'(async()=>{\n' +
'  var token=' + tokenJSON + ';\n' +
'  var diff=' + difficulty + ';\n' +
'  var pfx="0".repeat(diff);\n' +
'  var bar=document.getElementById("bar");\n' +
'  var st=document.getElementById("st");\n' +
'  async function sha256(s){\n' +
'    var b=new TextEncoder().encode(s);\n' +
'    var h=await crypto.subtle.digest("SHA-256",b);\n' +
'    return Array.from(new Uint8Array(h)).map(x=>x.toString(16).padStart(2,"0")).join("");\n' +
'  }\n' +
'  st.textContent="Solving…";\n' +
'  var n=0,avg=Math.pow(16,diff),start=Date.now();\n' +
'  while(true){\n' +
'    var h=await sha256(token+"."+n);\n' +
'    if(h.startsWith(pfx))break;\n' +
'    n++;\n' +
'    var pct=Math.min(99,Math.round(n/avg*100));\n' +
'    bar.style.width=pct+"%";\n' +
'    if(n%500===0){\n' +
'      var el=((Date.now()-start)/1000).toFixed(1);\n' +
'      st.textContent="Working… ("+n.toLocaleString()+" attempts, "+el+"s)";\n' +
'      await new Promise(r=>setTimeout(r,0));\n' +
'    }\n' +
'  }\n' +
'  bar.style.width="100%";\n' +
'  st.textContent="Done in "+n.toLocaleString()+" attempts!";\n' +
'  document.getElementById("nc").value=n;\n' +
'  document.getElementById("checking").style.display="none";\n' +
'  document.getElementById("done").style.display="block";\n' +
'  setTimeout(()=>document.getElementById("f").submit(),400);\n' +
'})();\n' +
'</script></body></html>';
}

export default { check: check, challenge: challenge, verify: verify };
JSEOF

# KP Shield domain map (populated by panel's kp-update-shield-map)
cat > /etc/nginx/kp_shield_map.conf << 'EOF'
# kp_shield_map.conf — auto-generated by kp-update-shield-map.sh
# DO NOT EDIT MANUALLY — changes will be overwritten
# Map $host => shield config string ("difficulty:N") or "" for no shield
default "";
EOF

# Proxy maps — populated every minute by kp-update-proxy-map cron
printf '# proxy_http_map.conf — auto-generated by kp-update-proxy-map\n' \
    > /etc/nginx/proxy_http_map.conf
printf '# proxy_stream_map.conf — auto-generated by kp-update-proxy-map\n' \
    > /etc/nginx/proxy_stream_map.conf

# API config for the proxy map cron script
cat > /etc/nginx/kp_pdns_api.conf << EOF
api_url=http://127.0.0.1:8081/api/v1/servers/localhost
api_key=${API_KEY}
EOF
chmod 640 /etc/nginx/kp_pdns_api.conf
ok "kp_pdns_api.conf written"

# Custom error page (shown when origin is unreachable)
mkdir -p /var/www/kp-dns-error
cat > /var/www/kp-dns-error/kp-down.html << 'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Site Temporarily Unavailable</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%}
body{
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
  background:#0d1117;
  color:#c9d1d9;
  display:flex;
  flex-direction:column;
  align-items:center;
  justify-content:center;
  min-height:100vh;
  padding:2rem;
}
.card{
  width:100%;
  max-width:520px;
  text-align:center;
}
.icon{
  width:64px;height:64px;
  margin:0 auto 1.5rem;
  border-radius:50%;
  background:#161b22;
  border:2px solid #30363d;
  display:flex;align-items:center;justify-content:center;
  font-size:1.8rem;
}
.code{
  font-size:4rem;
  font-weight:700;
  color:#f0883e;
  letter-spacing:-2px;
  line-height:1;
  margin-bottom:.5rem;
}
h1{
  font-size:1.25rem;
  font-weight:600;
  color:#e6edf3;
  margin-bottom:.75rem;
}
.desc{
  font-size:.9rem;
  color:#8b949e;
  line-height:1.65;
  margin-bottom:2rem;
}
.domain{
  display:inline-block;
  background:#161b22;
  border:1px solid #30363d;
  border-radius:6px;
  padding:.25rem .75rem;
  font-size:.8rem;
  font-family:'SF Mono',Consolas,'Liberation Mono',Menlo,monospace;
  color:#79c0ff;
  margin-bottom:2rem;
  max-width:100%;
  overflow:hidden;
  text-overflow:ellipsis;
  white-space:nowrap;
}
.details{
  display:flex;
  gap:1rem;
  justify-content:center;
  flex-wrap:wrap;
  margin-bottom:2.5rem;
}
.detail-item{
  background:#161b22;
  border:1px solid #30363d;
  border-radius:8px;
  padding:.6rem 1rem;
  font-size:.78rem;
  color:#8b949e;
  text-align:left;
  min-width:130px;
}
.detail-item strong{
  display:block;
  color:#c9d1d9;
  font-size:.7rem;
  text-transform:uppercase;
  letter-spacing:.05em;
  margin-bottom:.2rem;
}
.retry-btn{
  display:inline-block;
  padding:.6rem 1.5rem;
  background:#238636;
  color:#fff;
  border:none;
  border-radius:6px;
  font-size:.875rem;
  font-weight:500;
  cursor:pointer;
  text-decoration:none;
  transition:background .2s;
}
.retry-btn:hover{background:#2ea043}
footer{
  position:fixed;
  bottom:1.25rem;
  font-size:.75rem;
  color:#484f58;
}
footer a{color:#484f58;text-decoration:none}
footer a:hover{color:#8b949e}
</style>
</head>
<body>
<div class="card">
  <div class="icon">&#x26A0;</div>
  <div class="code" id="errcode">502</div>
  <h1>This website is temporarily unavailable</h1>
  <p class="desc">
    The origin server did not respond in time.<br>
    This is usually a temporary issue — please try again shortly.
  </p>
  <div class="domain" id="domain-label">loading&hellip;</div>
  <div class="details">
    <div class="detail-item">
      <strong>Error</strong>
      <span id="err-text">Bad Gateway</span>
    </div>
    <div class="detail-item">
      <strong>Time</strong>
      <span id="ts">—</span>
    </div>
    <div class="detail-item">
      <strong>Ray</strong>
      <span id="ray">—</span>
    </div>
  </div>
  <a href="javascript:location.reload()" class="retry-btn">Try again</a>
</div>
<footer>Performance &amp; security by <a href="https://kinsmenwebpanel.com" target="_blank">Kinsmen Web Panel</a></footer>

<script>
(function(){
  var host = location.hostname || 'unknown host';
  document.getElementById('domain-label').textContent = host;
  document.getElementById('ts').textContent = new Date().toUTCString().replace('GMT','UTC');

  // Ray ID: short fingerprint of host + timestamp
  var ray = (Date.now() ^ (host.split('').reduce(function(a,c){return (a<<5)-a+c.charCodeAt(0)|0},0))).toString(36).toUpperCase().slice(-8);
  document.getElementById('ray').textContent = ray;
})();
</script>
</body>
</html>
HTMLEOF
ok "Error page installed at /var/www/kp-dns-error/kp-down.html"

# Proxy map updater (runs every minute via cron)
cat > /usr/local/sbin/kp-update-proxy-map << 'PYEOF'
#!/usr/bin/env python3
"""
kp-update-proxy-map — Rebuild nginx proxy_http_map.conf and proxy_stream_map.conf
from _kp-origin.* TXT records in local PowerDNS.

Runs every minute via cron on dns1 and dns2.
TXT record format:  _kp-origin.<domain>  →  "origin_ip"

HTTP map  → domain maps to bare IP  (nginx uses :80 by default)
Stream map → domain maps to IP:10443 (origin nginx PROXY-protocol HTTPS port)
"""
import json, os, re, subprocess, sys, urllib.request, urllib.parse
from datetime import datetime

HTTP_MAP    = '/etc/nginx/proxy_http_map.conf'
STREAM_MAP  = '/etc/nginx/proxy_stream_map.conf'
PDNS_CONF   = '/etc/nginx/kp_pdns_api.conf'
LOG         = '/var/log/kp-proxy-map.log'


def read_conf(path):
    cfg = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                k, _, v = line.partition('=')
                cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return cfg


def pdns_get(url_base, key, path):
    url = url_base.rstrip('/') + path
    req = urllib.request.Request(url, headers={'X-API-Key': key, 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r) if r.status == 200 else None
    except Exception:
        return None


def write_if_changed(path, entries, label):
    ts   = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')
    body = f'# {label} — auto-generated {ts}\n# DO NOT EDIT MANUALLY\n'
    for host, val in sorted(entries.items()):
        body += f'  {host} {val};\n'

    norm = lambda s: re.sub(r'auto-generated [^\n]+\n', '', s)
    try:
        existing = open(path).read()
    except FileNotFoundError:
        existing = ''

    if norm(body) == norm(existing):
        return False

    with open(path, 'w') as f:
        f.write(body)
    return True


def log(msg):
    ts = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG, 'a') as f:
            f.write(f'[{ts}] {msg}\n')
    except Exception:
        pass


def main():
    if not os.path.exists(PDNS_CONF):
        sys.exit(0)

    cfg     = read_conf(PDNS_CONF)
    api_url = cfg.get('api_url', '').rstrip('/')
    api_key = cfg.get('api_key', '')
    if not api_url or not api_key:
        sys.exit(0)

    zones = pdns_get(api_url, api_key, '/zones')
    if not isinstance(zones, list):
        sys.exit(0)

    http_map   = {}
    stream_map = {}

    for zone in zones:
        zone_id   = zone.get('id', '')
        zone_name = zone.get('name', '').rstrip('.')
        if not zone_id or not zone_name:
            continue

        detail = pdns_get(
            api_url, api_key,
            f'/zones/{urllib.parse.quote(zone_id, safe="")}?rrsets=true'
        )
        if not isinstance(detail, dict):
            continue

        rrsets = detail.get('rrsets', [])

        # Find _kp-origin.<zone> TXT → origin IP
        origin_ip = None
        for rr in rrsets:
            if rr.get('type') != 'TXT':
                continue
            name = rr.get('name', '')
            if not re.match(rf'^_kp-origin\.{re.escape(zone_name)}\.$', name):
                continue
            for rec in rr.get('records', []):
                v = rec.get('content', '').strip('"')
                if re.match(r'^\d{1,3}(?:\.\d{1,3}){3}$', v):
                    origin_ip = v
                    break
            if origin_ip:
                break

        if not origin_ip:
            continue

        # Zone apex + www
        for host in (zone_name, f'www.{zone_name}'):
            http_map[host]   = origin_ip
            stream_map[host] = f'{origin_ip}:10443'

        # Any A records in this zone that point to the same origin
        for rr in rrsets:
            if rr.get('type') != 'A':
                continue
            host = rr.get('name', '').rstrip('.')
            if host in (zone_name, f'www.{zone_name}'):
                continue
            for rec in rr.get('records', []):
                if rec.get('content', '') == origin_ip:
                    http_map[host]   = origin_ip
                    stream_map[host] = f'{origin_ip}:10443'
                    break

    if not http_map:
        sys.exit(0)

    h_changed = write_if_changed(HTTP_MAP,   http_map,   'proxy_http_map.conf')
    s_changed = write_if_changed(STREAM_MAP, stream_map, 'proxy_stream_map.conf')

    if h_changed or s_changed:
        r = subprocess.run(
            ['systemctl', 'reload', 'nginx'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if r.returncode != 0:
            log(f'nginx reload failed: {r.stderr.decode().strip()}')
        else:
            log(f'Maps updated: {len(http_map)} domains, nginx reloaded.')


main()
PYEOF
chmod +x /usr/local/sbin/kp-update-proxy-map
ok "kp-update-proxy-map installed"

# Cron: refresh proxy maps every minute
(crontab -l 2>/dev/null | grep -v kp-update-proxy-map; \
 echo "* * * * * /usr/local/sbin/kp-update-proxy-map >> /var/log/kp-proxy-map.log 2>&1") | crontab -
ok "Proxy map cron installed (every minute)"

systemctl enable nginx
nginx -t && systemctl reload nginx 2>/dev/null || systemctl start nginx
ok "nginx configured — proxy on 80/443, Admin UI on port ${ADMIN_PORT}"

# ── 6. Firewall ───────────────────────────────────────────────────────────────

hdr "Firewall"

if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=dns  &>/dev/null
    firewall-cmd --permanent --add-service=http &>/dev/null
    firewall-cmd --permanent --add-service=https &>/dev/null
    firewall-cmd --permanent --add-port=8081/tcp &>/dev/null
    firewall-cmd --permanent --add-port="${ADMIN_PORT}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    ok "Firewall: ports 53, 80, 443, 8081, ${ADMIN_PORT} opened"
else
    warn "No firewall-cmd found — ensure ports 53 (UDP+TCP), 80, 443, 8081, ${ADMIN_PORT} are reachable"
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
