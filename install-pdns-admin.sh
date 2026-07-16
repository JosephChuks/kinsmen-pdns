#!/bin/bash
# setup-pdns-admin.sh — Install PowerDNS-Admin web UI on a PowerDNS server
#
# Installs PowerDNS-Admin (https://github.com/PowerDNS-Admin/PowerDNS-Admin)
# as a systemd service behind nginx on port 9191.
#
# Usage:
#   bash setup-pdns-admin.sh                  # install / upgrade
#   bash setup-pdns-admin.sh --uninstall      # remove
#
# Tested on AlmaLinux 8/9 (RHEL-compatible).
# Assumes PowerDNS authoritative server is already running locally.

set -euo pipefail

INSTALL_DIR="/opt/pdns-admin"
SERVICE_USER="pdnsadmin"
SERVICE_FILE="/etc/systemd/system/pdns-admin.service"
APP_PORT=9191       # external port (nginx listens here)
GUNICORN_PORT=9292  # internal port (gunicorn binds here, avoids self-proxy loop)
NGINX_CONF="/etc/nginx/conf.d/pdns-admin.conf"
SECRET_FILE="/etc/pdns-admin.secret"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

# ── Uninstall ─────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
    info "Removing pdns-admin..."
    systemctl stop pdns-admin 2>/dev/null || true
    systemctl disable pdns-admin 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$NGINX_CONF" "$SECRET_FILE"
    rm -rf "$INSTALL_DIR"
    userdel "$SERVICE_USER" 2>/dev/null || true
    systemctl daemon-reload
    nginx -s reload 2>/dev/null || true
    ok "pdns-admin removed"
    exit 0
fi

# ── Preflight ─────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root"
command -v pdns_server >/dev/null 2>&1 || die "PowerDNS not found — install it first"

PDNS_API_KEY=$(grep '^api-key' /etc/pdns/pdns.conf 2>/dev/null | cut -d= -f2 | tr -d ' ') || true
PDNS_API_URL="http://localhost:8081/api/v1"

[[ -n "$PDNS_API_KEY" ]] || die "api-key not set in /etc/pdns/pdns.conf"

# Verify API is reachable
if ! curl -sf -H "X-API-Key: $PDNS_API_KEY" "$PDNS_API_URL/servers/localhost" >/dev/null; then
    die "PowerDNS API not reachable at $PDNS_API_URL — is PowerDNS running with api=yes and webserver=yes?"
fi

ok "PowerDNS API reachable"

# ── System dependencies ───────────────────────────────────────────────────────

info "Installing system dependencies..."
# Prefer python3.9 (available on EL8 via appstream); python3 on EL8 is 3.6 which
# is too old for PowerDNS-Admin and has a pip that lacks required features.
dnf install -y -q python39 python39-devel python39-pip 2>/dev/null || true

# Node 18+ required by PowerDNS-Admin's frontend deps (fs-extra requires >=12,
# default EL8 stream is Node 10). Switch module stream before installing.
NODE_VER=$(node --version 2>/dev/null | grep -oP '\d+' | head -1)
if [[ -z "$NODE_VER" || "$NODE_VER" -lt 18 ]]; then
    info "Upgrading Node.js to 18 (current: ${NODE_VER:-none})..."
    dnf module reset nodejs -y -q 2>/dev/null || true
    dnf module enable nodejs:18 -y -q 2>/dev/null || true
fi

dnf install -y -q \
    gcc gcc-c++ make \
    openssl-devel libffi-devel libxml2-devel libxslt-devel \
    openldap-devel cyrus-sasl-devel \
    sqlite sqlite-devel \
    git curl \
    nodejs npm 2>/dev/null || \
dnf install -y -q \
    gcc gcc-c++ make \
    openssl-devel libffi-devel \
    sqlite git curl \
    nodejs npm

# yarn via npm
npm install -g yarn --quiet 2>/dev/null || true
ok "Dependencies installed (Node $(node --version 2>/dev/null))"

# ── Service user ──────────────────────────────────────────────────────────────

if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -s /sbin/nologin -d "$INSTALL_DIR" "$SERVICE_USER"
    ok "Created user $SERVICE_USER"
fi

# ── Clone / update repo ───────────────────────────────────────────────────────

if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating PowerDNS-Admin..."
    git -C "$INSTALL_DIR" pull -q
else
    info "Cloning PowerDNS-Admin..."
    git clone -q --depth 1 https://github.com/PowerDNS-Admin/PowerDNS-Admin.git "$INSTALL_DIR"
fi
ok "Source ready at $INSTALL_DIR"

# ── Python virtual environment ────────────────────────────────────────────────

info "Setting up Python environment..."
# Use python3.9 if available (EL8 ships python3=3.6 which is too old)
PYTHON_BIN=$(command -v python3.9 || command -v python3.8 || command -v python3)
info "Using $($PYTHON_BIN --version 2>&1)"
"$PYTHON_BIN" -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"

# Upgrade pip silently
pip install -q --upgrade pip setuptools wheel

# Strip pip option lines that old pip versions reject (e.g. --use-feature=no-binary-enable-wheel-cache)
# PowerDNS-Admin's requirements.txt may contain these; they're hints not hard requirements.
CLEANED_REQ=$(mktemp)
# Strip pip option lines (old pip rejects them) and mysqlclient (needs MySQL dev
# headers; we use SQLite so it's unused).
grep -v '^--' "$INSTALL_DIR/requirements.txt" \
    | grep -v '^mysqlclient' \
    | grep -v '^psycopg2' \
    > "$CLEANED_REQ" || cp "$INSTALL_DIR/requirements.txt" "$CLEANED_REQ"

# Install app dependencies
pip install -q -r "$CLEANED_REQ" || pip install -r "$CLEANED_REQ"
rm -f "$CLEANED_REQ"

ok "Python environment ready"

# ── Application config ────────────────────────────────────────────────────────

# Generate or reuse secret key
if [[ ! -f "$SECRET_FILE" ]]; then
    python3 -c "import secrets; print(secrets.token_hex(32))" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi
SECRET_KEY=$(cat "$SECRET_FILE")

cat > "$INSTALL_DIR/powerdnsadmin/default_config.py" << PYEOF
import os

# Flask
SECRET_KEY = '${SECRET_KEY}'
BIND_ADDRESS = '127.0.0.1'
PORT = ${APP_PORT}
LOGIN_TITLE = 'Kinsmen DNS Admin'

# SQLite database for app users/settings
SQLA_DB_USER = ''
SQLA_DB_PASSWORD = ''
SQLA_DB_HOST = ''
SQLA_DB_NAME = '${INSTALL_DIR}/data/pdns-admin.db'
SQLALCHEMY_DATABASE_URI = 'sqlite:///${INSTALL_DIR}/data/pdns-admin.db'
SQLALCHEMY_TRACK_MODIFICATIONS = True

# PowerDNS API
PDNS_STATS_URL = '${PDNS_API_URL}/'
PDNS_API_KEY = '${PDNS_API_KEY}'
PDNS_VERSION = '4.7.0'

# Features
SIGNUP_ENABLED = False
OFFLINE_MODE = False
RECORDS_ALLOW_EDIT = ['A', 'AAAA', 'CNAME', 'MX', 'NS', 'SOA', 'SRV', 'TXT', 'CAA', 'TLSA', 'SSHFP', 'LOC', 'NAPTR', 'ALIAS']

# Session — filesystem type required by flask_session_captcha to prevent replay attacks
SESSION_TYPE = 'filesystem'
SESSION_FILE_DIR = '${INSTALL_DIR}/data/flask_sessions'
SESSION_PERMANENT = False
SESSION_COOKIE_SAMESITE = 'Lax'

# Captcha (disable to avoid requiring Redis/Memcached)
CAPTCHA_ENABLE = False

# SAML (disabled — not used)
SAML_ENABLED = False
PYEOF

mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/data/flask_sessions"
ok "App configured"

# ── Build frontend assets ─────────────────────────────────────────────────────

info "Building frontend assets (this may take a minute)..."
cd "$INSTALL_DIR"
if command -v yarn &>/dev/null; then
    yarn install 2>&1 | tail -5
    yarn build 2>&1 | tail -10
else
    npm install 2>&1 | tail -5
    npm run build 2>&1 | tail -10
fi

# Verify critical asset exists — abort if build failed
if [[ ! -f "$INSTALL_DIR/powerdnsadmin/static/generated/main.js" ]] && \
   [[ ! -f "$INSTALL_DIR/powerdnsadmin/static/node_modules/@fortawesome/fontawesome-free/css/all.css" ]]; then
    warn "Frontend build may be incomplete — checking for any generated assets..."
    ls "$INSTALL_DIR/powerdnsadmin/static/generated/" 2>/dev/null || warn "No generated assets found — run 'cd $INSTALL_DIR && yarn build' manually"
else
    ok "Frontend assets built"
fi

# ── Database init ─────────────────────────────────────────────────────────────

info "Initialising database..."
export FLASK_APP=powerdnsadmin/__init__.py
"$INSTALL_DIR/venv/bin/flask" db upgrade 2>/dev/null || \
"$INSTALL_DIR/venv/bin/python3" -c "
from powerdnsadmin import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('DB created')
" 2>/dev/null || warn "DB init step had warnings — may need manual init on first login"

# Fix ownership
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
ok "Database ready"

# ── Systemd service ───────────────────────────────────────────────────────────

info "Installing systemd service..."
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

pip install -q gunicorn
systemctl daemon-reload
systemctl enable pdns-admin
systemctl restart pdns-admin
ok "Service started"

# ── Nginx reverse proxy ───────────────────────────────────────────────────────

info "Configuring nginx..."

# nginx listens on APP_PORT externally; gunicorn runs on GUNICORN_PORT internally.
# Using different ports avoids any self-proxy ambiguity.
cat > "$NGINX_CONF" << EOF
# PowerDNS Admin — available on port ${APP_PORT}
server {
    listen ${APP_PORT};
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

# If nginx.conf doesn't already include conf.d, add the include to the http block.
# Some setups (e.g., pure-proxy dns servers) omit the standard conf.d glob.
if ! grep -q 'conf\.d/\*\.conf\|conf\.d/pdns-admin' /etc/nginx/nginx.conf 2>/dev/null; then
    warn "nginx.conf does not include conf.d — adding explicit include"
    # Use awk to insert the include line after mime.types (sed \n is not portable)
    awk -v conf="$NGINX_CONF" '
        /include.*mime\.types/ { print; print "    include " conf ";"; next }
        { print }
    ' /etc/nginx/nginx.conf > /tmp/nginx.conf.tmp && mv /tmp/nginx.conf.tmp /etc/nginx/nginx.conf
fi

nginx -t 2>/dev/null && nginx -s reload && ok "nginx configured (port ${APP_PORT} → gunicorn :${GUNICORN_PORT})" \
    || warn "nginx reload failed — check /etc/nginx/nginx.conf manually"

# ── Firewall ──────────────────────────────────────────────────────────────────

if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=9191/tcp &>/dev/null && \
    firewall-cmd --reload &>/dev/null && ok "Firewall: port 9191 opened" || warn "Could not open firewall port 9191"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
ok "PowerDNS Admin installed successfully"
echo ""
echo -e "  ${CYAN}URL:${NC}     http://${SERVER_IP}:9191"
echo -e "  ${CYAN}Login:${NC}   First visit creates the admin account"
echo -e "  ${CYAN}API key${NC}  (from pdns.conf): ${PDNS_API_KEY:0:8}…"
echo ""
warn "Remember to restrict port 9191 to trusted IPs only (e.g. your office/VPN IP)"
echo -e "  ${CYAN}Example:${NC} firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=YOUR_IP port port=9191 protocol=tcp accept'"
echo ""
