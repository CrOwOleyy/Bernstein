#!/usr/bin/env bash

# Test zero-downtime rolling updates by sending continuous requests to the Service endpoint.
# Usage: ./test-zero-downtime.sh <service-name> <namespace> [target-url]
# Example: ./test-zero-downtime.sh poll bernstein-poll
# Example with explicit URL: ./test-zero-downtime.sh poll bernstein-poll http://20.50.100.12

set -e

SERVICE="${1:-poll}"
NAMESPACE="${2:-bernstein-poll}"
CUSTOM_URL="${3:-}"

if [ -z "$SERVICE" ] || [ -z "$NAMESPACE" ]; then
  echo "Usage: $0 <service-name> <namespace> [target-url]"
  exit 1
fi

echo "=========================================================="
echo "🚀 Testing zero-downtime rolling update for $SERVICE in $NAMESPACE"
echo "=========================================================="
echo ""

DEPLOYMENT="$SERVICE"

# Verify deployment exists
if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" > /dev/null 2>&1; then
  echo "❌ Error: Deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'"
  exit 1
fi

CURRENT_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
REPLICAS=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
echo "📦 Current image: $CURRENT_IMAGE"
echo "👥 Configured replicas: $REPLICAS"

PF_PID=""
cleanup() {
  if [ -n "$REQUEST_PID" ]; then
    kill "$REQUEST_PID" 2>/dev/null || true
  fi
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$REQUESTS_FILE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Determine endpoint URL
if [ -n "$CUSTOM_URL" ]; then
  ENDPOINT_URL="$CUSTOM_URL"
  echo "🔗 Using specified endpoint: $ENDPOINT_URL"
else
  # Check if Service has LoadBalancer IP
  EXTERNAL_IP=$(kubectl get svc "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$EXTERNAL_IP" ]; then
    ENDPOINT_URL="http://${EXTERNAL_IP}/healthz"
    echo "🔗 Found LoadBalancer External IP: $EXTERNAL_IP"
    echo "🔗 Testing against: $ENDPOINT_URL"
  else
    # Fallback to local port-forward against the Kubernetes Service
    PORT=$((18000 + RANDOM % 1000))
    echo "ℹ️  No LoadBalancer IP found or resolving. Starting port-forward to svc/$SERVICE on port $PORT..."
    kubectl port-forward "svc/$SERVICE" "$PORT:80" -n "$NAMESPACE" > /dev/null 2>&1 &
    PF_PID=$!
    sleep 3
    ENDPOINT_URL="http://127.0.0.1:${PORT}/healthz"
    echo "🔗 Port-forward established. Testing against: $ENDPOINT_URL"
  fi
fi

# Verify initial connectivity
echo "🔍 Checking initial endpoint connectivity..."
if ! curl -s -f -m 3 "$ENDPOINT_URL" > /dev/null 2>&1; then
  echo "⚠️ Initial request failed. Retrying in 2s..."
  sleep 2
  if ! curl -s -f -m 3 "$ENDPOINT_URL" > /dev/null 2>&1; then
    echo "❌ Cannot connect to $ENDPOINT_URL before update. Aborting test."
    exit 1
  fi
fi
echo "✅ Endpoint is healthy and reachable."
echo ""

REQUESTS_FILE="/tmp/${SERVICE}-requests-$$.log"
rm -f "$REQUESTS_FILE"

# Start background continuous polling
echo "📊 Starting continuous requests (every 0.3s)..."
(
  while true; do
    TIMESTAMP=$(date +'%H:%M:%S.%3N')
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 4 "$ENDPOINT_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
      echo "$TIMESTAMP 200 SUCCESS" >> "$REQUESTS_FILE"
    else
      echo "$TIMESTAMP $HTTP_CODE FAILED" >> "$REQUESTS_FILE"
    fi
    sleep 0.3
  done
) &
REQUEST_PID=$!

sleep 2

# Trigger rolling update
echo "🔄 Triggering rolling update on deployment/$DEPLOYMENT..."
kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"}}}}}"

echo "⏳ Waiting for rollout to complete..."
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=5m

# Stop continuous requests
kill "$REQUEST_PID" 2>/dev/null || true
REQUEST_PID=""
sleep 1

# Analyze results
echo ""
echo "=========================================================="
echo "📈 TEST RESULTS"
echo "=========================================================="

if [ -f "$REQUESTS_FILE" ]; then
  SUCCESSFUL=$(grep -c "SUCCESS" "$REQUESTS_FILE" || true)
  FAILED=$(grep -c "FAILED" "$REQUESTS_FILE" || true)
  TOTAL=$((SUCCESSFUL + FAILED))

  if [ "$TOTAL" -gt 0 ]; then
    SUCCESS_RATE=$((SUCCESSFUL * 100 / TOTAL))
    echo "  Total requests sent : $TOTAL"
    echo "  Successful (HTTP 200): $SUCCESSFUL"
    echo "  Failed requests      : $FAILED"
    echo "  Availability rate    : ${SUCCESS_RATE}%"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
      echo "✅ SUCCESS: ZERO DOWNTIME CONFIRMED! 0 requests failed during the rolling update."
    else
      echo "❌ DOWNTIME DETECTED: $FAILED requests failed during the rollout!"
      echo "Failed samples:"
      grep "FAILED" "$REQUESTS_FILE" | head -n 5
      exit 1
    fi
  else
    echo "⚠️ No requests recorded."
    exit 1
  fi
else
  echo "⚠️ Log file not found."
  exit 1
fi

echo ""
NEW_IMAGE=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "🎯 Active image after rollout: $NEW_IMAGE"
echo "=========================================================="
