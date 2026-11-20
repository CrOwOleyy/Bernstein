# PowerShell script to build and push images to Azure Container Registry (ACR)
# Usage: .\scripts\build-and-push.ps1 [-AcrName <name>] [-Tag <tag>] [-CloudBuild]

param(
    [string]$AcrName = "",
    [string]$Tag = "latest",
    [switch]$CloudBuild
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    try {
        $discovered = (az acr list --query "[0].name" -o tsv 2>$null).Trim()
        if (-not [string]::IsNullOrWhiteSpace($discovered)) {
            $AcrName = $discovered
        }
    } catch {}
}

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    $AcrName = Read-Host -Prompt "Enter your ACR name (without .azurecr.io)"
}

if ([string]::IsNullOrWhiteSpace($AcrName)) {
    Write-Error "ACR name is required."
    exit 1
}

$AcrLoginServer = "$AcrName.azurecr.io"
$services = @("poll", "worker", "result")

# Check if docker daemon is running
$dockerRunning = $false
try {
    $null = docker info 2>&1
    if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
} catch {}

if ($CloudBuild -or -not $dockerRunning) {
    Write-Host "Building images in Azure Cloud via 'az acr build'..." -ForegroundColor Cyan
    foreach ($svc in $services) {
        Write-Host "Building and pushing $svc in ACR $AcrName..." -ForegroundColor Yellow
        $svcPath = "$RepoRoot\app\$svc"
        az acr build --registry $AcrName --image "${svc}:${Tag}" --image "${svc}:latest" $svcPath
    }
} else {
    Write-Host "Building images locally using Docker..." -ForegroundColor Cyan
    Write-Host "Logging into ACR $AcrName..."
    az acr login --name $AcrName

    foreach ($svc in $services) {
        Write-Host "Building $svc..." -ForegroundColor Yellow
        $svcPath = "$RepoRoot\app\$svc"
        docker build -t "$AcrLoginServer/${svc}:${Tag}" -t "$AcrLoginServer/${svc}:latest" $svcPath
        Write-Host "Pushing $svc to $AcrLoginServer..." -ForegroundColor Yellow
        docker push "$AcrLoginServer/${svc}:${Tag}"
        docker push "$AcrLoginServer/${svc}:latest"
    }
}

Write-Host ""
Write-Host "[OK] All images built and pushed successfully to $AcrLoginServer!" -ForegroundColor Green
