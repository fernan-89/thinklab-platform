<#
.SYNOPSIS
  Live proof of Journey 14, first service: health monitoring through the platform gateway (health-monitoring ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8103, routes it through the gateway, allows loopback targets and turns the ledger
  recording on). The script starts the target double (mock-target.mjs, Node built-ins only: an HTTP endpoint and a TCP listener whose
  answer it controls) when nothing listens on its port. Uses its own tenant id, then drives, through the GATEWAY:
    (1) the SCHEDULER probes by itself: a check due every 10 seconds goes UP with no one asking, keeps probing, stops while paused and
        probes again at once when resumed;
    (2) a blip is not an outage: one failure leaves a check UP, the second in a row takes it DOWN, one success brings it back, and the audit
        trail holds exactly those changes of health;
    (3) a TCP target goes DOWN with the fixed code "connection refused" when the listener closes, and UP again when it opens;
    (4) a target that answers too slowly is "timeout", and one that answers with a redirect is "unexpected status" with the 302 (the
        redirect is not followed);
    (5) the target policy: the cloud metadata address, a link-local address over TCP, the decimal spelling of one, credentials in the URL
        and a query string are all refused (400), also when a check is updated;
    (6) the summary and the list filters tell the same story as the checks;
    (7) staff only (a REQUESTER gets 403), another tenant gets a 404, a duplicate name is refused (409), and four people running the same
        failing check at once record exactly one change of health;
    (8) every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\health-monitoring-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$LedgerUrl = 'http://localhost:8094',
    # How THIS script reaches the double's control endpoint.
    [string]$ControlUrl = 'http://localhost:9200',
    # How the MONITOR reaches the double (a compose name there, localhost here), and the ports it sees.
    [string]$TargetHost = 'localhost',
    [int]$TargetHttpPort = 9200,
    [int]$TargetTcpPort = 9201,
    [string]$NodeExe = (Join-Path $PSScriptRoot '..\..\..\tools\node\node.exe')
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 6 }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 45) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 }
    return [bool](& $Condition)
}

# ---- The target double ---------------------------------------------------------------------------------------------------------
$mockProcess = $null
function Test-TargetUp { try { [void](Invoke-WebRequest -Uri "$ControlUrl/__mock/state" -UseBasicParsing -TimeoutSec 2); return $true } catch { return $false } }
function Target([string]$Path, $Body) { [void](Invoke-WebRequest -Method POST -Uri "$ControlUrl$Path" -UseBasicParsing -ContentType 'application/json' -Body ($Body | ConvertTo-Json)) }

try {
    if (-not (Test-TargetUp)) {
        $env:MOCK_TARGET_HTTP_PORT = "$(([uri]$ControlUrl).Port)"
        $env:MOCK_TARGET_TCP_PORT = "$TargetTcpPort"
        $mockProcess = Start-Process -FilePath $NodeExe -ArgumentList (Join-Path $PSScriptRoot 'mock-target.mjs') -PassThru -WindowStyle Hidden
        if (-not (Wait-Until { Test-TargetUp } 15)) { throw 'the target double did not start' }
    }
    Target '/__mock/status' @{ status = 200 }; Target '/__mock/delay' @{ ms = 0 }; Target '/__mock/tcp' @{ open = $true }

    $hlm = "$GatewayUrl/it-health-monitoring/v1"
    $tenantId = [guid]::NewGuid().ToString()
    $staffUser = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
    $staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
    $asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
    $otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }
    $httpTarget = "http://${TargetHost}:$TargetHttpPort/health"
    $tcpTarget = "${TargetHost}:$TargetTcpPort"

    function New-Check($Body) { Invoke-Api POST "$hlm/initiate" $staff $Body }
    function Get-Check([string]$Id) { (Invoke-Api GET "$hlm/$Id/retrieve" $staff).Body }
    function Run-Check([string]$Id) { (Invoke-Api PUT "$hlm/$Id/check/execute" $staff).Body }
    function Result-Count([string]$Id) { @((Invoke-Api GET "$hlm/$Id/results/retrieve?limit=500" $staff).Body).Count }
    function Actions([string]$Id) { (@((Invoke-Api GET "$hlm/$Id/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action }) -join ',') }

    # 1. The scheduler probes by itself.
    $created = New-Check @{ name = 'Intranet'; type = 'HTTP'; target = $httpTarget; assetId = $assetId; intervalSeconds = 10; timeoutMillis = 2000 }
    $s = $created.Body.id
    Assert-Equal 'staff start watching an HTTP target: 201, ACTIVE, UNKNOWN, every 10 s' "$($created.Status)/$($created.Body.status)/$($created.Body.health)/$($created.Body.intervalSeconds)" '201/ACTIVE/UNKNOWN/10'
    Assert-Equal 'with no one asking, the scheduler probes it and it goes UP' (Wait-Until { (Get-Check $s).health -eq 'UP' } 60) $true
    $probed = Get-Check $s
    Assert-Equal 'it knows when it was probed, how long it took and that nothing is wrong' "$([bool]$probed.lastCheckedAt)/$($null -ne $probed.lastLatencyMillis)/$([bool]$probed.lastError)" 'True/True/False'
    Assert-Equal 'and it keeps probing: a second probe arrives by itself' (Wait-Until { (Result-Count $s) -ge 2 } 45) $true
    $latest = @((Invoke-Api GET "$hlm/$s/results/retrieve?limit=5" $staff).Body)[0]
    Assert-Equal 'the history holds what each probe saw (newest first)' "$($latest.ok)/$($latest.statusCode)" 'True/200'
    Assert-Equal 'pause' (Invoke-Api PUT "$hlm/$s/control/pause" $staff).Status 204
    Start-Sleep -Seconds 4
    $paused = Result-Count $s
    Start-Sleep -Seconds 13
    Assert-Equal 'a paused check is no longer probed on its own' (Result-Count $s) $paused
    Assert-Equal 'pausing twice is an illegal transition (409)' (Invoke-Api PUT "$hlm/$s/control/pause" $staff).Status 409
    Assert-Equal 'resume' (Invoke-Api PUT "$hlm/$s/control/resume" $staff).Status 204
    Assert-Equal 'resuming makes it due at once: it is probed again without waiting an interval' (Wait-Until { (Result-Count $s) -gt $paused } 12) $true
    Assert-Equal 'resuming an active check is an illegal transition (409)' (Invoke-Api PUT "$hlm/$s/control/resume" $staff).Status 409
    [void](Invoke-Api PUT "$hlm/$s/control/pause" $staff)

    # 2. A blip is not an outage. A long interval keeps the scheduler out of the way after its first probe.
    $m = (New-Check @{ name = 'Portal'; type = 'HTTP'; target = $httpTarget; intervalSeconds = 3600; timeoutMillis = 2000; failureThreshold = 2; successThreshold = 1 }).Body.id
    Assert-Equal 'its first probe is made by the scheduler: UP' (Wait-Until { (Get-Check $m).health -eq 'UP' } 60) $true
    Target '/__mock/status' @{ status = 503 }
    $blip = Run-Check $m
    Assert-Equal 'one failure: the check is still UP, one failure counted' "$($blip.health)/$($blip.consecutiveFailures)/$($blip.lastError)" 'UP/1/unexpected status'
    $down = Run-Check $m
    Assert-Equal 'the second failure in a row takes it DOWN' "$($down.health)/$($down.consecutiveFailures)" 'DOWN/2'
    Target '/__mock/status' @{ status = 200 }
    $back = Run-Check $m
    Assert-Equal 'one success brings it back UP, the error cleared' "$($back.health)/$([bool]$back.lastError)" 'UP/False'
    Assert-Equal 'the audit trail holds exactly the changes of health, not every probe' (Actions $m) 'INITIATED,BECAME_UP,WENT_DOWN,BECAME_UP'

    # 3. TCP.
    $t = (New-Check @{ name = 'Database'; type = 'TCP'; target = $tcpTarget; intervalSeconds = 3600; timeoutMillis = 1000; failureThreshold = 2 }).Body.id
    Assert-Equal 'a TCP check is UP when the connection opens' (Wait-Until { (Get-Check $t).health -eq 'UP' } 60) $true
    Target '/__mock/tcp' @{ open = $false }
    [void](Run-Check $t)
    $refused = Run-Check $t
    Assert-Equal 'with the listener closed: DOWN, with the fixed code "connection refused"' "$($refused.health)/$($refused.lastError)" 'DOWN/connection refused'
    Target '/__mock/tcp' @{ open = $true }
    Assert-Equal 'with the listener open again: UP' (Run-Check $t).health 'UP'

    # 4. Timeout, and a redirect that is not followed.
    $d = (New-Check @{ name = 'Slow'; type = 'HTTP'; target = $httpTarget; intervalSeconds = 3600; timeoutMillis = 500; failureThreshold = 1 }).Body.id
    Target '/__mock/delay' @{ ms = 2500 }
    $slow = Run-Check $d
    Assert-Equal 'a target that answers too slowly: DOWN, "timeout"' "$($slow.health)/$($slow.lastError)" 'DOWN/timeout'
    Target '/__mock/delay' @{ ms = 0 }
    $e = (New-Check @{ name = 'Redirecting'; type = 'HTTP'; target = "http://${TargetHost}:$TargetHttpPort/redirect"; intervalSeconds = 3600; timeoutMillis = 2000; expectedStatus = 200; failureThreshold = 1 }).Body.id
    [void](Run-Check $e)
    $redirected = @((Invoke-Api GET "$hlm/$e/results/retrieve?limit=1" $staff).Body)[0]
    Assert-Equal 'a redirect is an answer, not followed: DOWN with the 302 and "unexpected status"' "$((Get-Check $e).health)/$($redirected.statusCode)/$($redirected.error)" 'DOWN/302/unexpected status'

    # 5. The target policy.
    Assert-Equal 'the cloud metadata address is refused (400)' (New-Check @{ name = 'p1'; type = 'HTTP'; target = 'http://169.254.169.254/latest/meta-data' }).Status 400
    Assert-Equal 'a link-local address over TCP is refused (400)' (New-Check @{ name = 'p2'; type = 'TCP'; target = '169.254.0.7:80' }).Status 400
    Assert-Equal 'the decimal spelling of the metadata address is refused (400)' (New-Check @{ name = 'p3'; type = 'HTTP'; target = 'http://2852039166/' }).Status 400
    Assert-Equal 'credentials in the URL are refused (400)' (New-Check @{ name = 'p4'; type = 'HTTP'; target = 'https://bot:secret@intranet.acme.test/' }).Status 400
    Assert-Equal 'a query string, where tokens end up, is refused (400)' (New-Check @{ name = 'p5'; type = 'HTTP'; target = 'https://intranet.acme.test/health?token=abc' }).Status 400
    Assert-Equal 'a name already in use is refused (409)' (New-Check @{ name = 'Intranet'; type = 'TCP'; target = 'db.internal:5432' }).Status 409
    Assert-Equal 'an update to a forbidden target is refused too (400)' (Invoke-Api PUT "$hlm/$m/update" $staff @{ name = 'Portal'; target = 'http://169.254.169.254/' }).Status 400
    Assert-Equal 'a timeout longer than the interval is refused (400)' (New-Check @{ name = 'p6'; type = 'TCP'; target = 'db.internal:5432'; intervalSeconds = 10; timeoutMillis = 20000 }).Status 400

    # 6. Summary and filters.
    $summary = (Invoke-Api GET "$hlm/summary/retrieve" $staff).Body
    Assert-Equal 'the summary counts the active checks by health, and the paused apart (5 checks: 2 up, 2 down, 1 paused)' "$($summary.total)/$($summary.up)/$($summary.down)/$($summary.unknown)/$($summary.paused)" '5/2/2/0/1'
    Assert-Equal 'the DOWN checks are found by health' (@((Invoke-Api GET "$hlm/retrieve?health=DOWN" $staff).Body).Count) 2
    Assert-Equal 'the paused one is found by status' (@((Invoke-Api GET "$hlm/retrieve?status=PAUSED" $staff).Body | ForEach-Object { $_.id }) -join ',') $s
    Assert-Equal 'and the check that watches an asset is found by asset' (@((Invoke-Api GET "$hlm/retrieve?assetId=$assetId" $staff).Body | ForEach-Object { $_.id }) -join ',') $s

    # 7. Staff only, the tenant, and a race.
    $denied = Invoke-Api POST "$hlm/initiate" $asRequester @{ name = 'r'; type = 'TCP'; target = 'db.internal:5432' }
    Assert-Equal 'a REQUESTER cannot start monitoring (403 ERR-HLM-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-HLM-00403'
    Assert-Equal 'a REQUESTER cannot read a check (403)' (Invoke-Api GET "$hlm/$m/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot list the checks (403)' (Invoke-Api GET "$hlm/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot read the summary (403)' (Invoke-Api GET "$hlm/summary/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot run a check (403)' (Invoke-Api PUT "$hlm/$m/check/execute" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot read the results (403)' (Invoke-Api GET "$hlm/$m/results/retrieve" $asRequester).Status 403
    Assert-Equal 'another tenant gets a 404 for the check' (Invoke-Api GET "$hlm/$m/retrieve" $otherTenant).Status 404
    Assert-Equal 'nor can it run it' (Invoke-Api PUT "$hlm/$m/check/execute" $otherTenant).Status 404
    Assert-Equal 'and finds none in the list' (@((Invoke-Api GET "$hlm/retrieve" $otherTenant).Body).Count) 0
    Assert-Equal 'the tenant is mandatory (400)' (Invoke-Api GET "$hlm/$m/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
    Target '/__mock/status' @{ status = 503 }
    $run = {
        param($url, $tenant, $executor)
        try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
        catch { [int]$_.Exception.Response.StatusCode }
    }
    $jobs = 1..4 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$hlm/$m/check/execute", $tenantId, ([guid]::NewGuid().ToString()) }
    $codes = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job
    Assert-Equal 'four people running the same failing check at once: every one is answered 200' (@($codes | Where-Object { $_ -ne 200 }).Count) 0
    [void](Run-Check $m)
    $raced = Get-Check $m
    Assert-Equal 'the check is DOWN and the trail holds exactly one more change of health: none was lost or doubled' "$($raced.health)/$((Actions $m))" 'DOWN/INITIATED,BECAME_UP,WENT_DOWN,BECAME_UP,WENT_DOWN'
    Target '/__mock/status' @{ status = 200 }
    Assert-Equal 'there is no delete (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$hlm/$m" $staff).Status) $true

    # 8. The ledger.
    $ledger = "$LedgerUrl/compliance-audit-ledger/v1"
    $recorded = 0
    for ($i = 0; $i -lt 20; $i++) {
        $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-health-monitoring' })
        $recorded = $entries.Count
        if ($recorded -ge 25) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 25) $true
    Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
    Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true
}
finally {
    if ($mockProcess) { Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Health monitoring smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
