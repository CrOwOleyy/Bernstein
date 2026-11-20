# Bernstein Architecture & Technical Choices Justification

This document details the architectural decisions, design choices, security configurations, and defense justifications for the Bernstein Poll application deployed on Kubernetes (Azure AKS).

---

## 1. High-Level Architecture & Data Flow

```
[ Voter ]                     [ Audience / Evaluator ]
    │                                    │
    ▼                                    ▼
[ Poll Web App ]                 [ Result Web App ]
(Flask / Gunicorn)             (Node.js / Socket.IO)
    │                                    ▲
    │ (RPUSH votes)                      │ (SELECT query)
    ▼                                    │
[ Redis Queue ] ──(BLPOP votes)──> [ Java Worker ] ──(UPSERT)──> [ PostgreSQL DB ]
```

* **Poll** (Python 3.14 / Flask + Gunicorn, Port 80): Stateless voting interface. Pushes voter uuid and choice into Redis list `votes`. Exposes `/healthz` and `/readyz` (Redis ping).
* **Redis** (Redis 8 Alpine, Port 6379): Fast in-memory buffer queue. Holds incoming votes awaiting consumption by the Worker.
* **Worker** (Java 25, Port 80 for health checks): Background consumer service. Continuously pulls votes from Redis via blocking pop (`BLPOP`) and upserts them into PostgreSQL (`INSERT ... ON CONFLICT (id) DO UPDATE`).
* **PostgreSQL** (PostgreSQL 18 Alpine, Port 5432): Single source of truth. Stores persistent vote records (`id text PRIMARY KEY, vote text NOT NULL`).
* **Result** (Node.js 24 / Express + Socket.IO, Port 80): Real-time live scoreboard. Polls database tallies every second and broadcasts live score updates to connected web browsers over WebSockets.

---

## 2. Technical Decisions & Justifications

### 2.1 State Management: StatefulSet vs Deployment
* **PostgreSQL uses a `StatefulSet`:**
  * **Why not a Deployment?** Deployments are designed for interchangeable, stateless pods. If two Postgres replicas accidentally run against the same disk, database corruption occurs.
  * `StatefulSet` guarantees:
    1. A stable network identity (`postgres-0.postgres.bernstein-poll.svc.cluster.local`).
    2. A dedicated, persistent volume bound via `volumeClaimTemplates` to Azure Managed Disk (`managed-csi`). Even if the pod is rescheduled or deleted, the data volume is never orphaned or deleted.
    3. Strict single-writer semantics (ordered creation/deletion, single active replica).
* **Redis uses a `Deployment` with single replica:**
  * Redis acts solely as an ephemeral FIFO queue between Poll and Worker. Per the project specifications, Redis does not require persistent disk storage.
  * A single replica (`replicas: 1`) with `strategy: Recreate` prevents split-brain queues (multiple Redis replicas without clustering would create independent queues that cause lost votes).

### 2.2 Replicas & High Availability
* **Poll (2 Replicas):** Web-facing frontend. Multiple replicas provide load balancing across cluster nodes and ensure high availability during traffic spikes.
* **Worker (2 Replicas):** Java background consumers. Multiple workers consume from the shared Redis queue concurrently without conflict thanks to atomic `BLPOP` operations.
* **Result (2 Replicas):** Read-only web frontend. Multiple replicas distribute WebSocket client connections.

### 2.3 RollingUpdate Strategy & Zero-Downtime
All stateless services (`poll`, `worker`, `result`) use:
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```
* **`maxUnavailable: 0`:** Guarantees that the number of active, ready pods never drops below the desired replica count (2).
* **`maxSurge: 1`:** Allows Kubernetes to spin up 1 temporary extra pod (3 total) during the rollout.
* **Rollout sequence:**
  1. Kubernetes creates a new pod with the updated image.
  2. The new pod must pass both its `livenessProbe` and `readinessProbe`.
  3. Only once the new pod is `Ready` does Kubernetes begin terminating an old pod.
  4. Repeat until all pods run the new version.

### 2.4 Graceful Termination (`preStop` Hook)
To prevent dropped connections during rolling updates:
```yaml
lifecycle:
  preStop:
    exec:
      command: ["/bin/sleep", "5"]
```
* **Why this is critical:** When a pod is deleted, Kubernetes sends `SIGTERM` while simultaneously updating endpoints in `kube-proxy` across all cluster nodes. In cloud environments like Azure, routing tables take 1 to 2 seconds to propagate.
* Without `preStop`, Gunicorn or Node.js shuts down immediately upon receiving `SIGTERM`, causing in-flight requests to receive `Connection Refused` or `TCP RST`.
* With `preStop sleep 5`, the pod is removed from endpoints first, stops receiving new traffic, finishes handling ongoing requests, and only then exits cleanly.

### 2.5 Multi-threading in Gunicorn
* Gunicorn is launched with `--workers 2 --threads 4` (instead of default 1 worker).
* This allows concurrent handling of voter traffic and health probe requests simultaneously without socket starvation.

### 2.6 Least-Privilege Network Policies
NetworkPolicies enforce zero-trust network isolation within the namespace:
* **Redis (`redis-allow-poll-worker`):** Only pods with label `app: poll` (writes) and `app: worker` (reads) can connect on port 6379. All other pods (including Result) are blocked.
* **PostgreSQL (`postgres-allow-worker-result`):** Only pods with label `app: worker`, `app: result`, and `app: postgres-schema-init` can connect on port 5432. Poll has zero access to PostgreSQL.

### 2.7 Autoscaling (HPA)
`k8s/apps/hpa.yaml` defines Horizontal Pod Autoscalers for `poll` and `result`:
* Min replicas: 2 | Max replicas: 5.
* Target: 70% average CPU utilization.
* Automatically scales up during traffic surges and scales down during quiet periods to optimize cloud compute costs.

### 2.8 External Exposure
* **`type: LoadBalancer`:** Configured on `poll` and `result` services.
* On Azure AKS, this provisions standard Azure Public IPs with health-checked load balancer rules on port 80.
* Direct public IPs eliminate dependencies on custom domain names or extra ingress controllers, satisfying the defense evaluation criteria directly.

---

## 3. Defense Questions & Answers (Technical Mastery)

### Q1: What will happen if we execute `kubectl drain` on a node?
* **Stateless pods (`poll`, `result`, `worker`):**
  * Because replicas are distributed across nodes and `maxUnavailable: 0`, when a node is drained, Kubernetes cordons the node (marks it unschedulable) and evicts pods.
  * The ReplicaSet immediately recreates replacement pods on the surviving node. Users experience **zero downtime**.
* **Stateful pod (`postgres-0`):**
  * PostgreSQL will terminate gracefully.
  * The underlying Azure Managed Disk (`managed-csi`) is detached from the drained node and re-attached to the active node (~30 to 60 seconds).
  * During this short failover:
    * `poll` continues to accept votes and buffer them in Redis. **No votes are lost!**
    * Once `postgres-0` becomes ready on the new node, `worker` resumes draining the Redis queue and upserting into the database.

### Q2: How would we limit the processing power of Redis?
1. **Kubernetes Resource Limits (cgroups):**
   In `infra/k8s/redis/deployment.yaml`:
   ```yaml
   resources:
     limits:
       cpu: "200m"      # 20% of 1 CPU core via Linux CFS quota
       memory: "128Mi"  # 128 MB max memory
   ```
2. **Redis Application-Level Limits:**
   In container args:
   ```yaml
   args: ["--maxmemory", "96mb", "--maxmemory-policy", "noeviction"]
   ```
   * `--maxmemory 96mb`: Restricts Redis cache size.
   * `--maxmemory-policy noeviction`: If the queue reaches 96 MB, Redis rejects new write commands with an error rather than silently deleting unconsumed votes.

### Q3: What is your PostgreSQL persistence and backup strategy?
* **Persistence:** Azure Disk CSI (`managed-csi`) with `ReadWriteOnce` access mode. The storage volume lifecycle is independent of the container lifecycle.
* **Backup Strategy in Production:**
  1. *CSI VolumeSnapshots:* Automate volume-level snapshots via Kubernetes `VolumeSnapshot` objects with daily retention.
  2. *Logical Backups:* Run a scheduled Kubernetes `CronJob` executing `pg_dump` and streaming compressed backups to an Azure Blob Storage container with geo-redundancy.

### Q4: Why is there an init Job for the schema instead of running it in the worker or database?
* Running `schema.sql` inside the PostgreSQL container entrypoint only works on initial empty directories (fails on persistent volume re-attachments).
* Running schema creation in the application creates race conditions when multiple worker replicas boot simultaneously.
* A dedicated Kubernetes `Job` (`postgres-schema-init`) runs idempotently (`CREATE TABLE IF NOT EXISTS`), verifies database readiness with `pg_isready`, and completes cleanly before the application layer takes traffic.
