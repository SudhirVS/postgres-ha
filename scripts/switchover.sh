#!/bin/bash
# ============================================================
# Supabase HA - Manual Switchover (graceful, zero data loss)
# Usage: bash scripts/switchover.sh [target-node]
# Example: bash scripts/switchover.sh pg-replica-1
# ============================================================

TARGET="${1:-}"
SCOPE="supabase-ha"

if [ -z "$TARGET" ]; then
  echo "Usage: $0 <target-node>"
  echo "Available nodes:"
  docker exec ha-pg-primary curl -sf http://localhost:8008/cluster \
    | python3 -c "import sys,json; [print('  ' + m['name']) for m in json.load(sys.stdin)['members']]"
  exit 1
fi

echo "Performing graceful switchover to: $TARGET"
echo "This is a planned operation with no data loss."
echo ""

docker exec ha-pg-primary patronictl \
  -c /tmp/patroni-rendered.yml \
  switchover "$SCOPE" \
  --master "$(docker exec ha-pg-primary curl -sf http://localhost:8008/cluster \
    | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin)['members'] if m['role']=='Leader']")" \
  --candidate "$TARGET" \
  --force

echo ""
echo "Switchover complete. New cluster state:"
sleep 5
docker exec ha-pg-primary curl -sf http://localhost:8008/cluster \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin)['members']:
    print(f\"  {m['name']:20s}  role={m['role']:10s}  state={m['state']}\")
"
