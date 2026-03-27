#!/bin/bash
# ============================================================
# Supabase HA - Cluster Status Check
# Run from the ha/ directory: bash scripts/status.sh
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Supabase HA - Cluster Status${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"

echo ""
echo -e "${YELLOW}── Patroni Cluster (via pg-primary) ──${NC}"
docker exec ha-pg-primary curl -sf http://localhost:8008/cluster 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for m in d['members']:
        role  = m.get('role', 'unknown')
        state = m.get('state', 'unknown')
        lag   = m.get('lag', 0)
        tl    = m.get('timeline', '?')
        print(f\"  {m['name']:20s}  role={role:10s}  state={state:12s}  timeline={tl}  lag={lag}\")
except Exception as e:
    print(f'  Could not parse cluster info: {e}')
" || echo "  ha-pg-primary is not reachable"

echo ""
echo -e "${YELLOW}── HAProxy Backend Status ──${NC}"
echo "  Stats UI: http://localhost:7000"
docker exec ha-haproxy sh -c \
  "echo 'show stat' | socat stdio /var/run/haproxy/admin.sock 2>/dev/null | cut -d',' -f1,2,18,19 | grep -E 'pg_primary|pg_replica'" \
  2>/dev/null || echo "  (HAProxy stats socket not available in this image - use http://localhost:7000)"

echo ""
echo -e "${YELLOW}── Docker Container Health ──${NC}"
docker ps --filter "name=ha-" --filter "name=supabase-" \
  --format "  {{.Names}}\t{{.Status}}" | column -t

echo ""
echo -e "${YELLOW}── Replication Lag (from primary) ──${NC}"
docker exec ha-pg-primary sh -c \
  "PGPASSWORD=\${POSTGRES_PASSWORD} psql -U postgres -d postgres -c \
   \"SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
     (sent_lsn - replay_lsn) AS replication_lag
     FROM pg_stat_replication;\"" 2>/dev/null \
  || echo "  Primary not reachable or no replicas connected"

echo ""
echo -e "${GREEN}Done.${NC}"
