#!/bin/bash
# pdns-restore-zones.sh — Import zones from a pdns-backup-zones.sh backup
#
# Usage:
#   bash pdns-restore-zones.sh --backup-dir pdns-backup-YYYYMMDD/ --host NEW_DNS_SERVER --api-key KEY
#
# The target server must have PowerDNS installed and the API enabled.
# Existing zones on the target are NOT overwritten unless --force is passed.

set -euo pipefail

BACKUP_DIR=""
API_HOST=""
API_PORT=8081
API_KEY=""
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
        --host)       API_HOST="$2"; shift 2 ;;
        --port)       API_PORT="$2"; shift 2 ;;
        --api-key)    API_KEY="$2"; shift 2 ;;
        --force)      FORCE=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$BACKUP_DIR" ]] || { echo "ERROR: --backup-dir required" >&2; exit 1; }
[[ -d "$BACKUP_DIR" ]]  || { echo "ERROR: $BACKUP_DIR not found" >&2; exit 1; }
[[ -n "$API_HOST" ]]    || { echo "ERROR: --host required" >&2; exit 1; }
[[ -n "$API_KEY" ]]     || { echo "ERROR: --api-key required" >&2; exit 1; }

API_URL="http://${API_HOST}:${API_PORT}/api/v1/servers/localhost"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*" >&2; }

info "Restoring zones to $API_HOST:$API_PORT ..."

# Verify API is reachable
curl -sf -H "X-API-Key: $API_KEY" "$API_URL" >/dev/null || {
    err "PowerDNS API not reachable at $API_URL — is it running with api=yes and webserver=yes?"
    exit 1
}

OK=0; SKIP=0; FAIL=0

for JSON_FILE in "$BACKUP_DIR"/*.json; do
    [[ "$JSON_FILE" == *"zones-list.json" ]] && continue
    ZONE_NAME=$(basename "$JSON_FILE" .json)
    ZONE_FQDN="${ZONE_NAME}."

    ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ZONE_FQDN'))")

    # Check if zone already exists
    STATUS=$(curl -sf -o /dev/null -w '%{http_code}' -H "X-API-Key: $API_KEY" "$API_URL/zones/$ENCODED" 2>/dev/null || echo "000")

    if [[ "$STATUS" == "200" && "$FORCE" -eq 0 ]]; then
        warn "  $ZONE_NAME: already exists — skipping (use --force to overwrite)"
        ((SKIP++)) || true
        continue
    fi

    # Read zone JSON
    ZONE_JSON=$(cat "$JSON_FILE")

    if [[ "$STATUS" == "200" ]]; then
        # Update existing zone rrsets
        RRSETS=$(echo "$ZONE_JSON" | python3 -c "
import sys, json
z = json.load(sys.stdin)
sets = []
for r in z.get('rrsets', []):
    r['changetype'] = 'REPLACE'
    sets.append(r)
print(json.dumps({'rrsets': sets}))
")
        RESP=$(curl -sf -o /dev/null -w '%{http_code}' -X PATCH \
            -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
            -d "$RRSETS" "$API_URL/zones/$ENCODED" 2>/dev/null || echo "000")
        if [[ "$RESP" == "204" || "$RESP" == "200" ]]; then
            ok "  $ZONE_NAME: updated"
            ((OK++)) || true
        else
            err "  $ZONE_NAME: update failed (HTTP $RESP)"
            ((FAIL++)) || true
        fi
    else
        # Create zone with rrsets
        CREATE_PAYLOAD=$(echo "$ZONE_JSON" | python3 -c "
import sys, json
z = json.load(sys.stdin)
payload = {
    'name': z['name'],
    'kind': z.get('kind', 'Native'),
    'nameservers': [],
    'rrsets': z.get('rrsets', [])
}
print(json.dumps(payload))
")
        RESP=$(curl -sf -o /dev/null -w '%{http_code}' -X POST \
            -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
            -d "$CREATE_PAYLOAD" "$API_URL/zones" 2>/dev/null || echo "000")
        if [[ "$RESP" == "201" || "$RESP" == "200" ]]; then
            ok "  $ZONE_NAME: created"
            ((OK++)) || true
        else
            err "  $ZONE_NAME: create failed (HTTP $RESP)"
            ((FAIL++)) || true
        fi
    fi
done

echo ""
ok "Restore complete: $OK restored, $SKIP skipped, $FAIL failed"
[[ $FAIL -gt 0 ]] && warn "Check errors above — failed zones may need manual attention"
