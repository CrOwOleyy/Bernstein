#!/usr/bin/env bash

# Complete end-to-end deployment script for Bernstein Poll application on Kubernetes (AKS / Cloud / Local)
# Usage: ./scripts/deploy.sh [ACR_LOGIN_SERVER] [POSTGRES_PASSWORD] [REDIS_PASSWORD]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="bernstein-poll"

echo "=========================================================="
echo "🎻 BERNSTEIN - Orchestrate Your Symphony of Containers"
echo "=========================================================="
echo ""

# 1. Check kubectl connectivity
echo "🔍 Checking cluster connectivity..."
if ! kubectl cluster-info > /dev/null 2>&1; then
  echo "❌ Error: Cannot connect to Kubernetes cluster using kubectl."
  echo "Please configure your kubeconfig (e.g. 'az aks get-credentials --resource-group <rg> --name <cluster>')."
  exit 1
fi
echo "✅ Cluster is reachable: $(kubectl config current-context)"
echo ""

# 2. Determine ACR_LOGIN_SERVER
ACR_LOGIN_SERVER="${1:-$ACR_LOGIN_SERVER}"
if [ -z "$ACR_LOGIN_SERVER" ]; then
  # Try to discover from terraform if available
  if [ -f "$REPO_ROOT/infra/terraform/terraform.tfstate" ] && command -v terraform > /dev/null 2>&1; then
    ACR_LOGIN_SERVER=$(cd "$REPO_ROOT/infra/terraform" && terraform output -raw acr_login_server 2>/dev/null || true)
  fi
  # Try to discover from az cli
  if [ -z "$ACR_LOGIN_SERVER" ] && command -v az > /dev/null 2>&1; then
    ACR_LOGIN_SERVER=$(az acr list --query "[0].loginServer" -o tsv 2>/dev/null || true)
  fi
fi

if [ -z "$ACR_LOGIN_SERVER" ]; then
  read -r -p "Enter your ACR login server (e.g. acrbernstein123.azurecr.io): " ACR_LOGIN_SERVER
fi

if [ -z "$ACR_LOGIN_SERVER" ]; then
  echo "❌ Error: ACR_LOGIN_SERVER is required."
  exit 1
fi
echo "📦 Using Registry: $ACR_LOGIN_SERVER"

# 3. Passwords
POSTGRES_PASSWORD="${2:-$POSTGRES_PASSWORD}"
if [ -z "$POSTGRES_PASSWORD" ]; then
  read -r -s -p "Enter POSTGRES_PASSWORD (min 8 chars): " POSTGRES_PASSWORD
  echo ""
fi
if [ -z "$POSTGRES_PASSWORD" ]; then
  POSTGRES_PASSWORD="SecurePostgresPass123!"
  echo "ℹ️  Using default generated password for Postgres."
fi

REDIS_PASSWORD="${3:-$REDIS_PASSWORD}"
if [ -z "$REDIS_PASSWORD" ]; then
  read -r -s -p "Enter REDIS_PASSWORD (min 8 chars): " REDIS_PASSWORD
  echo ""
fi
if [ -z "$REDIS_PASSWORD" ]; then
  REDIS_PASSWORD="SecureRedisPassword123!"
  echo "ℹ️  Using default generated password for Redis."
fi

echo ""
echo "🚀 Starting deployment..."

# Step 1: Namespace
echo "1️⃣  Creating Namespace '$NAMESPACE'..."
kubectl apply -f "$REPO_ROOT/infra/k8s/namespace/namespace.yaml"

# Step 2: Secrets
echo "2️⃣  Configuring Secrets..."
kubectl create secret generic postgres-credentials -n "$NAMESPACE" \
  --from-literal=POSTGRES_USER=poll \
  --from-literal=POSTGRES_DB=poll \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic redis-credentials -n "$NAMESPACE" \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Backing services (Redis & PostgreSQL)
echo "3️⃣  Deploying Redis & PostgreSQL..."
kubectl apply -f "$REPO_ROOT/infra/k8s/redis/deployment.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/redis/service.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/postgres/statefulset.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/postgres/service.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/network-policies/"

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=3m

# Step 4: Schema initialization Job
echo "4️⃣  Initializing PostgreSQL database schema..."
kubectl -n "$NAMESPACE" delete job postgres-schema-init --ignore-not-found=true
kubectl apply -f "$REPO_ROOT/infra/k8s/postgres/schema-init-job.yaml"
kubectl -n "$NAMESPACE" wait --for=condition=complete job/postgres-schema-init --timeout=2m

# Step 5: Application Deployments (poll, worker, result)
echo "5️⃣  Deploying Applications (poll, worker, result)..."
for app in poll worker result; do
  echo "   - Deploying $app (image: $ACR_LOGIN_SERVER/$app:latest)..."
  sed "s#<ACR_LOGIN_SERVER>#$ACR_LOGIN_SERVER#g" "$REPO_ROOT/k8s/apps/$app/deployment.yaml" | kubectl apply -f -
done

# Step 6: Services (LoadBalancer) & HPA
echo "6️⃣  Applying Services & HPA..."
kubectl apply -f "$REPO_ROOT/k8s/apps/poll/service.yaml"
kubectl apply -f "$REPO_ROOT/k8s/apps/result/service.yaml"
kubectl apply -f "$REPO_ROOT/k8s/apps/hpa.yaml"

# Step 7: Wait for rollout
echo "⏳ Waiting for application pods to be Running & Ready..."
kubectl -n "$NAMESPACE" rollout status deployment/poll --timeout=3m
kubectl -n "$NAMESPACE" rollout status deployment/worker --timeout=3m
kubectl -n "$NAMESPACE" rollout status deployment/result --timeout=3m

echo ""
echo "=========================================================="
echo "🎉 DEPLOYMENT SUCCESSFUL!"
echo "=========================================================="
echo ""
echo "Pod status:"
kubectl get pods -n "$NAMESPACE"
echo ""

echo "Fetching external IP addresses (this may take up to 1-2 minutes on Azure)..."
POLL_IP=""
RESULT_IP=""
ATTEMPTS=0
MAX_ATTEMPTS=24

while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  POLL_IP=$(kubectl get svc poll -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  RESULT_IP=$(kubectl get svc result -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [ -n "$POLL_IP" ] && [ -n "$RESULT_IP" ]; then
    break
  fi
  echo "   ... waiting for public IPs allocation (attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS) ..."
  sleep 5
  ATTEMPTS=$((ATTEMPTS+1))
done

echo ""
echo "=========================================================="
echo "🌐 APPLICATION ACCESS URLS:"
echo "=========================================================="
if [ -n "$POLL_IP" ]; then
  echo "  🗳️  POLL (Voting Page)   : http://${POLL_IP}"
else
  echo "  🗳️  POLL (Voting Page)   : IP Pending. Check with 'kubectl get svc poll -n $NAMESPACE'"
fi

if [ -n "$RESULT_IP" ]; then
  echo "  📊 RESULT (Results Page): http://${RESULT_IP}"
else
  echo "  📊 RESULT (Results Page): IP Pending. Check with 'kubectl get svc result -n $NAMESPACE'"
fi
echo "=========================================================="

