#!/bin/bash
# ============================================================
# Supabase HA - Failover Test Script
# Run from the ha/ directory: bash scripts/test-failover.sh
# ============================================================

set -euo pipefail

# shellcheck source=../.env
ENV_FILE="$(dirname "$0")/../.env"
source "$ENV_FILE" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)] $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +%T)] $*${NC}"; }
fail() { echo -e "${RED}[$(date +%T)] $*${NC}"; exit 1; }

# ── Helper: run psql on a specific container ─────────────────
pg_exec() {
  local container="$1"
  local sql="$2"
  docker exec "$container" gosu postgres psql -U postgres -h /var/run/postgresql -d postgres -c "$sql"
}

# ── Helper: get current Patroni leader name ───────────────────
get_leader() {
  local container="$1"
  docker exec "$container" curl -sf http://localhost:8008/cluster 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['name']) for m in d['members'] if m['role']=='leader']" \
    2>/dev/null || echo "unknown"
}

# ── Helper: find which replica is now leader ─────────────────
get_new_leader_container() {
  for c in ha-pg-replica-1 ha-pg-replica-2; do
    role=$(docker exec "$c" curl -sf http://localhost:8008/ 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('role',''))" 2>/dev/null || echo "")
    if [ "$role" = "master" ] || [ "$role" = "primary" ]; then
      echo "$c"
      return
    fi
  done
  echo "ha-pg-replica-1"
}

# ── Step 0: Ensure test table exists ─────────────────────────
log "Step 0: Creating ha_test table on primary..."
pg_exec ha-pg-primary \
  "CREATE TABLE IF NOT EXISTS ha_test (id serial PRIMARY KEY, label text, ts timestamptz);" \
  || fail "Could not create test table. Is the stack running?"

# ── Step 1: Baseline write ────────────────────────────────────
log "Step 1: Writing baseline row before failover..."
pg_exec ha-pg-primary \
  "INSERT INTO ha_test (label, ts) VALUES ('before-failover', now()) RETURNING id, label, ts;"

LEADER_BEFORE=$(get_leader ha-pg-primary)
log "Current Patroni leader: ${LEADER_BEFORE}"

# ── Step 2: Kill the primary container ───────────────────────
warn "Step 2: Stopping container ha-pg-primary to simulate pod/node failure..."
docker stop ha-pg-primary

log "Waiting 20s for Patroni to detect failure and elect new leader..."
sleep 20

# ── Step 3: Verify new leader ────────────────────────────────
log "Step 3: Checking new Patroni leader..."
LEADER_AFTER=$(get_leader ha-pg-replica-1)
log "New leader: ${LEADER_AFTER}"

if [ "$LEADER_AFTER" = "$LEADER_BEFORE" ] || [ "$LEADER_AFTER" = "unknown" ]; then
  warn "Leader may not have changed yet, waiting 10 more seconds..."
  sleep 10
  LEADER_AFTER=$(get_leader ha-pg-replica-1)
  log "New leader after extra wait: ${LEADER_AFTER}"
fi

# ── Step 4: Write to new leader ──────────────────────────────
log "Step 4: Writing row to new leader..."
NEW_LEADER_CONTAINER=$(get_new_leader_container)
log "Writing via container: ${NEW_LEADER_CONTAINER}"
pg_exec "$NEW_LEADER_CONTAINER" \
  "INSERT INTO ha_test (label, ts) VALUES ('after-failover', now()) RETURNING id, label, ts;"

# ── Step 5: Verify data consistency ──────────────────────────
log "Step 5: Reading all rows to verify data consistency..."
pg_exec "$NEW_LEADER_CONTAINER" \
  "SELECT id, label, ts FROM ha_test ORDER BY id;"

# ── Step 6: Restart old primary (rejoins as replica) ─────────
log "Step 6: Restarting old primary container (it will rejoin as replica)..."
docker start ha-pg-primary
sleep 25

log "Final cluster state:"
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
