#!/bin/bash
# pdns-failover.sh — PowerDNS server failover toolkit (run from your desktop/srv5)
#
# ── Scenarios ─────────────────────────────────────────────────────────────────
#
#   SECONDARY fails → replace it:
#     bash pdns-failover.sh replace-secondary \
#         --primary dns1 \
#         --old-ip 46.183.27.159 \
#         --new-ip 5.5.5.5
#
#   PRIMARY fails → promote surviving secondary, then add new secondary:
#     Step 1 — promote dns2 to become the new primary:
#       bash pdns-failover.sh promote-to-primary --server dns2
#
#     Step 2 — add a new secondary to the promoted primary:
#       bash pdns-failover.sh add-secondary --primary dns2 --new-ip 5.5.5.5
#
#   ADD a secondary to an existing primary (no failure, just expanding):
#     bash pdns-failover.sh add-secondary --primary dns1 --new-ip 5.5.5.5
#
# ── What each command does ────────────────────────────────────────────────────
#
#   replace-secondary
#     1. Removes old secondary IP from primary's also-notify + allow-axfr-ips
#     2. Adds new secondary IP
#     3. Restarts pdns on primary
#     4. Sends NOTIFY for all zones to the new IP
#     5. Prints the install command to run on the new secondary server
#
#   promote-to-primary
#     1. Converts all Secondary zones to Primary on the surviving server
#     2. Removes secondary/autosecondary flags from pdns.conf
#     3. Restarts pdns
#     4. Prints the panel setting to update (API URL)
#
#   add-secondary
#     1. Adds new IP to primary's also-notify + allow-axfr-ips
#     2. Restarts pdns on primary
#     3. Sends NOTIFY for all zones to the new IP
#     4. Prints the install command to run on the new secondary server

set -euo pipefail

CMD="${1:-}"
shift || true

PRIMARY=""
SERVER=""
OLD_IP=""
NEW_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary)  PRIMARY="$2"; shift 2 ;;
        --server)   SERVER="$2";  shift 2 ;;
        --old-ip)   OLD_IP="$2";  shift 2 ;;
        --new-ip)   NEW_IP="$2";  shift 2 ;;
        -h|--help)  sed -n '/^#/p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Edit a comma-separated config directive in pdns.conf on a remote server.
# Usage: pdns_conf_set_ips <ssh-host> <directive> <old-ip-to-remove> <new-ip-to-add>
pdns_conf_set_ips() {
    local host="$1" directive="$2" remove_ip="$3" add_ip="$4"

    ssh "$host" "
        CONF=/etc/pdns/pdns.conf
        CURRENT=\$(grep \"^${directive}=\" \"\$CONF\" 2>/dev/null | cut -d= -f2 || echo '')

        # Build new IP list: remove old, add new, deduplicate
        NEW=\$(echo \"\$CURRENT,${add_ip}\" | tr ',' '\n' \
            | grep -v '^${remove_ip}\$' \
            | grep -v '^\$' \
            | sort -u \
            | tr '\n' ',' \
            | sed 's/,\$//')

        if grep -q \"^${directive}=\" \"\$CONF\"; then
            sed -i \"s|^${directive}=.*|${directive}=\${NEW}|\" \"\$CONF\"
        else
            echo \"${directive}=\${NEW}\" >> \"\$CONF\"
        fi
        echo \"  ${directive}=\${NEW}\"
    "
}

# ── replace-secondary ─────────────────────────────────────────────────────────

if [[ "$CMD" == "replace-secondary" ]]; then
    [[ -n "$PRIMARY" ]] || die "--primary required"
    [[ -n "$NEW_IP"  ]] || die "--new-ip required (new secondary IP)"

    echo ""
    echo -e "${BOLD}Replace secondary${NC}"
    [[ -n "$OLD_IP" ]] && info "Removing old secondary: $OLD_IP" || info "No --old-ip given — just adding $NEW_IP"
    info "New secondary: $NEW_IP"
    info "Primary server: $PRIMARY"
    echo ""

    info "Updating primary pdns.conf..."
    pdns_conf_set_ips "$PRIMARY" "also-notify"   "${OLD_IP:-__none__}" "$NEW_IP"
    pdns_conf_set_ips "$PRIMARY" "allow-axfr-ips" "${OLD_IP:-__none__}" "$NEW_IP"
    ok "Config updated on $PRIMARY"

    info "Restarting PowerDNS on primary..."
    ssh "$PRIMARY" "systemctl restart pdns"
    ok "pdns restarted"

    info "Sending NOTIFY for all zones to $NEW_IP..."
    ZONE_COUNT=$(ssh "$PRIMARY" "
        pdns_control list-zones 2>/dev/null | while read -r zone; do
            [[ -z \"\$zone\" ]] && continue
            pdns_control notify-host \"\$zone\" '${NEW_IP}' 2>/dev/null || true
            echo \"\$zone\"
        done | wc -l
    ")
    ok "NOTIFY sent for ${ZONE_COUNT} zones"

    PRIMARY_IP=$(ssh "$PRIMARY" "hostname -I | awk '{print \$1}'")
    API_KEY=$(ssh "$PRIMARY" "grep '^api-key' /etc/pdns/pdns.conf | cut -d= -f2 | tr -d ' '")

    echo ""
    echo -e "${BOLD}${GREEN}Done.${NC} Now run this on the new secondary server (${NEW_IP}):${NC}"
    echo ""
    echo -e "  bash <(curl -fsSL https://raw.githubusercontent.com/JosephChuks/kinsmen-pdns/main/install-pdns-server.sh) \\"
    echo -e "      --mode secondary \\"
    echo -e "      --primary-ip ${PRIMARY_IP} \\"
    echo -e "      --api-key ${API_KEY}"
    echo ""
fi

# ── promote-to-primary ────────────────────────────────────────────────────────

if [[ "$CMD" == "promote-to-primary" ]]; then
    [[ -n "$SERVER" ]] || die "--server required (the secondary to promote)"

    echo ""
    echo -e "${BOLD}Promote ${SERVER} from secondary → primary${NC}"
    echo ""
    warn "This assumes the original primary is DOWN and unreachable."
    echo ""

    info "Converting all Secondary zones to Primary on $SERVER..."
    RESULT=$(ssh "$SERVER" "
        CONVERTED=0
        FAILED=0
        while IFS= read -r zone; do
            [[ -z \"\$zone\" ]] && continue
            TYPE=\$(pdnsutil show-zone \"\$zone\" 2>/dev/null | grep '^Type' | awk '{print \$2}')
            if [[ \"\$TYPE\" == 'Secondary' || \"\$TYPE\" == 'Slave' ]]; then
                if pdnsutil change-zone-type \"\$zone\" PRIMARY 2>/dev/null; then
                    CONVERTED=\$((CONVERTED+1))
                else
                    FAILED=\$((FAILED+1))
                fi
            fi
        done < <(pdns_control list-zones 2>/dev/null)
        echo \"converted=\${CONVERTED} failed=\${FAILED}\"
    ")
    ok "Zone conversion: $RESULT"

    info "Removing secondary mode from pdns.conf on $SERVER..."
    ssh "$SERVER" "
        sed -i '/^secondary=/d' /etc/pdns/pdns.conf
        sed -i '/^autosecondary=/d' /etc/pdns/pdns.conf
        sed -i '/^slave=/d' /etc/pdns/pdns.conf
        sed -i '/^autoslave=/d' /etc/pdns/pdns.conf
    "
    ok "Secondary flags removed"

    info "Restarting PowerDNS on $SERVER..."
    ssh "$SERVER" "systemctl restart pdns"
    sleep 2
    ssh "$SERVER" "systemctl is-active pdns >/dev/null && echo 'pdns active' || echo 'pdns FAILED'"
    ok "pdns restarted as primary"

    SERVER_IP=$(ssh "$SERVER" "hostname -I | awk '{print \$1}'")
    API_KEY=$(ssh "$SERVER" "grep '^api-key' /etc/pdns/pdns.conf | cut -d= -f2 | tr -d ' '")

    echo ""
    echo -e "${BOLD}${GREEN}Done. ${SERVER} is now the primary.${NC}"
    echo ""
    echo -e "  ${YELLOW}1. Update the panel:${NC}"
    echo -e "     Admin → Settings → PowerDNS → API URL:"
    echo -e "     ${CYAN}http://${SERVER_IP}:8081/api/v1/servers/localhost${NC}"
    echo ""
    echo -e "  ${YELLOW}2. Add a new secondary (when ready):${NC}"
    echo -e "     bash pdns-failover.sh add-secondary --primary ${SERVER} --new-ip <new-server-ip>"
    echo ""
fi

# ── add-secondary ─────────────────────────────────────────────────────────────

if [[ "$CMD" == "add-secondary" ]]; then
    [[ -n "$PRIMARY" ]] || die "--primary required"
    [[ -n "$NEW_IP"  ]] || die "--new-ip required"

    echo ""
    echo -e "${BOLD}Add secondary ${NEW_IP} to primary ${PRIMARY}${NC}"
    echo ""

    info "Updating primary pdns.conf..."
    pdns_conf_set_ips "$PRIMARY" "also-notify"    "" "$NEW_IP"
    pdns_conf_set_ips "$PRIMARY" "allow-axfr-ips" "" "$NEW_IP"

    # Ensure disable-axfr=no
    ssh "$PRIMARY" "
        grep -q '^disable-axfr=' /etc/pdns/pdns.conf \
            && sed -i 's/^disable-axfr=.*/disable-axfr=no/' /etc/pdns/pdns.conf \
            || echo 'disable-axfr=no' >> /etc/pdns/pdns.conf
    "
    ok "Config updated"

    info "Restarting PowerDNS on primary..."
    ssh "$PRIMARY" "systemctl restart pdns"
    ok "pdns restarted"

    info "Sending NOTIFY for all zones to $NEW_IP..."
    ZONE_COUNT=$(ssh "$PRIMARY" "
        pdns_control list-zones 2>/dev/null | while read -r zone; do
            [[ -z \"\$zone\" ]] && continue
            pdns_control notify-host \"\$zone\" '${NEW_IP}' 2>/dev/null || true
            echo \"\$zone\"
        done | wc -l
    ")
    ok "NOTIFY sent for ${ZONE_COUNT} zones"

    PRIMARY_IP=$(ssh "$PRIMARY" "hostname -I | awk '{print \$1}'")
    API_KEY=$(ssh "$PRIMARY" "grep '^api-key' /etc/pdns/pdns.conf | cut -d= -f2 | tr -d ' '")

    echo ""
    echo -e "${BOLD}${GREEN}Done.${NC} Now run this on the new secondary server (${NEW_IP}):${NC}"
    echo ""
    echo -e "  bash <(curl -fsSL https://raw.githubusercontent.com/JosephChuks/kinsmen-pdns/main/install-pdns-server.sh) \\"
    echo -e "      --mode secondary \\"
    echo -e "      --primary-ip ${PRIMARY_IP} \\"
    echo -e "      --api-key ${API_KEY}"
    echo ""
fi

# ── Unknown command ───────────────────────────────────────────────────────────

if [[ -z "$CMD" ]] || ! [[ "$CMD" =~ ^(replace-secondary|promote-to-primary|add-secondary)$ ]]; then
    echo ""
    echo "Usage: bash pdns-failover.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  replace-secondary   --primary HOST --new-ip IP [--old-ip IP]"
    echo "  promote-to-primary  --server HOST"
    echo "  add-secondary       --primary HOST --new-ip IP"
    echo ""
    echo "Run with --help for full documentation."
    echo ""
    [[ -n "$CMD" ]] && die "Unknown command: $CMD"
    exit 0
fi
