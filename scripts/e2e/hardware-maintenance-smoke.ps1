<#
.SYNOPSIS
  Live proof of the WorkOrder <-> Asset event integration (it-hardware-maintenance's ADR-034,
  it-asset-registry's ADR-026): starting a repair moves the affected Asset into MAINTENANCE, and
  passing quality check moves it back to DEPLOYED - both via NATS JetStream, no synchronous call
  between the two services.

.DESCRIPTION
  Runs with THINKLAB_SECURITY_ENABLED left off (the default), so every call here is a plain,
  unauthenticated HTTP call directly to each service's own port. Start the stack with events on:

    $env:THINKLAB_EVENTS_ENABLED = 'true'
    .\start-local-stack.ps1 -Build

    powershell -File .\hardware-maintenance-smoke.ps1

  It creates an Organisation, an Asset (progressed to DEPLOYED, since only a DEPLOYED asset can enter
  MAINTENANCE), and a WorkOrder against it; triages, schedules and starts the repair, then polls the
  Asset until it reaches MAINTENANCE; completes the repair and passes quality check, then polls the
  Asset until it is back to DEPLOYED.
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
    [string]$AssetUrl = 'http://localhost:8083',
    [string]$HardwareMaintenanceUrl = 'http://localhost:8085'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 5 }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { $text | ConvertFrom-Json } else { $null } }
    }
}

function Assert-Status {
    param([string]$Name, $Response, [int]$Expected)
    $ok = ($Response.Status -eq $Expected)
    if (-not $ok) { Write-Output ("  {0} -> expected {1}, got {2}: {3}" -f $Name, $Expected, $Response.Status, ($Response.Body | ConvertTo-Json -Compress -Depth 4)) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Response.Status; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Wait-AssetStatus {
    param([string]$AssetApi, [string]$AssetId, [hashtable]$Headers, [string]$TargetStatus, [int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $status = $null
    while ((Get-Date) -lt $deadline -and $status -ne $TargetStatus) {
        $r = Invoke-Api GET "$AssetApi/$AssetId/retrieve" $Headers
        if ($r.Status -eq 200) { $status = $r.Body.status }
        if ($status -ne $TargetStatus) { Start-Sleep -Seconds 2 }
    }
    return $status
}

$org = "$OrgUrl/party-reference-data-directory/v1"
$asset = "$AssetUrl/it-asset-registry/v1"
$wo = "$HardwareMaintenanceUrl/it-hardware-maintenance/v1"
$executorHeader = @{ 'X-Executor' = 'hardware-maintenance-smoke' }

# 1. A real Organisation, a real Asset progressed to DEPLOYED (only a DEPLOYED asset enters MAINTENANCE).
$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$orgResponse = Invoke-Api POST "$org/initiate" $executorHeader @{ corporateName = 'Repairs Corp'; tradeName = 'Repairs'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@repairs.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created' $orgResponse 201
$orgId = $orgResponse.Body.id
$tenantAndExecutor = $executorHeader + @{ 'X-Tenant-Id' = $orgId }

$serial = "SN-SMOKE-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$assetResponse = Invoke-Api POST "$asset/initiate" $tenantAndExecutor @{ name = 'Laptop for repair'; category = 'LAPTOP'; serialNumber = $serial; specifications = @{ cpu = 'i7' } }
Assert-Status 'asset created (PROVISIONED)' $assetResponse 201
$assetId = $assetResponse.Body.id

$assignResponse = Invoke-Api PUT "$asset/$assetId/assignment/update" $executorHeader @{ assignedToUserId = [guid]::NewGuid().ToString(); locationId = [guid]::NewGuid().ToString() }
Assert-Status 'asset assigned a location' $assignResponse 204
Assert-Status 'asset control/ready' (Invoke-Api PUT "$asset/$assetId/control/ready" $executorHeader) 204
Assert-Status 'asset control/deploy (now DEPLOYED)' (Invoke-Api PUT "$asset/$assetId/control/deploy" $executorHeader) 204

# 2. File a WorkOrder against it, requester self-service style (no operator-supplied requesterId).
$requesterId = [guid]::NewGuid().ToString()
$requesterExecutor = @{ 'X-Executor' = $requesterId; 'X-Role' = 'REQUESTER' } + @{ 'X-Tenant-Id' = $orgId }
$woResponse = Invoke-Api POST "$wo/initiate" $requesterExecutor @{ assetId = $assetId; title = 'Laptop wont boot'; symptom = 'Black screen on power-on'; type = 'CORRECTIVE' }
Assert-Status 'work order filed (REQUESTED)' $woResponse 201
$woId = $woResponse.Body.id
Assert-Status 'work order requesterId defaults to the caller' ([pscustomobject]@{ Status = $(if ($woResponse.Body.requesterId -eq $requesterId) { 200 } else { 0 }) }) 200

# 3. Triage, schedule, start - control/start publishes repair-started.
Assert-Status 'triage (REQUESTED -> TRIAGED)' (Invoke-Api PUT "$wo/$woId/triage" $tenantAndExecutor @{ priority = 'P1' }) 204
Assert-Status 'schedule (TRIAGED -> SCHEDULED)' (Invoke-Api PUT "$wo/$woId/schedule" $executorHeader) 204
Assert-Status 'control/start (SCHEDULED -> IN_REPAIR)' (Invoke-Api PUT "$wo/$woId/control/start" $executorHeader) 204

Write-Output '  waiting up to 20s for the asset to reach MAINTENANCE...'
$statusAfterStart = Wait-AssetStatus -AssetApi $asset -AssetId $assetId -Headers $executorHeader -TargetStatus 'MAINTENANCE'
[void]$results.Add([pscustomobject]@{ Check = 'asset reaches MAINTENANCE via repair-started event'; Expected = 'MAINTENANCE'; Actual = $statusAfterStart; Result = if ($statusAfterStart -eq 'MAINTENANCE') { 'PASS' } else { 'FAIL' } })

# 4. Complete the repair and pass quality check - control/pass publishes repair-completed.
Assert-Status 'control/complete-repair (IN_REPAIR -> QUALITY_CHECK)' (Invoke-Api PUT "$wo/$woId/control/complete-repair" $executorHeader @{ diagnosis = 'Replaced the motherboard'; additionalLaborMinutes = 45 }) 204
Assert-Status 'control/pass (QUALITY_CHECK -> RESOLVED)' (Invoke-Api PUT "$wo/$woId/control/pass" $executorHeader @{ resolutionCode = 'RC-MOBO-SMOKE' }) 204

Write-Output '  waiting up to 20s for the asset to return to DEPLOYED...'
$statusAfterPass = Wait-AssetStatus -AssetApi $asset -AssetId $assetId -Headers $executorHeader -TargetStatus 'DEPLOYED'
[void]$results.Add([pscustomobject]@{ Check = 'asset returns to DEPLOYED via repair-completed event'; Expected = 'DEPLOYED'; Actual = $statusAfterPass; Result = if ($statusAfterPass -eq 'DEPLOYED') { 'PASS' } else { 'FAIL' } })

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Hardware maintenance smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
