#!/usr/bin/env bash

# Build and push images to Azure Container Registry (or any private Docker registry)
# Usage: ./scripts/build-and-push.sh [ACR_NAME] [TAG] [--cloud]
# Example: ./scripts/build-and-push.sh acrbernstein123 v1
# Example using Azure Cloud Build (no local Docker needed): ./scripts/build-and-push.sh acrbernstein123 latest --cloud

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ACR_NAME="${1:-}"
TAG="${2:-latest}"
USE_CLOUD="${3:-}"

if [ -z "$ACR_NAME" ]; then
  # Try to discover from az cli
  if command -v az > /dev/null 2>&1; then
    ACR_NAME=$(az acr list --query "[0].name" -o tsv 2>/dev/null || true)
  fi
fi

if [ -z "$ACR_NAME" ]; then
  read -r -p "Enter your ACR name (without .azurecr.io): " ACR_NAME
fi

if [ -z "$ACR_NAME" ]; then
  echo "❌ Error: ACR_NAME is required."
  exit 1
fi

ACR_LOGIN_SERVER="${ACR_NAME}.azurecr.io"
SERVICES=("poll" "worker" "result")

# Check if Docker daemon is running
DOCKER_RUNNING=true
if ! docker info > /dev/null 2>&1; then
  DOCKER_RUNNING=false
fi

if [ "$USE_CLOUD" = "--cloud" ] || [ "$DOCKER_RUNNING" = false ]; then
  echo "☁️  Building images in Azure Cloud using 'az acr build' (no local Docker required)..."
  for svc in "${SERVICES[@]}"; do
    echo "🔨 Building & pushing $svc in ACR $ACR_NAME..."
    az acr build \
      --registry "$ACR_NAME" \
      --image "$svc:$TAG" \
      --image "$svc:latest" \
      "$REPO_ROOT/app/$svc"
  done
else
  echo "🐳 Building images locally using Docker..."
  echo "🔑 Logging into ACR $ACR_NAME..."
  az acr login --name "$ACR_NAME"

  for svc in "${SERVICES[@]}"; do
    echo "🔨 Building $svc..."
    docker build -t "$ACR_LOGIN_SERVER/$svc:$TAG" -t "$ACR_LOGIN_SERVER/$svc:latest" "$REPO_ROOT/app/$svc"
    echo "⬆️ Pushing $svc to $ACR_LOGIN_SERVER..."
    docker push "$ACR_LOGIN_SERVER/$svc:$TAG"
    docker push "$ACR_LOGIN_SERVER/$svc:latest"
  done
fi

echo ""
echo "✅ All images built and pushed successfully to $ACR_LOGIN_SERVER!"

