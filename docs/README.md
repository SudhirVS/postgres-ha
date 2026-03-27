# Supabase Self-Hosted — High Availability PostgreSQL

> Tested and proven on AWS EC2 t3.xlarge (Ubuntu 22.04 LTS)
> Failover time: ~20 seconds | Zero data loss demonstrated

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Repository Structure](#2-repository-structure)
3. [Prerequisites](#3-prerequisites)
4. [Component Roles](#4-component-roles)
5. [How It Works](#5-how-it-works)
6. [Setup & Deployment](#6-setup--deployment)
7. [Failover Testing](#7-failover-testing)
8. [Monitoring & Operations](#8-monitoring--operations)
9. [Port Reference](#9-port-reference)
10. [Known Issues & Fixes Applied](#10-known-issues--fixes-applied)
11. [Limitations](#11-limitations)

---

## 1. Architecture Overview

```
                        ┌─────────────────────────────────────────────┐
                        │           Supabase Services Layer            │
                        │  Studio · Kong · Auth · REST · Realtime      │
                        │  Storage · Meta · Functions · Analytics      │
                        │  Supavisor (pooler) · Vector · imgproxy      │
                        └──────────────────┬──────────────────────────┘
                                           │ POSTGRES_HOST=haproxy
                                           ▼
                        ┌─────────────────────────────────────────────┐
                        │         HAProxy  :5432 (rw primary)          │
                        │                  :5433 (ro replicas)         │
                        │                  :7000 (stats UI)            │
                        │    Health-checks Patroni REST /primary       │
                        └──────┬──────────────┬──────────────┬────────┘
                               │              │              │
                    ┌──────────▼──┐  ┌────────▼────┐  ┌────▼────────┐
                    │ pg-primary  │  │ pg-replica-1│  │ pg-replica-2│
                    │  Patroni    │  │  Patroni    │  │  Patroni    │
                    │  PG 15      │  │  PG 15      │  │  PG 15      │
                    │  :5432      │  │  :5432      │  │  :5432      │
                    │  :8008      │  │  :8008      │  │  :8008      │
                    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘
                           └───────────────┬──────────────────┘
                                           │ leader election
                                    ┌──────▼──────┐
                                    │    etcd     │
                                    │  :2379      │
                                    └─────────────┘
```

### Proven Failover Result

| | Value |
|---|---|
| Leader before | `pg-primary` |
| Failure simulated | `docker stop ha-pg-primary` |
| Failover time | ~20 seconds |
| New leader elected | `pg-replica-2` |
| Data before failover | `before-failover` row — preserved ✅ |
| Data after failover | `after-failover` row — written successfully ✅ |
| Old primary recovery | Rejoined as replica, lag=0 ✅ |

### Failure Tolerance

| Failure Type | Handled By | Recovery Time |
|---|---|---|
| Pod/container crash | Patroni + Docker `restart: unless-stopped` | ~10–30s |
| Primary container crash | Patroni automatic failover via etcd | ~20s |
| Node failure (conceptual) | Patroni elects new leader from remaining nodes | ~20–30s |
| Supabase service crash | Docker `restart: unless-stopped` | ~5s |
| HAProxy crash | Docker `restart: unless-stopped` | ~5s |

---

## 2. Repository Structure

```
postgres-ha/                          ← repo root
├── docker-compose.yml                ← full HA stack definition (17 containers)
├── .env                              ← all secrets and configuration
│
├── patroni/                          ← Patroni configs per node
│   ├── patroni-primary.yml           ← node 1 config (includes post_bootstrap hook)
│   ├── patroni-replica-1.yml         ← node 2 config
│   └── patroni-replica-2.yml         ← node 3 config
│
├── postgres/                         ← custom PostgreSQL + Patroni Docker image
│   ├── Dockerfile                    ← builds PG 15 + Patroni + gosu
│   ├── entrypoint.sh                 ← fixes permissions, drops to postgres user, starts Patroni
│   ├── post_bootstrap.sh             ← creates Supabase roles/schemas/grants (runs once on bootstrap)
│   └── init.sql                      ← SQL executed by post_bootstrap.sh
│
├── haproxy/
│   └── haproxy.cfg                   ← routes :5432→primary, :5433→replicas via Patroni health checks
│
├── supabase/
│   └── pooler.exs                    ← Supavisor tenant config (points to haproxy:5432)
│
├── volumes/
│   ├── api/
│   │   ├── kong.yml                  ← Kong declarative config (all Supabase routes)
│   │   └── kong-entrypoint.sh        ← substitutes env vars, starts kong, tails logs
│   ├── functions/
│   │   └── main/
│   │       └── index.ts              ← Edge Functions main handler
│   └── logs/
│       └── vector.yml                ← Vector log aggregation config
│
├── scripts/
│   ├── test-failover.sh              ← automated failover test with data consistency check
│   ├── switchover.sh                 ← graceful planned switchover via patronictl
│   └── status.sh                     ← cluster health dashboard
│
└── docs/
    └── README.md                     ← this file
```

---

## 3. Prerequisites

### Host Machine

| Requirement | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 LTS | Ubuntu 22.04 LTS |
| CPU | 4 cores | 6–8 cores |
| RAM | 8 GB | 16 GB |
| Disk | 30 GB SSD | 50 GB gp3 SSD |
| Architecture | x86_64 (amd64) | x86_64 (amd64) |

> Tested on AWS EC2 `t3.xlarge` (4 vCPU / 16 GB RAM / 50 GB gp3)

### Software to Install

#### 1. Docker Engine + Compose Plugin

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
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Allow running docker without sudo
sudo usermod -aG docker $USER && newgrp docker

# Verify
docker --version          # Docker version 24.x or higher
docker compose version    # Docker Compose version v2.x or higher
```

#### 2. Git

```bash
sudo apt-get install -y git
git --version
```

#### 3. dos2unix (required — scripts are developed on Windows)

```bash
sudo apt-get install -y dos2unix
```

#### 4. Python 3 (for cluster status parsing)

```bash
# Usually pre-installed on Ubuntu 22.04
python3 --version   # 3.10+
```

#### 5. curl (for Patroni health checks)

```bash
sudo apt-get install -y curl
```

#### 6. openssl (for generating secrets)

```bash
# Usually pre-installed
openssl version
```

### AWS EC2 Security Group — Required Inbound Rules

| Port | Protocol | Purpose | Source |
|---|---|---|---|
| 22 | TCP | SSH access | Your IP |
| 8000 | TCP | Supabase Studio + API | Your IP |
| 8443 | TCP | HTTPS (optional) | Your IP |
| 7000 | TCP | HAProxy stats (optional) | Your IP |
| 5432 | TCP | PostgreSQL direct (optional) | Your IP |

> Never open ports 5432 or 7000 to `0.0.0.0/0` in production.

### Network Ports Used on Host

| Port | Service | Direction |
|---|---|---|
| 5432 | HAProxy → PostgreSQL primary (rw) | Inbound |
| 5433 | HAProxy → PostgreSQL replicas (ro) | Inbound |
| 5435 | Supavisor session mode | Inbound |
| 6543 | Supavisor transaction mode | Inbound |
| 7000 | HAProxy stats dashboard | Inbound |
| 8000 | Kong HTTP / Supabase API + Studio | Inbound |
| 8443 | Kong HTTPS | Inbound |

---

## 4. Component Roles

### etcd (`quay.io/coreos/etcd:v3.5.14`)
- Distributed key-value store for Patroni leader election
- Stores the leader lock with TTL=30s
- When lock expires, replicas compete to become the new leader
- Single node in this setup (see Limitations for production fix)

### Patroni (embedded in custom PG image)
- Manages PostgreSQL lifecycle on each node
- Exposes REST API on `:8008`:
  - `GET /primary` → HTTP 200 only on the current leader
  - `GET /replica` → HTTP 200 only on standbys
  - `GET /health`  → HTTP 200 on any healthy node
  - `GET /cluster` → full cluster JSON
- Runs `post_bootstrap.sh` once after first cluster init
- Performs `pg_rewind` on old primary after failover so it rejoins as replica

### HAProxy (`haproxy:2.9-alpine`)
- Routes `:5432` to the Patroni leader (read-write)
- Routes `:5433` to standbys round-robin (read-only)
- Uses `shutdown-sessions` — drops stale connections immediately on failover
- All Supabase services connect via `haproxy:5432`

### Supavisor (`supabase/supavisor:2.7.4`)
- Supabase connection pooler (transaction mode)
- Connects to `haproxy:5432` — follows primary automatically
- Session mode on host port `5435`, transaction mode on `6543`

### PostgreSQL Nodes (custom image: `postgres:15-bullseye` + Patroni)
- `pg-primary` — initial leader, bootstraps the cluster
- `pg-replica-1` — standby, streams WAL from primary
- `pg-replica-2` — standby, streams WAL from primary
- All three nodes are identical — any can become leader

### Supabase Services (all point to `haproxy` as DB host)
- `studio` — Supabase dashboard UI
- `kong` — API gateway routing all requests
- `auth` (GoTrue) — authentication service
- `rest` (PostgREST) — auto-generated REST API
- `realtime` — WebSocket subscriptions
- `storage` — file storage API
- `meta` (postgres-meta) — DB metadata API
- `functions` (edge-runtime) — Edge Functions
- `analytics` (Logflare) — log analytics
- `vector` — log aggregation
- `imgproxy` — image transformation
- `supavisor` — connection pooler

---

## 5. How It Works

### Normal Operation
1. `pg-primary` holds the etcd leader lock → Patroni marks it as Leader
2. `pg-replica-1` and `pg-replica-2` stream WAL from primary (lag=0)
3. HAProxy health-checks all three nodes every 3s via `GET /primary`
4. Only the leader returns HTTP 200 → HAProxy routes all writes there
5. All Supabase services connect through `haproxy:5432`

### Automatic Failover
1. Primary container crashes or is stopped
2. Patroni on replicas detects leader lock expired (TTL=30s, loop_wait=10s)
3. Replica with most up-to-date WAL wins the etcd election
4. Winner promotes itself (`pg_ctl promote`)
5. HAProxy health check on new primary returns 200 within 3s
6. HAProxy re-routes `:5432` traffic to new primary
7. Supabase services get a connection error, retry, reconnect (~1–5s)
8. Old primary restarts → Patroni runs `pg_rewind` → rejoins as replica

### Bootstrap Process (first start only)
1. `pg-primary` runs `initdb` via Patroni
2. Patroni calls `post_bootstrap.sh` which creates:
   - All Supabase roles (`supabase_admin`, `supabase_auth_admin`, `authenticator`, etc.)
   - Schemas: `auth`, `storage`, `realtime`, `extensions`, `pgbouncer`, `_realtime`
   - `_supabase` database with `_analytics` and `_supavisor` schemas
   - All required grants and search_path settings
3. Replicas clone from primary via `pg_basebackup`

---

## 6. Setup & Deployment

### Step 1 — Clone the repository

```bash
git clone <your-repo-url> ~/postgres-ha
cd ~/postgres-ha
```

### Step 2 — Fix line endings and permissions

```bash
# Required when cloning on Linux after Windows development
find . -name "*.sh"  -exec dos2unix {} \;
find . -name "*.yml" -exec dos2unix {} \;
find . -name "*.cfg" -exec dos2unix {} \;
find . -name "*.sql" -exec dos2unix {} \;
find . -name "*.exs" -exec dos2unix {} \;

chmod +x scripts/*.sh \
         postgres/entrypoint.sh \
         postgres/post_bootstrap.sh \
         volumes/api/kong-entrypoint.sh
```

### Step 3 — Generate secrets

```bash
# Run each line and copy the output into .env
echo "POSTGRES_PASSWORD=$(openssl rand -hex 20)"
echo "JWT_SECRET=$(openssl rand -hex 32)"
echo "SECRET_KEY_BASE=$(openssl rand -hex 32)"
echo "VAULT_ENC_KEY=$(openssl rand -hex 16)"         # exactly 32 chars
echo "PG_META_CRYPTO_KEY=$(openssl rand -hex 16)"    # exactly 32 chars
echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -hex 24)"
echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -hex 24)"
```

### Step 4 — Configure .env

```bash
nano .env
```

Replace every placeholder value. Key fields:

| Variable | Requirement | Example |
|---|---|---|
| `POSTGRES_PASSWORD` | Strong, min 20 chars | `openssl rand -hex 20` |
| `JWT_SECRET` | Min 32 chars | `openssl rand -hex 32` |
| `VAULT_ENC_KEY` | Exactly 32 chars | `openssl rand -hex 16` |
| `PG_META_CRYPTO_KEY` | Exactly 32 chars | `openssl rand -hex 16` |
| `SECRET_KEY_BASE` | Min 64 chars | `openssl rand -hex 32` |
| `SUPABASE_PUBLIC_URL` | Your host IP | `http://<EC2-IP>:8000` |
| `API_EXTERNAL_URL` | Your host IP | `http://<EC2-IP>:8000` |
| `SITE_URL` | Your host IP | `http://<EC2-IP>:8000` |
| `POOLER_TENANT_ID` | Any unique string | `my-ha-tenant` |
| `DASHBOARD_PASSWORD` | Strong password | any strong password |

### Step 5 — Increase system limits

```bash
echo "fs.file-max = 100000" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | sudo tee -a /etc/security/limits.conf
```

### Step 6 — Pull images

```bash
docker compose --env-file .env pull
```

### Step 7 — Build custom Patroni image

```bash
docker compose --env-file .env build
```

### Step 8 — Start the stack

```bash
docker compose --env-file .env up -d
```

First start takes 3–5 minutes. Watch bootstrap:

```bash
docker compose --env-file .env logs -f pg-primary pg-replica-1 pg-replica-2
```

Look for:
```
>>> Supabase post-bootstrap complete.
INFO: initialized a new cluster
INFO: no action. I am (pg-primary), the leader with the lock
```

### Step 9 — Apply runtime DB grants (first deployment only)

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

### Step 10 — Verify all containers are healthy

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

All 17 containers should show `Up` or `Up (healthy)`.

### Step 11 — Verify Patroni cluster

```bash
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool
```

Expected:
```json
{
  "members": [
    { "name": "pg-primary",   "role": "leader",  "state": "running",   "lag": 0 },
    { "name": "pg-replica-1", "role": "replica", "state": "streaming", "lag": 0 },
    { "name": "pg-replica-2", "role": "replica", "state": "streaming", "lag": 0 }
  ]
}
```

### Step 12 — Access Supabase Studio

```
http://<your-host-ip>:8000
```

Login: `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`

---

## 7. Failover Testing

### Automated Test

```bash
bash scripts/test-failover.sh 2>&1 | tee ~/failover-evidence.txt
```

This script:
1. Creates `ha_test` table and inserts `before-failover` row
2. Stops `ha-pg-primary` (simulates pod failure)
3. Waits 20s for Patroni to elect new leader
4. Verifies leader changed
5. Inserts `after-failover` row via new leader
6. Reads all rows — confirms both rows visible (data consistency)
7. Restarts old primary — confirms it rejoins as replica
8. Prints final cluster state

### Manual Test Steps

```bash
# 1. Check current leader
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool

# 2. Simulate failure
docker stop ha-pg-primary

# 3. Watch failover (from replica)
watch -n2 'docker exec ha-pg-replica-1 curl -s http://localhost:8008/cluster | python3 -m json.tool'

# 4. Write to new primary
docker exec ha-pg-replica-1 gosu postgres psql -U postgres -h /var/run/postgresql -d postgres \
  -c "INSERT INTO ha_test (label, ts) VALUES ('manual-test', now()) RETURNING *;"

# 5. Restore old primary
docker start ha-pg-primary

# 6. Verify full cluster
bash scripts/status.sh
```

### Graceful Switchover (zero data loss, planned maintenance)

```bash
bash scripts/switchover.sh pg-replica-1
```

---

## 8. Monitoring & Operations

### Cluster Status

```bash
bash scripts/status.sh
```

### Patroni REST API

```bash
# Full cluster JSON
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool

# Is this node the primary?
docker exec ha-pg-primary curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/primary
# 200 = yes, 503 = no

# Timeline and lag
docker exec ha-pg-replica-1 curl -s http://localhost:8008/ | python3 -m json.tool
```

### Replication Lag

```bash
docker exec ha-pg-primary gosu postgres psql -U postgres -d postgres -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn,
          (sent_lsn - replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
```

### HAProxy Stats UI

```
http://<your-host-ip>:7000
```

### Key Log Commands

```bash
# Patroni logs
docker logs ha-pg-primary -f
docker logs ha-pg-replica-1 -f

# etcd logs
docker logs ha-etcd -f

# HAProxy logs
docker logs ha-haproxy -f

# All HA infrastructure
docker compose --env-file .env logs -f etcd pg-primary pg-replica-1 pg-replica-2 haproxy

# All Supabase services
docker compose --env-file .env logs -f auth rest realtime storage kong
```

### Common Operations

```bash
# Stop entire stack (preserves data)
docker compose --env-file .env down

# Start entire stack
docker compose --env-file .env up -d

# Restart a single service
docker restart supabase-auth

# Recreate containers without losing volumes
docker compose --env-file .env up -d --force-recreate pg-primary pg-replica-1 pg-replica-2 haproxy

# Full reset — WARNING: destroys all data
docker compose --env-file .env down -v
```

---

## 9. Port Reference

| Host Port | Container | Purpose |
|---|---|---|
| 5432 | ha-haproxy | PostgreSQL primary (read-write) |
| 5433 | ha-haproxy | PostgreSQL replicas (read-only) |
| 5435 | supabase-pooler | Supavisor session mode |
| 6543 | supabase-pooler | Supavisor transaction mode |
| 7000 | ha-haproxy | HAProxy stats dashboard |
| 8000 | supabase-kong | Supabase API + Studio (HTTP) |
| 8443 | supabase-kong | Supabase API (HTTPS) |

Internal ports (not exposed to host):

| Port | Service | Purpose |
|---|---|---|
| 8008 | pg-primary/replica-1/replica-2 | Patroni REST API |
| 2379 | ha-etcd | etcd client |
| 2380 | ha-etcd | etcd peer |
| 9999 | supabase-auth | GoTrue API |
| 3000 | supabase-rest | PostgREST API |
| 4000 | supabase-realtime | Realtime WebSocket |
| 5000 | supabase-storage | Storage API |
| 8080 | supabase-meta | postgres-meta API |
| 5001 | supabase-imgproxy | Image proxy |
| 9001 | supabase-vector | Vector health |

---

## 10. Known Issues & Fixes Applied

All issues below were encountered during deployment on AWS EC2 Ubuntu 22.04 and are already fixed in the codebase.

| # | Issue | Root Cause | Fix |
|---|---|---|---|
| 1 | `bitnami/etcd:3.5` image not found | Tag doesn't exist on Docker Hub | Switched to `quay.io/coreos/etcd:v3.5.14` |
| 2 | `initdb: cannot be run as root` | Patroni ran as root inside container | `entrypoint.sh` uses `gosu postgres` to drop privileges |
| 3 | `data directory has invalid permissions` | Volume mounted with wrong mode | `entrypoint.sh` runs `chmod 700` on data dir before starting |
| 4 | `postgresql-15-pgjwt not found` | Package not in Debian apt repos | Removed from Dockerfile — not required for HA |
| 5 | `Patroni v4 users block unsupported` | Patroni v4 removed `bootstrap.users` | Replaced with `post_bootstrap` script hook |
| 6 | `schema "auth" does not exist` | Supabase schemas not created at bootstrap | `post_bootstrap.sh` creates all required schemas |
| 7 | `permission denied for schema public` | PostgreSQL 15 revokes public schema by default | Explicit `GRANT USAGE, CREATE ON SCHEMA public` added |
| 8 | `permission denied for database postgres` | Service users missing CONNECT + CREATE grants | Grants added in `post_bootstrap.sh` and Step 9 |
| 9 | `envsubst not found` in kong | Not available in kong image | Replaced with `sed` substitution in entrypoint |
| 10 | `/docker-entrypoint.sh not found` in kong | Doesn't exist in kong image | Use `kong start --conf` directly |
| 11 | Kong container exits with code 0 | `kong start` is non-blocking, script exits | Added `exec tail -f` to keep container alive |
| 12 | Supavisor port 5432 conflict | HAProxy already binds host port 5432 | Supavisor session mode moved to host port 5435 |
| 13 | `VAULT_ENC_KEY` cipher error | Key was not exactly 32 bytes | Must be exactly 32 chars — use `openssl rand -hex 16` |
| 14 | Git merge conflicts in scripts | Branch merge not resolved | Resolved in `test-failover.sh` and `kong-entrypoint.sh` |
| 15 | CRLF line endings on Linux | Scripts edited on Windows | Run `dos2unix` on all `.sh` files after cloning |
| 16 | Container mount error on restart | Project path changed between runs | Use `docker compose up --force-recreate` to rebuild containers |

---

## 11. Limitations

### Single-node etcd
- If etcd crashes, Patroni cannot perform leader election. The existing primary keeps running but no automatic failover is possible.
- **Production fix:** Use a 3-node etcd cluster. Add two more etcd nodes and list all three in `ETCD_INITIAL_CLUSTER` and Patroni's `etcd3.hosts`.

### Asynchronous replication
- Default is async streaming replication. A crash between WAL flush on primary and replica receipt can cause up to `maximum_lag_on_failover` (1 MB) of data loss.
- **Production fix:** Set `synchronous_mode: true` in Patroni DCS config. Adds write latency but guarantees zero data loss.

### Services reconnect on next query
- GoTrue, PostgREST, Realtime, and Storage hold persistent connection pools. After failover, in-flight transactions are rolled back. Services reconnect on the next request (1–5 seconds).
- **Production fix:** Configure `keepalives_idle` and `connect_timeout` in connection strings to detect dead connections faster.

### Storage volume not replicated
- The `supabase-storage` Docker volume is local to the single host. File uploads are not replicated.
- **Production fix:** Use S3-compatible storage backend or mount a shared NFS/EFS volume.

### Single Docker host — not true multi-node HA
- All containers run on one EC2 instance. If the host fails, the entire stack goes down. Pod-level failure is proven; host-level is conceptual only.
- **Production fix:** Deploy on Kubernetes with pod anti-affinity rules, or use separate VMs with Docker Swarm.

### HAProxy is a single point of failure
- If HAProxy crashes, all services lose DB connectivity until Docker restarts it (~5s).
- **Production fix:** Run two HAProxy instances with Keepalived (VRRP) for a floating VIP, or use an AWS Network Load Balancer.

### Kong keep-alive workaround
- `kong start` is non-blocking. The entrypoint tails `error.log` to keep the container alive. If the log path changes in a future Kong version, the container will exit.
- **Production fix:** Use the official Supabase Kong image or deploy Kong via Helm on Kubernetes.

### dos2unix required on Linux
- Shell scripts developed on Windows have `\r\n` line endings which cause `bad interpreter` errors on Linux.
- **Fix:** Always run `find . -name "*.sh" -exec dos2unix {} \;` after cloning on a Linux host.
