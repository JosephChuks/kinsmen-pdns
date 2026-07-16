#!/bin/bash
# pdns-backup-zones.sh — Export all PowerDNS zones to a backup directory
#
# Usage:
#   bash pdns-backup-zones.sh [--output-dir /path/to/dir] [--host dns1] [--api-key KEY]
#
# Exports each zone as a BIND-format zone file (.zone) plus a full JSON snapshot
# (zones.json) for import. Run on the DNS server itself or point at a remote API.

set -euo pipefail

OUTPUT_DIR=""
API_HOST="localhost"
API_PORT=8081
API_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --host)       API_HOST="$2"; shift 2 ;;
        --port)       API_PORT="$2"; shift 2 ;;
        --api-key)    API_KEY="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Auto-read API key from local pdns.conf if not provided
if [[ -z "$API_KEY" ]]; then
    API_KEY=$(ssh "$API_HOST" "grep '^api-key' /etc/pdns/pdns.conf | cut -d= -f2 | tr -d ' '" 2>/dev/null) || true
    if [[ -z "$API_KEY" && "$API_HOST" == "localhost" ]]; then
        API_KEY=$(grep '^api-key' /etc/pdns/pdns.conf 2>/dev/null | cut -d= -f2 | tr -d ' ')
    fi
fi
[[ -n "$API_KEY" ]] || { echo "ERROR: --api-key required or /etc/pdns/pdns.conf not found" >&2; exit 1; }

API_URL="http://${API_HOST}:${API_PORT}/api/v1/servers/localhost"

# Default output dir: timestamped
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="pdns-backup-$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC}  $*"; }
info() { echo -e "${CYAN}ℹ${NC}  $*"; }
err()  { echo -e "${RED}✗${NC}  $*" >&2; }

info "Connecting to PowerDNS at $API_HOST:$API_PORT ..."

# List all zones
ZONES_JSON=$(curl -sf -H "X-API-Key: $API_KEY" "$API_URL/zones") || {
    err "Failed to list zones from $API_URL"
    exit 1
}

ZONE_COUNT=$(echo "$ZONES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
info "Found $ZONE_COUNT zones — exporting to $OUTPUT_DIR/"

# Save full zone list JSON (used by restore script)
echo "$ZONES_JSON" > "$OUTPUT_DIR/zones-list.json"

OK=0; FAIL=0
while IFS= read -r ZONE_ID; do
    ZONE_NAME="${ZONE_ID%.}"   # strip trailing dot for filename
    # Export as BIND zone file
    BIND_OUT=$(curl -sf -H "X-API-Key: $API_KEY" "$API_URL/zones/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ZONE_ID'))")/export") || {
        err "  $ZONE_NAME: export failed"
        ((FAIL++)) || true
        continue
    }
    echo "$BIND_OUT" > "$OUTPUT_DIR/${ZONE_NAME}.zone"
    # Also export full JSON for zone (includes all rrsets)
    curl -sf -H "X-API-Key: $API_KEY" "$API_URL/zones/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$ZONE_ID'))")" \
        > "$OUTPUT_DIR/${ZONE_NAME}.json"
    ((OK++)) || true
done < <(echo "$ZONES_JSON" | python3 -c "import sys,json; [print(z['id']) for z in json.load(sys.stdin)]")

# Manifest
cat > "$OUTPUT_DIR/MANIFEST" << EOF
backup_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
api_host=$API_HOST
zone_count=$OK
failed=$FAIL
EOF

echo ""
ok "Backup complete: $OK zones exported, $FAIL failed"
ok "Output: $OUTPUT_DIR/"
echo ""
echo "  To restore to a new server:"
echo "    bash pdns-restore-zones.sh --backup-dir $OUTPUT_DIR --host NEW_SERVER --api-key KEY"
