# Bernstein — Poll App on Kubernetes

Epitech "Bernstein" project: build, push and deploy the [Poll application](app/README.md) (Flask + Redis + Java worker + PostgreSQL + Node.js) to a Kubernetes cluster, with a working no-downtime update path.

## Repo layout

```
app/            Source code + Dockerfiles for the 3 services (provided, do not restructure)
infra/          Cluster/registry provisioning + stateful backing services (Redis, PostgreSQL)
k8s/apps/       Kubernetes manifests for the stateless app services (poll, worker, result) + ingress
ci/             CI/CD pipeline: image build & push to the private registry
scripts/        Automated deployment and image build/push helper scripts
test/           Validation scripts (zero-downtime rolling update)
docs/           Architecture notes, secrets/credentials documentation, technical justification write-up
```

## Getting started

1. Read [bernstein-project.pdf](bernstein-project.pdf) (subject) and [app/README.md](app/README.md) (app contract: ports, env vars, health endpoints).
2. Provision the cluster + private registry on Azure (via Azure Portal or Terraform) — see [docs/SECRETS.md](docs/SECRETS.md).
3. Build & push images to ACR, then deploy using `./scripts/deploy.sh`.
4. Validate zero-downtime update with `./test/test-zero-downtime.sh`.

## Deploy on Azure

### 1. Build & Push images to ACR
Using the helper script (works with local Docker, or with `--cloud` using Azure Cloud Build if Docker is not running locally):
```bash
./scripts/build-and-push.sh <acr_name> latest
# Or on Windows PowerShell:
.\scripts\build-and-push.ps1 -AcrName <acr_name>
```

### 2. Deploy to AKS
Run the automated deployment script (prompts for passwords if not provided):
```bash
./scripts/deploy.sh <acr_login_server>
# Or on Windows PowerShell:
.\scripts\deploy.ps1 -AcrLoginServer <acr_login_server>
```

The script automatically:
1. Creates the `bernstein-poll` namespace.
2. Configures `postgres-credentials` and `redis-credentials` Secrets.
3. Deploys Redis, PostgreSQL, and applies NetworkPolicies.
4. Waits for PostgreSQL and runs the `postgres-schema-init` Job.
5. Deploys `poll`, `worker`, `result` with your ACR image login server.
6. Exposes `poll` and `result` with Azure `LoadBalancer` public IPs.
7. Displays the public HTTP URLs to access both applications.

### 3. Validate Zero-Downtime Rolling Update
```bash
./test/test-zero-downtime.sh poll bernstein-poll
# Or on Windows PowerShell:
.\test\test-zero-downtime.ps1 -Service poll -Namespace bernstein-poll
```

## Run locally (kind)

Prerequisites: `docker`, `kind`, `kubectl`, and a kind cluster named `bernstein` (`kind create cluster --name bernstein`).

```bash
# 1. Namespace, secrets, backing services
kubectl apply -f infra/k8s/namespace/namespace.yaml
kubectl create secret generic postgres-credentials -n bernstein-poll \
  --from-literal=POSTGRES_USER=poll --from-literal=POSTGRES_DB=poll --from-literal=POSTGRES_PASSWORD='<password>'
kubectl create secret generic redis-credentials -n bernstein-poll --from-literal=REDIS_PASSWORD='<password>'
kubectl apply -f infra/k8s/redis/deployment.yaml -f infra/k8s/redis/service.yaml
kubectl apply -f infra/k8s/postgres/statefulset.yaml -f infra/k8s/postgres/service.yaml
kubectl apply -f infra/k8s/network-policies/
kubectl apply -f infra/k8s/postgres/schema-init-job.yaml

# 2. Build the images and load them into kind
docker build -t poll:local app/poll
docker build -t worker:local app/worker
docker build -t result:local app/result
mkdir -p ~/.kind-tmp && (cd ~/.kind-tmp && docker save -o images.tar poll:local worker:local result:local \
  && kind load image-archive images.tar --name bernstein && rm images.tar)

# 3. Deploy the apps (swap the ACR placeholder for the local images)
for app in poll worker result; do
  sed "s#<ACR_LOGIN_SERVER>/$app:latest#$app:local#" k8s/apps/$app/deployment.yaml | kubectl apply -f -
done
kubectl apply -f k8s/apps/poll/service.yaml -f k8s/apps/result/service.yaml
kubectl -n bernstein-poll get pods        # wait until everything is 1/1 Running
```

Access:
```bash
kubectl -n bernstein-poll port-forward svc/poll 9080:80     # vote:    http://localhost:9080
kubectl -n bernstein-poll port-forward svc/result 8081:80   # results: http://localhost:8081
```


---
_Note: the subject PDF, course archives and audio files were left out of this public copy._
