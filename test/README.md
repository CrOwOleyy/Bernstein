# test/ — Validation Scripts

Scripts for validating deployment and operational aspects of the application.

## Zero-Downtime Validation

This test validates that updating a deployment (rolling update) does not drop any HTTP requests and maintains 100% availability.

### Usage

**Bash / Linux / WSL / Git Bash:**
```bash
./test/test-zero-downtime.sh <service-name> <namespace> [target-url]
```

Examples:
```bash
# Automatic (uses LoadBalancer External-IP or background port-forward)
./test/test-zero-downtime.sh poll bernstein-poll

# With explicit target URL (e.g. from Azure LoadBalancer)
./test/test-zero-downtime.sh poll bernstein-poll http://20.50.100.12/healthz
```

**PowerShell (Windows native):**
```powershell
.\test\test-zero-downtime.ps1 -Service poll -Namespace bernstein-poll
```

### How It Works

1. Identifies the target Deployment (`poll` or `result`) and records current replicas.
2. Resolves the service endpoint:
   - Uses the Service's Azure `LoadBalancer` external IP if available.
   - Or automatically sets up a local `kubectl port-forward` directly against the Kubernetes Service.
3. Tests initial connectivity (`/healthz`).
4. Spawns a background worker that sends HTTP requests every 500ms and logs status codes.
5. Triggers a rolling update on the deployment (`kubectl patch`).
6. Waits for rollout to complete (`kubectl rollout status`).
7. Halts the polling loop and calculates:
   - Total requests sent
   - Successful requests (HTTP 200)
   - Failed requests
   - Availability percentage
8. Asserts that 0 requests failed (`100% success rate`).
