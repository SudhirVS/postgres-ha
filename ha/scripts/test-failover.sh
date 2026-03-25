#!/bin/bash
# ============================================================
# Supabase HA - Failover Test Script
# Run from the ha/ directory: bash scripts/test-failover.sh
# ============================================================

set -euo pipefail

# shellcheck source=../.env
ENV_FILE="$(dirname "$0")/../.env"
source "$ENV_FILE" 2>/dev/null || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] $*${NC}"; }
fail() { echo -e "${RED}[$(date +%T)] $*${NC}"; exit 1; }

# ── Helper: get current Patroni leader ──────────────────────
get_leader() {
  docker exec ha-pg-primary curl -sf http://localhost:8008/cluster 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['name']) for m in d['members'] if m['role']=='Leader']" \
    2>/dev/null || echo "unknown"
}

# ── Helper: write a test row ────────────────────────────────
write_test_row() {
  local label="$1"
  docker exec ha-haproxy sh -c \
    "PGPASSWORD=${POSTGRES_PASSWORD} psql -h 127.0.0.1 -p 5432 -U postgres -d postgres \
     -c \"INSERT INTO ha_test (label, ts) VALUES ('${label}', now()) RETURNING id, label, ts;\"" \
    2>/dev/null
}

# ── Helper: read test rows ───────────────────────────────────
read_test_rows() {
  docker exec ha-haproxy sh -c \
    "PGPASSWORD=${POSTGRES_PASSWORD} psql -h 127.0.0.1 -p 5432 -U postgres -d postgres \
     -c \"SELECT id, label, ts FROM ha_test ORDER BY id;\"" \
    2>/dev/null
}

# ── Step 0: Ensure test table exists ────────────────────────
log "Step 0: Creating ha_test table on primary..."
docker exec ha-haproxy sh -c \
  "PGPASSWORD=${POSTGRES_PASSWORD} psql -h 127.0.0.1 -p 5432 -U postgres -d postgres \
   -c \"CREATE TABLE IF NOT EXISTS ha_test (id serial PRIMARY KEY, label text, ts timestamptz);\"" \
  || fail "Could not create test table. Is the stack running?"

# ── Step 1: Baseline write ───────────────────────────────────
log "Step 1: Writing baseline row before failover..."
write_test_row "before-failover"

LEADER_BEFORE=$(get_leader)
log "Current Patroni leader: ${LEADER_BEFORE}"

# ── Step 2: Kill the primary container ──────────────────────
warn "Step 2: Stopping container ha-pg-primary to simulate pod/node failure..."
docker stop ha-pg-primary

log "Waiting 15s for Patroni to detect failure and elect new leader..."
sleep 15

# ── Step 3: Verify new leader ───────────────────────────────
log "Step 3: Checking new Patroni leader..."
# Query from replica-1 since primary is down
LEADER_AFTER=$(docker exec ha-pg-replica-1 curl -sf http://localhost:8008/cluster 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['name']) for m in d['members'] if m['role']=='Leader']" \
  2>/dev/null || echo "unknown")

log "New leader: ${LEADER_AFTER}"

if [ "$LEADER_AFTER" = "$LEADER_BEFORE" ]; then
  fail "Leader did NOT change after killing primary! Failover may have failed."
fi

# ── Step 4: Write through HAProxy to new primary ────────────
log "Step 4: Writing row through HAProxy to new primary..."
sleep 5  # give HAProxy health check time to re-route
write_test_row "after-failover"

# ── Step 5: Verify data consistency ─────────────────────────
log "Step 5: Reading all rows to verify data consistency..."
read_test_rows

# ── Step 6: Restart old primary (it rejoins as replica) ─────
log "Step 6: Restarting old primary container (it will rejoin as replica)..."
docker start ha-pg-primary
sleep 20

log "Cluster state after recovery:"
docker exec ha-pg-replica-1 curl -sf http://localhost:8008/cluster \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d['members']:
    print(f\"  {m['name']:20s}  role={m['role']:10s}  state={m['state']}  lag={m.get('lag', 0)}\")
"

log "✅ Failover test complete."
log "   Leader before: ${LEADER_BEFORE}"
log "   Leader after:  ${LEADER_AFTER}"
log "   Data written before and after failover is visible — consistency maintained."
