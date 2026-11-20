# Test zero-downtime rolling updates in PowerShell
# Usage: .\test\test-zero-downtime.ps1 [-Service poll] [-Namespace bernstein-poll] [-CustomUrl "http://..."]

param(
    [string]$Service = "poll",
    [string]$Namespace = "bernstein-poll",
    [string]$CustomUrl = ""
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "[+] Testing zero-downtime rolling update for $Service in $Namespace" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Verify deployment exists
$null = kubectl get deployment $Service -n $Namespace 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment '$Service' not found in namespace '$Namespace'."
    exit 1
}

$currentImage = ((kubectl get deployment $Service -n $Namespace -o "jsonpath={.spec.template.spec.containers[0].image}") | Out-String).Trim()
$replicas = ((kubectl get deployment $Service -n $Namespace -o "jsonpath={.spec.replicas}") | Out-String).Trim()
Write-Host "Current image: $currentImage"
Write-Host "Configured replicas: $replicas"

$pfProcess = $null
$endpointUrl = ""

try {
    if ($CustomUrl -ne "") {
        $endpointUrl = $CustomUrl
    } else {
        $extIp = ((kubectl get svc $Service -n $Namespace -o "jsonpath={.status.loadBalancer.ingress[0].ip}" 2>$null) | Out-String).Trim()
        if ($extIp -ne "") {
            $endpointUrl = "http://${extIp}/healthz"
            Write-Host "Found LoadBalancer External IP: $extIp"
        } else {
            $port = Get-Random -Minimum 18000 -Maximum 19000
            Write-Host "Starting background port-forward to svc/$Service on port $port..."
            $pfProcess = Start-Process -FilePath "kubectl" -ArgumentList "port-forward", "svc/$Service", "${port}:80", "-n", $Namespace -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 3
            $endpointUrl = "http://127.0.0.1:${port}/healthz"
        }
    }

    Write-Host "Target endpoint: $endpointUrl"
    Write-Host "Testing initial connectivity..."
    try {
        $testReq = Invoke-WebRequest -Uri $endpointUrl -UseBasicParsing -TimeoutSec 10
        if ($testReq.StatusCode -ne 200) { throw "Status $($testReq.StatusCode)" }
    } catch {
        Write-Error "Cannot reach $endpointUrl before rollout: $_"
        exit 1
    }
    Write-Host "[OK] Initial connectivity verified." -ForegroundColor Green

    $jobScript = {
        param($url)
        while ($true) {
            $ts = Get-Date -Format "HH:mm:ss.fff"
            try {
                $req = [System.Net.WebRequest]::Create($url)
                $req.Timeout = 4000
                $resp = $req.GetResponse()
                $status = [int]($resp.StatusCode)
                $resp.Close()
                [PSCustomObject]@{ Time=$ts; Status=$status; Success=($status -eq 200); Error="" }
            } catch {
                [PSCustomObject]@{ Time=$ts; Status=0; Success=$false; Error=$_.Exception.Message }
            }
            Start-Sleep -Milliseconds 400
        }
    }

    Write-Host "Starting continuous background polling..."
    $pollJob = Start-Job -ScriptBlock $jobScript -ArgumentList $endpointUrl
    Start-Sleep -Seconds 2

    Write-Host "Triggering rolling update via 'kubectl rollout restart'..."
    kubectl rollout restart deployment/$Service -n $Namespace

    Write-Host "Waiting for rollout to complete..."
    kubectl rollout status deployment/$Service -n $Namespace --timeout=5m

    Write-Host "Stopping polling..."
    Stop-Job $pollJob
    $results = Receive-Job $pollJob
    Remove-Job $pollJob -Force

    $total = 0
    $successful = 0
    $failed = 0

    if ($results) {
        $total = $results.Count
        $successful = ($results | Where-Object { $_.Success -eq $true }).Count
        $failed = $total - $successful
    }

    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "TEST RESULTS" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  Total requests sent : $total"
    Write-Host "  Successful (HTTP 200): $successful" -ForegroundColor Green
    Write-Host "  Failed requests      : $failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })

    if ($failed -gt 0) {
        Write-Host "Sample failure errors:"
        $results | Where-Object { $_.Success -eq $false } | Select-Object -First 3 | ForEach-Object { Write-Host "  $($_.Time): $($_.Error)" }
    }

    if ($failed -eq 0 -and $total -gt 0) {
        Write-Host ""
        Write-Host "[SUCCESS] ZERO DOWNTIME CONFIRMED! 100% availability during rollout." -ForegroundColor Green
    } elseif ($failed -gt 0) {
        Write-Host ""
        Write-Host "[FAILURE] DOWNTIME DETECTED: $failed requests failed!" -ForegroundColor Red
        exit 1
    }
}
finally {
    if ($pfProcess -and -not $pfProcess.HasExited) {
        Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
