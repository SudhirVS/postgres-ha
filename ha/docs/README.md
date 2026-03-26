# Supabase Self-Hosted — High Availability PostgreSQL

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Component Roles](#2-component-roles)
3. [Directory Structure](#3-directory-structure)
4. [How It Works](#4-how-it-works)
5. [Setup & Deployment](#5-setup--deployment)
6. [Failover Testing](#6-failover-testing)
7. [Monitoring](#7-monitoring)
8. [Known Issues & Fixes Applied](#8-known-issues--fixes-applied)
9. [Limitations](#9-limitations)

---

## 1. Architecture Overview

```
                        ┌─────────────────────────────────────────────┐
                        │           Supabase Services Layer            │
                        │  Studio · Kong · Auth · REST · Realtime      │
                        │  Storage · Meta · Functions · Analytics      │
                        │  Supavisor (pooler)                          │
                        └──────────────────┬──────────────────────────┘
                                           │ all DB connections
                                           ▼
                        ┌─────────────────────────────────────────────┐
                        │              HAProxy :5432 (rw)              │
                        │              HAProxy :5433 (ro)              │
                        │         Health-checks Patroni REST API       │
                        └──────┬──────────────┬──────────────┬────────┘
                               │              │              │
                    HTTP GET /primary   HTTP GET /primary   HTTP GET /primary
                    → 200 on leader     → 503 on standby    → 503 on standby
                               │              │              │
                    ┌──────────▼──┐  ┌────────▼────┐  ┌────▼────────┐
                    │ pg-primary  │  │ pg-replica-1│  │ pg-replica-2│
                    │  Patroni    │  │  Patroni    │  │  Patroni    │
                    │  PG 15      │  │  PG 15      │  │  PG 15      │
                    │  :5432      │  │  :5432      │  │  :5432      │
                    │  :8008      │  │  :8008      │  │  :8008      │
                    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
                           │               │                  │
                           └───────────────┴──────────────────┘
                                           │
                                    ┌──────▼──────┐
                                    │    etcd     │
                                    │  :2379      │
                                    │ Leader lock │
                                    │ Cluster DCS │
                                    └─────────────┘
```

### Failure Tolerance

| Failure Type | Handled By | Recovery Time |
|---|---|---|
| Pod crash (any PG node) | Patroni + Docker `restart: unless-stopped` | ~10–30s |
| Primary pod crash | Patroni automatic failover via etcd | ~20s (proven) |
| Node failure (conceptual) | Patroni elects new leader from remaining nodes | ~20–30s |
| Supabase service crash | Docker `restart: unless-stopped` | ~5s |
| HAProxy crash | Docker `restart: unless-stopped` | ~5s |

### Proven Failover Result (live on AWS EC2 t3.xlarge)

```
Leader before:  pg-primary
Simulated:      docker stop ha-pg-primary
Failover time:  ~20 seconds
Leader after:   pg-replica-2
Data check:     id=1 before-failover ✅  id=34 after-failover ✅
Old primary:    rejoined as replica, lag=0
```

---

## 2. Component Roles

### etcd (`quay.io/coreos/etcd:v3.5.14`)
- Single-node etcd for Patroni leader election and cluster state
- Stores the leader lock with TTL=30s — when lock expires, replicas compete to become leader
- Use 3-node etcd cluster in production (see Limitations)

### Patroni (runs inside each PG container)
- Manages PostgreSQL lifecycle on each node
- Exposes REST API on `:8008`:
  - `GET /primary` → HTTP 200 only on the current leader
  - `GET /replica` → HTTP 200 only on standbys
  - `GET /health`  → HTTP 200 on any healthy node
  - `GET /cluster` → full cluster JSON
- Runs `post_bootstrap.sh` once after first cluster init to create all Supabase roles and schemas
- Performs `pg_rewind` on the old primary after failover so it rejoins as replica

### HAProxy (`haproxy:2.9-alpine`)
- `:5432` → primary (read-write), health-checked via `GET /primary`
- `:5433` → replicas (read-only, round-robin), health-checked via `GET /replica`
- `:7000` → stats dashboard
- `shutdown-sessions` on marked-down servers — drops stale connections immediately on failover
- All Supabase services connect to `haproxy:5432`

### Supavisor (`supabase/supavisor:2.7.4`)
- Transaction-mode connection pooler
- Connects to `haproxy:5432` — follows primary automatically after failover
- Exposed on `:5435` (session mode) and `:6543` (transaction mode)
- Note: port 5432 on host is owned by HAProxy; Supavisor uses 5435

### Supabase Services
- All 12 services point to `haproxy` as `POSTGRES_HOST`
- On failover, HAProxy re-routes; services reconnect on next query attempt (1–5s)
- `auth`, `storage`, `realtime` each own their schema (`auth`, `storage`, `realtime`)
- `analytics` uses `_supabase` database with `_analytics` schema

---

## 3. Directory Structure

```
ha/
├── .env                          # All secrets and config
├── docker-compose.yml            # Full HA stack (17 containers)
├── patroni/
│   ├── patroni-primary.yml       # Patroni config for node 1 (includes post_bootstrap hook)
│   ├── patroni-replica-1.yml     # Patroni config for node 2
│   └── patroni-replica-2.yml     # Patroni config for node 3
├── postgres/
│   ├── Dockerfile                # PG 15 + Patroni + gosu image
│   ├── entrypoint.sh             # Fixes permissions, runs Patroni as postgres user
│   ├── post_bootstrap.sh         # Creates all Supabase roles, schemas, grants (runs once)
│   └── init.sql                  # SQL executed by post_bootstrap.sh
├── haproxy/
│   └── haproxy.cfg               # Routes :5432→primary, :5433→replicas
├── supabase/
│   └── pooler.exs                # Supavisor tenant config pointing to haproxy
├── volumes/
│   ├── api/
│   │   ├── kong.yml              # Kong declarative config with all Supabase routes
│   │   └── kong-entrypoint.sh    # Substitutes env vars, starts kong, tails logs
│   ├── functions/main/
│   │   └── index.ts              # Edge functions main handler
│   └── logs/
│       └── vector.yml            # Log aggregation config
├── scripts/
│   ├── test-failover.sh          # Automated failover test (proven working)
│   ├── switchover.sh             # Graceful planned switchover via patronictl
│   └── status.sh                 # Cluster health check
└── docs/
    └── README.md                 # This file
```

---

## 4. How It Works

### Normal Operation
1. `pg-primary` holds the etcd leader lock → Patroni marks it as Leader
2. `pg-replica-1` and `pg-replica-2` stream WAL from the primary (lag=0 verified)
3. HAProxy health-checks all three nodes every 3s via `GET /primary`
4. Only the leader returns HTTP 200 → HAProxy routes all writes there
5. All Supabase services connect through `haproxy:5432`

### Automatic Failover (pod/node failure)
1. Primary container crashes or is stopped
2. Patroni on replicas detects leader lock expired (TTL=30s, loop_wait=10s)
3. Replica with most up-to-date WAL wins the etcd election
4. Winner promotes itself (`pg_ctl promote`)
5. HAProxy health check on new primary returns 200 within 3s
6. HAProxy re-routes `:5432` traffic to new primary
7. Supabase services get a connection error, retry, reconnect to new primary
8. Old primary restarts → Patroni runs `pg_rewind` → rejoins as replica

### Data Consistency
- `maximum_lag_on_failover: 1048576` (1 MB) — Patroni will not promote a replica more than 1 MB behind
- `wal_log_hints: on` — required for `pg_rewind`
- `data-checksums` enabled at initdb — detects data corruption
- `use_pg_rewind: true` — old primary syncs and rejoins without full re-clone

### Bootstrap Process (first start only)
1. `pg-primary` runs `initdb` via Patroni
2. Patroni calls `post_bootstrap.sh` which:
   - Creates all Supabase roles (`supabase_admin`, `supabase_auth_admin`, `authenticator`, etc.)
   - Creates schemas: `auth`, `storage`, `realtime`, `extensions`, `pgbouncer`, `_realtime`
   - Creates `_supabase` database with `_analytics` and `_supavisor` schemas
   - Grants all required permissions
3. Replicas clone from primary via `pg_basebackup`

---

## 5. Setup & Deployment

### Prerequisites
- Ubuntu 22.04 LTS (tested and proven)
- Docker Engine 24+ with Compose plugin
- 8 GB RAM minimum, 16 GB recommended
- 50 GB disk (gp3 SSD recommended)
- Ports free: `5432`, `5433`, `5435`, `6543`, `7000`, `8000`, `8443`

### Step 1 — Install Docker (Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER && newgrp docker
```

### Step 2 — Clone and prepare

```bash
git clone <your-repo-url> ~/postgres-ha
cd ~/postgres-ha/ha

# Fix line endings and permissions
sudo apt-get install -y dos2unix
find . -name "*.sh" -exec dos2unix {} \;
find . -name "*.yml" -exec dos2unix {} \;
find . -name "*.cfg" -exec dos2unix {} \;
find . -name "*.sql" -exec dos2unix {} \;
chmod +x scripts/*.sh postgres/entrypoint.sh postgres/post_bootstrap.sh volumes/api/kong-entrypoint.sh
```

### Step 3 — Configure secrets

```bash
# Generate all secrets at once
echo "POSTGRES_PASSWORD=$(openssl rand -hex 20)"
echo "JWT_SECRET=$(openssl rand -hex 32)"
echo "SECRET_KEY_BASE=$(openssl rand -hex 32)"
echo "VAULT_ENC_KEY=$(openssl rand -hex 16)"        # must be exactly 32 chars
echo "PG_META_CRYPTO_KEY=$(openssl rand -hex 16)"   # must be exactly 32 chars
echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -hex 24)"
echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -hex 24)"
```

Edit `.env` and replace all placeholder values. Critical fields:

| Variable | Requirement |
|---|---|
| `POSTGRES_PASSWORD` | Strong password, min 20 chars |
| `JWT_SECRET` | Min 32 characters |
| `VAULT_ENC_KEY` | Exactly 32 characters |
| `PG_META_CRYPTO_KEY` | Exactly 32 characters |
| `SECRET_KEY_BASE` | Min 64 characters |
| `SUPABASE_PUBLIC_URL` | Set to `http://<your-host-ip>:8000` |
| `API_EXTERNAL_URL` | Set to `http://<your-host-ip>:8000` |
| `SITE_URL` | Set to `http://<your-host-ip>:8000` |
| `POOLER_TENANT_ID` | Any unique string e.g. `my-ha-tenant` |

### Step 4 — Increase system limits

```bash
echo "fs.file-max = 100000" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf
```

### Step 5 — Pull images

```bash
docker compose --env-file .env pull
```

### Step 6 — Build and start

```bash
docker compose --env-file .env build
docker compose --env-file .env up -d
```

First start takes 3–5 minutes. Bootstrap runs once on `pg-primary`.

### Step 7 — Apply runtime DB grants (first deployment only)

After the cluster bootstraps, apply additional grants required by storage and realtime:

```bash
docker exec -i ha-pg-primary gosu postgres psql -U postgres -d postgres << 'SQL'
GRANT CREATE ON DATABASE postgres TO supabase_storage_admin;
GRANT CREATE ON DATABASE postgres TO supabase_auth_admin;
GRANT CREATE ON DATABASE postgres TO supabase_admin;
GRANT CREATE ON DATABASE postgres TO authenticator;
GRANT ALL ON SCHEMA storage TO supabase_storage_admin;
GRANT ALL ON SCHEMA auth TO supabase_auth_admin;
ALTER USER supabase_storage_admin SET search_path = storage, public;
ALTER USER supabase_auth_admin SET search_path = auth, public;
ALTER USER supabase_admin SET search_path = public, realtime, _realtime;
SQL
```

### Step 8 — Verify

```bash
# All 17 containers should be Up or Up (healthy)
docker ps --format "table {{.Names}}\t{{.Status}}"

# Patroni cluster: 1 leader + 2 streaming replicas
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool

# Replication lag (should be 0)
docker exec ha-pg-primary gosu postgres psql -U postgres -d postgres \
  -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

### Step 9 — Access Supabase Studio

```
http://<your-host-ip>:8000
```

For AWS EC2: ensure port `8000` is open in your Security Group (inbound TCP from your IP).

---

## 6. Failover Testing

### Automated Test (proven working)

```bash
cd ~/postgres-ha/ha
bash scripts/test-failover.sh
```

Expected output:
```
[HH:MM:SS] Step 0: Creating ha_test table on primary...
[HH:MM:SS] Step 1: Writing baseline row before failover...
[HH:MM:SS] Current Patroni leader: pg-primary
[HH:MM:SS] Step 2: Stopping container ha-pg-primary to simulate pod/node failure...
[HH:MM:SS] Waiting 20s for Patroni to detect failure and elect new leader...
[HH:MM:SS] Step 3: New leader: pg-replica-2
[HH:MM:SS] Step 4: Writing row to new leader...
[HH:MM:SS] Step 5: Reading all rows to verify data consistency...
 id |      label      |              ts
----+-----------------+-------------------------------
  1 | before-failover | 2026-03-26 07:39:09.802837+00
 34 | after-failover  | 2026-03-26 07:39:32.305644+00
[HH:MM:SS] Step 6: Restarting old primary (rejoins as replica)...
[HH:MM:SS] Final cluster state:
  pg-replica-1    role=replica   state=streaming  lag=0
  pg-replica-2    role=leader    state=running    lag=0
[HH:MM:SS] ✅ Failover test complete. Leader before: pg-primary → after: pg-replica-2
```

### Manual Test Steps

**1. Check current leader:**
```bash
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool
```

**2. Simulate primary failure:**
```bash
docker stop ha-pg-primary
```

**3. Watch failover from replica:**
```bash
watch -n2 'docker exec ha-pg-replica-1 curl -s http://localhost:8008/cluster | python3 -m json.tool'
```

**4. Verify writes work on new primary:**
```bash
docker exec ha-pg-replica-1 gosu postgres psql -U postgres -h /var/run/postgresql -d postgres \
  -c "INSERT INTO ha_test (label, ts) VALUES ('manual-test', now()) RETURNING *;"
```

**5. Restore old primary:**
```bash
docker start ha-pg-primary
# Patroni runs pg_rewind and rejoins it as replica automatically
```

**6. Verify full cluster restored:**
```bash
bash scripts/status.sh
```

### Graceful Switchover (planned maintenance, zero data loss)

```bash
bash scripts/switchover.sh pg-replica-1
```

### HAProxy Stats

```
http://<your-host-ip>:7000
```

---

## 7. Monitoring

### Patroni REST API

| Endpoint | Returns 200 when... |
|---|---|
| `http://pg-primary:8008/health` | Node is healthy (any role) |
| `http://pg-primary:8008/primary` | Node is the current leader |
| `http://pg-primary:8008/replica` | Node is a standby |
| `http://pg-primary:8008/cluster` | Always — full cluster JSON |

### Replication lag

```sql
SELECT client_addr, state, sent_lsn, replay_lsn,
       (sent_lsn - replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

### Key log commands

```bash
docker logs ha-pg-primary -f
docker logs ha-etcd -f
docker logs ha-haproxy -f
docker compose --env-file .env logs -f etcd pg-primary pg-replica-1 pg-replica-2 haproxy
```

---

## 8. Known Issues & Fixes Applied

These issues were encountered during deployment on AWS EC2 Ubuntu 22.04 and are already fixed in the codebase.

| Issue | Root Cause | Fix Applied |
|---|---|---|
| `bitnami/etcd:3.5` not found | Tag doesn't exist on Docker Hub | Switched to `quay.io/coreos/etcd:v3.5.14` |
| `initdb: cannot be run as root` | Patroni ran as root inside container | `entrypoint.sh` uses `gosu postgres` to drop privileges |
| `data directory has invalid permissions` | Volume mounted with wrong permissions | `entrypoint.sh` runs `chmod 700` on data dir |
| `postgresql-15-pgjwt not found` | Package not in Debian apt repos | Removed from Dockerfile; not required for HA |
| `Patroni v4 users block unsupported` | Patroni v4 removed bootstrap.users | Replaced with `post_bootstrap` script hook |
| `schema "auth" does not exist` | Supabase schemas not created at bootstrap | `post_bootstrap.sh` creates all required schemas |
| `permission denied for schema public` | PostgreSQL 15 revokes public schema by default | Explicit `GRANT USAGE, CREATE ON SCHEMA public` added |
| `permission denied for database postgres` | Service users missing CONNECT + CREATE grants | Grants added in `post_bootstrap.sh` and Step 7 |
| `envsubst not found` in kong | Not available in kong image | Replaced with `sed` substitution in entrypoint |
| `/docker-entrypoint.sh not found` in kong | Doesn't exist in kong image | Use `kong start` directly |
| Kong container exits (code 0) | `kong start` is non-blocking, script exits | Added `tail -f` to keep container alive |
| Supavisor port 5432 conflict | HAProxy already binds host port 5432 | Supavisor session mode moved to host port 5435 |
| `VAULT_ENC_KEY` cipher error | Key was not exactly 32 bytes | Documented: must be exactly 32 chars (`openssl rand -hex 16`) |

---

## 9. Limitations

### Single-node etcd
- If etcd crashes, Patroni cannot perform leader election. The existing primary keeps running but no automatic failover is possible until etcd recovers.
- **Production fix:** Use a 3-node etcd cluster. Add two more etcd nodes to `ETCD_INITIAL_CLUSTER` and update Patroni configs to list all three endpoints.

### Asynchronous replication (potential data loss window)
- Default configuration uses async streaming replication. A crash between the last WAL flush on the primary and replica receipt can cause up to `maximum_lag_on_failover` (1 MB) of data loss.
- **Production fix:** Set `synchronous_mode: true` in Patroni DCS config. Adds write latency but guarantees zero data loss.

### Services reconnect on next query (brief interruption)
- GoTrue, PostgREST, Realtime, and Storage hold persistent connection pools. After failover, in-flight transactions are rolled back. Services reconnect on the next request (1–5 seconds).
- **Production fix:** Configure `keepalives_idle`, `keepalives_interval`, and `connect_timeout` in connection strings to detect dead connections faster.

### Storage volume is not replicated
- The `supabase-storage` Docker volume is local to the single host. File uploads are not replicated across nodes.
- **Production fix:** Use S3-compatible storage backend by adding `docker-compose.s3.yml` overlay, or mount an NFS/EFS volume shared across hosts.

### Single Docker host — not true multi-node HA
- All containers run on one EC2 instance. If the host itself fails, the entire stack goes down. Pod-level failure tolerance is proven; host-level is conceptual only in this setup.
- **Production fix:** Deploy on Kubernetes with pod anti-affinity rules to spread PG nodes across different physical nodes, or use separate VMs with Docker Swarm.

### HAProxy is a single point of failure
- If HAProxy crashes, all Supabase services lose DB connectivity until Docker restarts it (~5s).
- **Production fix:** Run two HAProxy instances with Keepalived (VRRP) for a floating VIP, or use an AWS Network Load Balancer in front.

### Kong requires manual keep-alive workaround
- The `kong start` command is non-blocking. The entrypoint tails `error.log` to keep the container alive. If the log file path changes in a future Kong version, the container will exit.
- **Production fix:** Use the official Supabase Kong image which handles this correctly, or switch to a Kong Helm chart on Kubernetes.

### `dos2unix` required when cloning on Windows
- Shell scripts created or edited on Windows have `\r\n` line endings which cause `bad interpreter` errors on Linux.
- **Fix:** Always run `find . -name "*.sh" -exec dos2unix {} \;` after cloning on a Linux host.
