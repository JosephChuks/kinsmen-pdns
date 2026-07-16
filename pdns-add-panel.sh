#!/bin/bash
# pdns-add-panel.sh — Add a new panel server to the PowerDNS API allowlist
#
# Run from your desktop when you add a new panel server to your fleet.
# Updates webserver-allow-from on every DNS server you specify, then
# prints the API key and URL ready to paste into the new panel's settings.
#
# Usage:
#   bash pdns-add-panel.sh --new-panel-ip <IP> <dns-host> [<dns-host> ...]
#
# Example (adding srv11 to both dns servers):
#   bash pdns-add-panel.sh --new-panel-ip 103.x.x.x dns1 dns2

set -euo pipefail

NEW_PANEL_IP=""
DNS_HOSTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new-panel-ip) NEW_PANEL_IP="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^#/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  DNS_HOSTS+=("$1"); shift ;;
    esac
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

[[ -n "$NEW_PANEL_IP" ]] || die "--new-panel-ip required"
[[ ${#DNS_HOSTS[@]} -gt 0 ]] || die "At least one DNS host required (e.g. dns1 dns2)"

echo ""
echo -e "${BOLD}Adding panel IP ${NEW_PANEL_IP} to PowerDNS API allowlist${NC}"
echo ""

API_KEY=""
API_URL=""

for HOST in "${DNS_HOSTS[@]}"; do
    info "Updating $HOST..."

    ssh "$HOST" "
        CONF=/etc/pdns/pdns.conf

        # Read current webserver-allow-from
        CURRENT=\$(grep '^webserver-allow-from=' \"\$CONF\" 2>/dev/null | cut -d= -f2 || echo '127.0.0.1')

        # Add new IP (deduplicated)
        NEW=\$(echo \"\$CURRENT,${NEW_PANEL_IP}\" | tr ',' '\n' \
            | grep -v '^\$' \
            | sort -u \
            | tr '\n' ',' \
            | sed 's/,\$//')

        if grep -q '^webserver-allow-from=' \"\$CONF\"; then
            sed -i \"s|^webserver-allow-from=.*|webserver-allow-from=\${NEW}|\" \"\$CONF\"
        else
            echo \"webserver-allow-from=\${NEW}\" >> \"\$CONF\"
        fi

        systemctl restart pdns
        echo \"  webserver-allow-from=\${NEW}\"
    "

    ok "$HOST updated"

    # Grab API key and server IP from the first host that responds
    if [[ -z "$API_KEY" ]]; then
        API_KEY=$(ssh "$HOST" "grep '^api-key' /etc/pdns/pdns.conf | cut -d= -f2 | tr -d ' '")
        HOST_IP=$(ssh "$HOST" "hostname -I | awk '{print \$1}'")
        API_URL="http://${HOST_IP}:8081/api/v1/servers/localhost"
    fi
done

echo ""
echo -e "${BOLD}${GREEN}Done.${NC} Add these to the new panel server's settings:${NC}"
echo ""
echo -e "  ${YELLOW}Admin → Settings → PowerDNS${NC}"
echo -e "  ${CYAN}API URL:${NC}  ${API_URL}"
echo -e "  ${CYAN}API Key:${NC}  ${API_KEY}"
echo ""
