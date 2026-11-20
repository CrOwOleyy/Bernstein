# PowerShell end-to-end deployment script for Bernstein Poll application on Kubernetes (AKS / Cloud / Local)
# Usage: .\scripts\deploy.ps1 [-AcrLoginServer <server>] [-PostgresPassword <pwd>] [-RedisPassword <pwd>]

param(
    [string]$AcrLoginServer = "",
    [string]$PostgresPassword = "",
    [string]$RedisPassword = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$Namespace = "bernstein-poll"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "BERNSTEIN - Orchestrate Your Symphony of Containers" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Check kubectl connectivity
Write-Host "[1/7] Checking cluster connectivity..."
$oldEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$clusterInfoOut = kubectl cluster-info 2>&1
$k8sExit = $LASTEXITCODE
$ErrorActionPreference = $oldEAP

if ($k8sExit -ne 0) {
    Write-Error "Cannot connect to Kubernetes cluster using kubectl. Please verify that the cluster is running (az aks start) and run 'az aks get-credentials --resource-group <rg> --name <cluster>'."
    exit 1
}
$currentCtx = (kubectl config current-context).Trim()
Write-Host "[OK] Cluster is reachable: $currentCtx" -ForegroundColor Green
Write-Host ""

# 2. Determine ACR_LOGIN_SERVER
if ([string]::IsNullOrWhiteSpace($AcrLoginServer)) {
    if ($env:ACR_LOGIN_SERVER) {
        $AcrLoginServer = $env:ACR_LOGIN_SERVER
    } else {
        # Try az cli
        try {
            $azAcr = (az acr list --query "[0].loginServer" -o tsv 2>$null).Trim()
            if (-not [string]::IsNullOrWhiteSpace($azAcr)) {
                $AcrLoginServer = $azAcr
            }
        } catch {}
    }
}

if ([string]::IsNullOrWhiteSpace($AcrLoginServer)) {
    $AcrLoginServer = Read-Host -Prompt "Enter your ACR login server"
}

if ([string]::IsNullOrWhiteSpace($AcrLoginServer)) {
    Write-Error "ACR login server is required."
    exit 1
}
Write-Host "Using Registry: $AcrLoginServer" -ForegroundColor Yellow

# 3. Passwords
if ([string]::IsNullOrWhiteSpace($PostgresPassword)) {
    if ($env:POSTGRES_PASSWORD) {
        $PostgresPassword = $env:POSTGRES_PASSWORD
    } else {
        $PostgresPassword = Read-Host -Prompt "Enter POSTGRES_PASSWORD"
        if ([string]::IsNullOrWhiteSpace($PostgresPassword)) {
            $PostgresPassword = "SecurePostgresPass123!"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RedisPassword)) {
    if ($env:REDIS_PASSWORD) {
        $RedisPassword = $env:REDIS_PASSWORD
    } else {
        $RedisPassword = Read-Host -Prompt "Enter REDIS_PASSWORD"
        if ([string]::IsNullOrWhiteSpace($RedisPassword)) {
            $RedisPassword = "SecureRedisPassword123!"
        }
    }
}

Write-Host ""
Write-Host "Starting deployment..." -ForegroundColor Cyan

# Step 1: Namespace
Write-Host "[2/7] Creating Namespace '$Namespace'..."
kubectl apply -f "$RepoRoot\infra\k8s\namespace\namespace.yaml"

# Step 2: Secrets
Write-Host "[3/7] Configuring Secrets..."
kubectl create secret generic postgres-credentials -n $Namespace `
  --from-literal="POSTGRES_USER=poll" `
  --from-literal="POSTGRES_DB=poll" `
  --from-literal="POSTGRES_PASSWORD=$PostgresPassword" `
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic redis-credentials -n $Namespace `
  --from-literal="REDIS_PASSWORD=$RedisPassword" `
  --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Backing services
Write-Host "[4/7] Deploying Redis & PostgreSQL..."
kubectl apply -f "$RepoRoot\infra\k8s\redis\deployment.yaml"
kubectl apply -f "$RepoRoot\infra\k8s\redis\service.yaml"
kubectl apply -f "$RepoRoot\infra\k8s\postgres\statefulset.yaml"
kubectl apply -f "$RepoRoot\infra\k8s\postgres\service.yaml"
kubectl apply -f "$RepoRoot\infra\k8s\network-policies"

Write-Host "Waiting for PostgreSQL to be ready..."
kubectl -n $Namespace rollout status statefulset/postgres --timeout=3m

# Step 4: Schema init Job
Write-Host "[5/7] Initializing PostgreSQL database schema..."
kubectl -n $Namespace delete job postgres-schema-init --ignore-not-found=true
kubectl apply -f "$RepoRoot\infra\k8s\postgres\schema-init-job.yaml"
kubectl -n $Namespace wait --for=condition=complete job/postgres-schema-init --timeout=2m

# Step 5: Application Deployments
Write-Host "[6/7] Deploying Applications (poll, worker, result)..."
foreach ($app in @("poll", "worker", "result")) {
    Write-Host "   - Deploying $app (image: $($AcrLoginServer)/$($app):latest)..."
    $rawYaml = Get-Content "$RepoRoot\k8s\apps\$app\deployment.yaml" -Raw
    $substituted = $rawYaml -replace '<ACR_LOGIN_SERVER>', $AcrLoginServer
    $substituted | kubectl apply -f -
}

# Step 6: Services
Write-Host "[7/7] Applying Services (LoadBalancer) & HPA..."
kubectl apply -f "$RepoRoot\k8s\apps\poll\service.yaml"
kubectl apply -f "$RepoRoot\k8s\apps\result\service.yaml"
kubectl apply -f "$RepoRoot\k8s\apps\hpa.yaml"

# Step 7: Wait for rollout
Write-Host "Waiting for application pods to be Running & Ready..."
kubectl -n $Namespace rollout status deployment/poll --timeout=3m
kubectl -n $Namespace rollout status deployment/worker --timeout=3m
kubectl -n $Namespace rollout status deployment/result --timeout=3m

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "DEPLOYMENT SUCCESSFUL!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Fetching external IP addresses (this may take up to 1-2 minutes on Azure)..."
$pollIp = ""
$resultIp = ""
$attempts = 0
$maxAttempts = 24

while ($attempts -lt $maxAttempts) {
    $pollIp = ((kubectl get svc poll -n $Namespace -o "jsonpath={.status.loadBalancer.ingress[0].ip}" 2>$null) | Out-String).Trim()
    $resultIp = ((kubectl get svc result -n $Namespace -o "jsonpath={.status.loadBalancer.ingress[0].ip}" 2>$null) | Out-String).Trim()

    if ($pollIp -ne "" -and $resultIp -ne "") {
        break
    }
    Write-Host "   ... waiting for public IPs allocation (attempt $($attempts + 1)/$maxAttempts) ..."
    Start-Sleep -Seconds 5
    $attempts++
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "APPLICATION ACCESS URLS:" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
if ($pollIp -ne "") {
    Write-Host "  POLL [Voting Page]    : http://${pollIp}" -ForegroundColor Green
} else {
    Write-Host "  POLL [Voting Page]    : IP Pending. Check with 'kubectl get svc poll -n $Namespace'" -ForegroundColor Yellow
}

if ($resultIp -ne "") {
    Write-Host "  RESULT [Results Page]  : http://${resultIp}" -ForegroundColor Green
} else {
    Write-Host "  RESULT [Results Page]  : IP Pending. Check with 'kubectl get svc result -n $Namespace'" -ForegroundColor Yellow
}
Write-Host "==========================================================" -ForegroundColor Cyan
