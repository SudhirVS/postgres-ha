# Supabase Self-Hosted — High Availability PostgreSQL

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [Component Roles](#2-component-roles)
3. [Directory Structure](#3-directory-structure)
4. [How It Works](#4-how-it-works)
5. [Setup & Deployment](#5-setup--deployment)
6. [Failover Testing](#6-failover-testing)
7. [Monitoring](#7-monitoring)
8. [Limitations](#8-limitations)

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
| Pod crash (any PG node) | Patroni + Docker restart | ~10–30s |
| Primary pod crash | Patroni automatic failover | ~15–30s |
| Node failure (conceptual) | Patroni elects new leader from remaining nodes | ~15–30s |
| Supabase service crash | Docker `restart: unless-stopped` | ~5s |
| HAProxy crash | Docker `restart: unless-stopped` | ~5s |

---

## 2. Component Roles

### etcd
- Single-node etcd (sufficient for local/dev HA demo; use 3-node etcd cluster in production)
- Stores Patroni cluster state, leader lock, and DCS configuration
- Patroni nodes compete for the leader lock via etcd TTL (30s)

### Patroni (runs inside each PG container)
- Manages PostgreSQL lifecycle on each node
- Holds the leader lock in etcd → only one node is primary at a time
- Exposes REST API on `:8008`:
  - `GET /primary` → HTTP 200 only on the current leader
  - `GET /replica` → HTTP 200 only on standbys
  - `GET /health`  → HTTP 200 on any healthy node
  - `GET /cluster` → full cluster JSON
- Performs `pg_rewind` on the old primary after failover so it can rejoin as replica

### HAProxy
- Listens on `:5432` (primary/rw) and `:5433` (replica/ro)
- Uses Patroni's `/primary` and `/replica` HTTP endpoints as health checks
- Automatically stops routing to a node when its health check fails
- All Supabase services use `haproxy:5432` as their `POSTGRES_HOST`
- Stats dashboard at `http://localhost:7000`

### Supavisor (Supabase connection pooler)
- Configured to connect to `haproxy:5432` (not directly to a PG node)
- Provides transaction-mode pooling for all client connections
- Automatically reconnects through HAProxy after failover

### Supabase Services
- All services (`auth`, `rest`, `realtime`, `storage`, `meta`, `analytics`, `functions`) point to `haproxy` as `POSTGRES_HOST`
- On failover, HAProxy re-routes to the new primary; services reconnect on their next query attempt
- Services with connection retry logic (GoTrue, PostgREST, Realtime) recover within seconds

---

## 3. Directory Structure

```
ha/
├── .env                          # All secrets and config (copy from .env.example)
├── docker-compose.yml            # Full HA stack definition
├── patroni/
│   ├── patroni-primary.yml       # Patroni config for node 1
│   ├── patroni-replica-1.yml     # Patroni config for node 2
│   └── patroni-replica-2.yml     # Patroni config for node 3
├── postgres/
│   ├── Dockerfile                # PG 15 + Patroni image
│   ├── entrypoint.sh             # Substitutes env vars, starts Patroni
│   └── init.sql                  # Supabase roles, schemas, extensions
├── haproxy/
│   └── haproxy.cfg               # HAProxy routing rules
├── supabase/
│   └── pooler.exs                # Supavisor tenant config (points to haproxy)
├── scripts/
│   ├── test-failover.sh          # Automated failover test
│   ├── switchover.sh             # Graceful planned switchover
│   └── status.sh                 # Cluster health check
└── docs/
    └── README.md                 # This file
```

---

## 4. How It Works

### Normal Operation
1. `pg-primary` holds the etcd leader lock → Patroni marks it as Leader
2. `pg-replica-1` and `pg-replica-2` stream WAL from the primary
3. HAProxy health-checks all three nodes every 3s via `GET /primary`
4. Only `pg-primary` returns HTTP 200 → HAProxy routes all writes there
5. All Supabase services connect through HAProxy → reach the primary

### Automatic Failover (pod/node failure)
1. `pg-primary` container crashes or becomes unreachable
2. Patroni on replicas detects the leader lock has expired (TTL = 30s)
3. The replica with the most up-to-date WAL wins the etcd election
4. Winner promotes itself to primary (`pg_ctl promote`)
5. HAProxy health check on the new primary starts returning 200
6. HAProxy re-routes `:5432` traffic to the new primary (~3s after promotion)
7. Supabase services get a connection error on their next query, retry, and reconnect through HAProxy to the new primary
8. When the old primary restarts, Patroni runs `pg_rewind` to sync it and it rejoins as a replica

### Data Consistency
- PostgreSQL streaming replication is synchronous by default in Patroni's `use_pg_rewind: true` mode
- `maximum_lag_on_failover: 1048576` (1 MB) — Patroni will not promote a replica that is more than 1 MB behind
- `wal_log_hints: on` — required for `pg_rewind` to work correctly
- `data-checksums` enabled at initdb — detects data corruption

---

## 5. Setup & Deployment

### Prerequisites
- Docker Desktop (Windows/Mac) or Docker Engine + Compose plugin (Linux)
- At least 4 GB RAM available for Docker
- Ports 5432, 5433, 6543, 7000, 8000, 8443 free on the host

### Step 1 — Configure secrets

```bash
cd ha/
cp .env .env.local   # optional: keep a local copy
```

Edit `.env` and change **all** placeholder values:
- `POSTGRES_PASSWORD` — strong password, used by all PG users
- `JWT_SECRET` — at least 32 characters
- `ANON_KEY` / `SERVICE_ROLE_KEY` — generate with `sh ../supabse/supabase/docker/utils/generate-keys.sh`
- `SECRET_KEY_BASE`, `VAULT_ENC_KEY`, `PG_META_CRYPTO_KEY` — 32+ char random strings
- `LOGFLARE_PUBLIC_ACCESS_TOKEN`, `LOGFLARE_PRIVATE_ACCESS_TOKEN`
- `DASHBOARD_USERNAME`, `DASHBOARD_PASSWORD`

### Step 2 — Build and start

```bash
cd ha/
docker compose --env-file .env up -d --build
```

First start takes 3–5 minutes (builds the Patroni image, bootstraps the cluster).

### Step 3 — Verify cluster health

```bash
bash scripts/status.sh
```

Expected output:
```
── Patroni Cluster ──
  pg-primary           role=Leader      state=running    timeline=1  lag=0
  pg-replica-1         role=Replica     state=streaming  timeline=1  lag=0
  pg-replica-2         role=Replica     state=streaming  timeline=1  lag=0
```

### Step 4 — Access Supabase Studio

Open `http://<your-host-ip>:8000` in your browser.
Login with `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`.

For AWS EC2, replace `<your-host-ip>` with your instance's public IP and ensure port `8000` is open in the Security Group.

---

## 6. Failover Testing

### Automated Test (recommended)

```bash
bash scripts/test-failover.sh
```

This script:
1. Creates a `ha_test` table and inserts a row ("before-failover")
2. Stops the `ha-pg-primary` container (simulates pod failure)
3. Waits 15s for Patroni to elect a new leader
4. Verifies the leader changed
5. Inserts another row ("after-failover") through HAProxy to the new primary
6. Reads all rows to confirm data consistency
7. Restarts the old primary (it rejoins as replica)
8. Prints final cluster state

### Manual Test Steps

**1. Check current leader:**
```bash
docker exec ha-pg-primary curl -s http://localhost:8008/cluster | python3 -m json.tool
```

**2. Simulate primary failure:**
```bash
docker stop ha-pg-primary
```

**3. Watch failover happen (from replica):**
```bash
watch -n2 'docker exec ha-pg-replica-1 curl -s http://localhost:8008/cluster | python3 -m json.tool'
```

**4. Verify writes still work through HAProxy:**
```bash
PGPASSWORD=<your-password> psql -h localhost -p 5432 -U postgres -d postgres \
  -c "INSERT INTO ha_test (label, ts) VALUES ('manual-test', now()) RETURNING *;"
```

**5. Restore old primary:**
```bash
docker start ha-pg-primary
# Patroni will run pg_rewind and rejoin it as replica
```

**6. Verify full cluster restored:**
```bash
bash scripts/status.sh
```

### Graceful Switchover (planned maintenance)

```bash
bash scripts/switchover.sh pg-replica-1
```

This uses `patronictl switchover` — zero data loss, graceful handoff.

### HAProxy Stats

Open `http://<your-host-ip>:7000` to see real-time backend health, connection counts, and which node is active.

---

## 7. Monitoring

### Patroni REST API endpoints

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
# Patroni logs on primary
docker logs ha-pg-primary -f

# HAProxy logs
docker logs ha-haproxy -f

# etcd logs
docker logs ha-etcd -f

# All HA infrastructure logs
docker compose -f ha/docker-compose.yml logs -f etcd pg-primary pg-replica-1 pg-replica-2 haproxy
```

---

## 8. Limitations

### Single-node etcd
- This setup uses a single etcd node. If etcd crashes, Patroni cannot perform leader election (existing primary keeps running but no failover is possible).
- **Production fix:** Use a 3-node etcd cluster with `ETCD_INITIAL_CLUSTER` listing all three nodes.

### No synchronous replication
- Default configuration uses asynchronous streaming replication.
- In the window between the last WAL flush on the primary and the replica receiving it, a crash can cause up to `maximum_lag_on_failover` (1 MB) of data loss.
- **Production fix:** Set `synchronous_mode: true` in Patroni DCS config and `synchronous_standby_names = '*'` in PostgreSQL parameters. This adds write latency but guarantees zero data loss.

### Supabase services reconnect on next query
- Services like PostgREST, GoTrue, and Realtime hold persistent connection pools. After failover, in-flight transactions are rolled back and the service reconnects on the next request.
- Typical reconnect time: 1–5 seconds depending on the service's retry logic.
- **Production fix:** Configure shorter `connect_timeout` and `keepalives_idle` in connection strings; use Supavisor's built-in reconnect logic.

### Storage is not replicated
- The `supabase-storage` volume is local to the Docker host. It is not replicated across nodes.
- **Production fix:** Use S3-compatible storage backend (`docker-compose.s3.yml` from the official repo) or a shared NFS/EFS volume.

### No cross-host node failure
- This setup runs all containers on a single Docker host. True node-level failure tolerance requires running each PG container on a separate physical/virtual machine (e.g., Kubernetes with pod anti-affinity, or separate VMs with Docker Swarm).
- **Production fix:** Deploy on Kubernetes using the Patroni Helm chart or the CloudNativePG operator, with pod anti-affinity rules to spread replicas across nodes.

### HAProxy is a single point of failure
- If HAProxy crashes, all Supabase services lose DB connectivity until Docker restarts it (~5s with `restart: unless-stopped`).
- **Production fix:** Run two HAProxy instances behind a virtual IP using Keepalived (VRRP), or use a cloud load balancer (AWS NLB, GCP TCP LB).

### etcd data loss on volume removal
- `docker compose down -v` removes the etcd volume, destroying cluster state. Patroni will re-bootstrap from scratch.
- Always use `docker compose down` (without `-v`) to preserve data.
