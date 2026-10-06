<#
.SYNOPSIS
  Live proof of Journey 14, second service: alerting through the platform gateway (alerting ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8104, routes it through the gateway and turns the ledger recording on). The script
  starts the target double (mock-target.mjs) when nothing listens on its port. It uses its own tenant id and the REAL health monitor and the
  REAL incident service, then drives, through the GATEWAY:
    (1) nothing is down: an evaluation opens nothing;
    (2) a check goes DOWN: an alert is opened and a real incident is filed on the incident service, with the title, the priority derived from
        the rule's impact and urgency, the requester and the asset;  the OLDEST active rule that covers the check is the one that decides;
    (3) ONE incident per outage: more evaluations and the scheduler's own rounds open nothing more, and four evaluations at once on another
        outage open exactly one alert and one incident;
    (4) recovery: the alert is RESOLVED and the incident gets an INTERNAL note (a requester does not see it); the incident is NOT closed;
    (5) a new outage is a new alert and a new incident; a PAUSED rule is skipped (the next rule decides), a tenant with no active rule
        opens nothing, and an alert opened earlier is still resolved when its check recovers;
    (6) staff only (a REQUESTER gets 403), another tenant gets a 404 / nothing, a duplicate rule name is refused (409), alerts cannot be
        written by hand;
    (7) every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\alerting-smoke.ps1
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
    $alr = "$GatewayUrl/it-alerting/v1"
    $inc = "$GatewayUrl/it-incident-management/v1"
    $tenantId = [guid]::NewGuid().ToString()
    $staffUser = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
    $staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
    $asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $filedFor; 'X-Role' = 'REQUESTER' }
    $otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }
    $httpTarget = "http://${TargetHost}:$TargetHttpPort/health"
    $tcpTarget = "${TargetHost}:$TargetTcpPort"

    function Run-Check([string]$Id) { (Invoke-Api PUT "$hlm/$Id/check/execute" $staff).Body }
    function Evaluate { (Invoke-Api PUT "$alr/evaluation/execute" $staff) }
    function Alerts([string]$Query = '') { @((Invoke-Api GET "$alr/retrieve$Query" $staff).Body) }
    function Incidents { @((Invoke-Api GET "$inc/retrieve" $staff).Body) }
    function Get-Incident([string]$Id) { (Invoke-Api GET "$inc/$Id/retrieve" $staff).Body }
    function Actions([string]$Path) { (@((Invoke-Api GET "$Path/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action }) -join ',') }
    function New-Rule($Body) { Invoke-Api POST "$alr/rule/initiate" $staff $Body }

    # 0. Two checks to watch, probed once by the monitor's own scheduler, then left alone (a long interval).
    $web = (Invoke-Api POST "$hlm/initiate" $staff @{ name = 'Intranet'; type = 'HTTP'; target = $httpTarget; assetId = $assetId; intervalSeconds = 3600; timeoutMillis = 2000; failureThreshold = 1 }).Body.id
    $db = (Invoke-Api POST "$hlm/initiate" $staff @{ name = 'Database'; type = 'TCP'; target = $tcpTarget; intervalSeconds = 3600; timeoutMillis = 1000; failureThreshold = 1 }).Body.id
    Assert-Equal 'both checks are probed by the monitor and go UP' (Wait-Until { (Invoke-Api GET "$hlm/$web/retrieve" $staff).Body.health -eq 'UP' -and (Invoke-Api GET "$hlm/$db/retrieve" $staff).Body.health -eq 'UP' } 60) $true

    # 1. Rules, and nothing down.
    $ruleAll = New-Rule @{ name = 'Everything'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }
    $ruleWeb = New-Rule @{ name = 'Intranet'; checkId = $web; impact = 'HIGH'; urgency = 'HIGH'; requesterId = $filedFor }
    Assert-Equal 'a rule for every check: 201, ACTIVE' "$($ruleAll.Status)/$($ruleAll.Body.status)/$($ruleAll.Body.checkId)" '201/ACTIVE/'
    Assert-Equal 'a rule for one check: 201, tied to it' "$($ruleWeb.Status)/$($ruleWeb.Body.checkId)" "201/$web"
    Assert-Equal 'a rule name already in use is refused (409 ERR-ALR-00409)' "$((New-Rule @{ name = 'Everything'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }).Body.error_code)" 'ERR-ALR-00409'
    Assert-Equal 'a rule must name the requester the incident is filed for (400)' (New-Rule @{ name = 'No requester'; impact = 'LOW'; urgency = 'LOW' }).Status 400
    Assert-Equal 'the rules are listed oldest first' (@((Invoke-Api GET "$alr/rule/retrieve" $staff).Body | ForEach-Object { $_.name }) -join ',') 'Everything,Intranet'
    $quiet = Evaluate
    Assert-Equal 'nothing is down: an evaluation opens nothing' "$($quiet.Status)/$($quiet.Body.opened)/$($quiet.Body.resolved)/$($quiet.Body.incidentsOpened)" '200/0/0/0'
    Assert-Equal 'no alert and no incident' "$(@(Alerts).Count)/$(@(Incidents).Count)" '0/0'

    # 2. A check goes down: an alert and a real incident, decided by the OLDEST active rule that covers it.
    Target '/__mock/status' @{ status = 503 }
    Assert-Equal 'the monitor sees the check DOWN' (Run-Check $web).health 'DOWN'
    [void](Evaluate)
    Assert-Equal 'an alert is opened for it (by an evaluation or by the scheduler)' (Wait-Until { @(Alerts).Count -ge 1 } 20) $true
    $first = (Alerts)[0]
    Assert-Equal 'it is OPEN, names the check and the fixed error, and has its incident' "$($first.status)/$($first.checkName)/$($first.lastError)/$([bool]$first.incidentId)" 'OPEN/Intranet/unexpected status/True'
    $incident = Get-Incident $first.incidentId
    Assert-Equal 'the incident is filed: title, NEW, requester and the asset the check watches' "$($incident.title)/$($incident.status)/$($incident.requesterId)/$(@($incident.affectedAssetIds) -join ',')" "Health check down: Intranet/NEW/$filedFor/$assetId"
    Assert-Equal 'the OLDEST rule decided (LOW x LOW is P4), not the newer rule made for this very check' "$($incident.impact)/$($incident.urgency)/$($incident.priority)" 'LOW/LOW/P4'
    Assert-Equal 'the incident names the service identity that opened it' (@((Invoke-Api GET "$inc/$($first.incidentId)/audit-log/retrieve" $staff).Body | Select-Object -First 1 | ForEach-Object { $_.executor })) 'system:alerting'
    Assert-Equal 'the alert trail says it opened and its incident did' (Actions "$alr/$($first.id)") 'OPENED,INCIDENT_OPENED'

    # 3. ONE incident per outage.
    1..3 | ForEach-Object { [void](Evaluate) }
    Start-Sleep -Seconds 12
    Assert-Equal 'more evaluations and the scheduler''s own rounds open nothing more: still one alert and one incident' "$(@(Alerts).Count)/$(@(Incidents).Count)" '1/1'
    $again = Evaluate
    Assert-Equal 'an evaluation says so: nothing opened' "$($again.Body.opened)/$($again.Body.incidentsOpened)" '0/0'
    Target '/__mock/tcp' @{ open = $false }
    Assert-Equal 'a second outage: the database check is DOWN' (Run-Check $db).health 'DOWN'
    $run = {
        param($url, $tenant, $executor)
        try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
        catch { [int]$_.Exception.Response.StatusCode }
    }
    $jobs = 1..4 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$alr/evaluation/execute", $tenantId, ([guid]::NewGuid().ToString()) }
    $codes = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job
    Assert-Equal 'four evaluations at once: every one is answered 200' (@($codes | Where-Object { $_ -ne 200 }).Count) 0
    Start-Sleep -Seconds 6
    Assert-Equal 'and they opened exactly ONE alert and ONE incident for the second outage' "$(@(Alerts "?checkId=$db").Count)/$(@(Alerts).Count)/$(@(Incidents).Count)" '1/2/2'
    $dbAlert = (Alerts "?checkId=$db")[0]
    Assert-Equal 'it has its incident too' ([bool]$dbAlert.incidentId) $true

    # 4. Recovery: resolved, an INTERNAL note, the incident is not closed.
    Target '/__mock/status' @{ status = 200 }
    Assert-Equal 'the check is UP again' (Run-Check $web).health 'UP'
    [void](Evaluate)
    Assert-Equal 'its alert is RESOLVED' (Wait-Until { (Alerts "?checkId=$web")[0].status -eq 'RESOLVED' } 20) $true
    $resolved = (Alerts "?checkId=$web")[0]
    Assert-Equal 'it knows when it resolved and keeps its incident' "$([bool]$resolved.resolvedAt)/$($resolved.incidentId)" "True/$($first.incidentId)"
    Assert-Equal 'the alert trail reads in order' (Actions "$alr/$($first.id)") 'OPENED,INCIDENT_OPENED,RESOLVED'
    Assert-Equal 'only the status filter shows it: one resolved, one open' "$(@(Alerts '?status=RESOLVED').Count)/$(@(Alerts '?status=OPEN').Count)" '1/1'
    $after = Get-Incident $first.incidentId
    $note = @($after.comments)
    Assert-Equal 'the incident got exactly one note, INTERNAL, from the service identity' "$($note.Count)/$($note[0].internal)/$($note[0].author)" '1/True/system:alerting'
    Assert-Equal 'and it was NOT closed or resolved: a person decides that' $after.status 'NEW'
    Assert-Equal 'the person it was filed for does not see the internal note' "$(@((Invoke-Api GET "$inc/$($first.incidentId)/retrieve" $asRequester).Body.comments).Count)" 0
    [void](Evaluate)
    Assert-Equal 'a resolved alert is not touched again: still one note' "$(@((Get-Incident $first.incidentId).comments).Count)" 1

    # 5. A new outage is a new alert; a paused rule is skipped; no active rule opens nothing; an open alert is still resolved.
    Assert-Equal 'pause the oldest rule' (Invoke-Api PUT "$alr/rule/$($ruleAll.Body.id)/control/pause" $staff).Status 204
    Assert-Equal 'pausing it twice is an illegal transition (409)' (Invoke-Api PUT "$alr/rule/$($ruleAll.Body.id)/control/pause" $staff).Status 409
    Target '/__mock/status' @{ status = 503 }
    Assert-Equal 'the check goes DOWN again' (Run-Check $web).health 'DOWN'
    [void](Evaluate)
    Assert-Equal 'a NEW alert is opened: the first one is history' (Wait-Until { @(Alerts "?checkId=$web").Count -ge 2 } 20) $true
    $second = (Alerts "?checkId=$web")[0]
    Assert-Equal 'the newest first: OPEN, a different alert, with an incident' "$($second.status)/$($second.id -ne $first.id)/$([bool]$second.incidentId)" 'OPEN/True/True'
    $incident2 = Get-Incident $second.incidentId
    Assert-Equal 'the paused rule was skipped: the next rule decided (HIGH x HIGH is P1)' "$($incident2.impact)/$($incident2.urgency)/$($incident2.priority)" 'HIGH/HIGH/P1'
    Assert-Equal 'three incidents so far: one per outage' "$(@(Incidents).Count)" 3
    Assert-Equal 'pause the other rule too: no rule is active' (Invoke-Api PUT "$alr/rule/$($ruleWeb.Body.id)/control/pause" $staff).Status 204
    Target '/__mock/status' @{ status = 200 }
    Assert-Equal 'with no active rule the open alert is still resolved when its check recovers' (Run-Check $web).health 'UP'
    [void](Evaluate)
    Assert-Equal 'it is RESOLVED' (Wait-Until { (Alerts "?checkId=$web")[0].status -eq 'RESOLVED' } 20) $true
    Target '/__mock/status' @{ status = 503 }
    [void](Run-Check $web)
    [void](Evaluate)
    Start-Sleep -Seconds 7
    Assert-Equal 'a third outage with no active rule opens nothing: no new alert, no new incident' "$(@(Alerts "?checkId=$web").Count)/$(@(Incidents).Count)" '2/3'
    Target '/__mock/status' @{ status = 200 }
    [void](Run-Check $web)
    Target '/__mock/tcp' @{ open = $true }
    Assert-Equal 'the database is back too' (Run-Check $db).health 'UP'
    [void](Evaluate)
    Assert-Equal 'its alert is RESOLVED although every rule is paused' (Wait-Until { (Alerts "?checkId=$db")[0].status -eq 'RESOLVED' } 20) $true
    Assert-Equal 'nothing is left open' "$(@(Alerts '?status=OPEN').Count)" 0
    Assert-Equal 'resume a rule' (Invoke-Api PUT "$alr/rule/$($ruleWeb.Body.id)/control/resume" $staff).Status 204
    Assert-Equal 'the rule trail reads in order' (Actions "$alr/rule/$($ruleWeb.Body.id)") 'INITIATED,PAUSED,RESUMED'
    Assert-Equal 'update a rule (204)' (Invoke-Api PUT "$alr/rule/$($ruleWeb.Body.id)/update" $staff @{ name = 'Intranet'; checkId = $web; impact = 'MEDIUM'; urgency = 'HIGH'; requesterId = $filedFor }).Status 204
    Assert-Equal 'and it reads back as updated' "$((Invoke-Api GET "$alr/rule/$($ruleWeb.Body.id)/retrieve" $staff).Body.impact)" 'MEDIUM'

    # 6. Staff only, the tenant, and no hand-written alerts.
    $denied = Invoke-Api POST "$alr/rule/initiate" $asRequester @{ name = 'r'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }
    Assert-Equal 'a REQUESTER cannot create a rule (403 ERR-ALR-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-ALR-00403'
    Assert-Equal 'a REQUESTER cannot list the rules (403)' (Invoke-Api GET "$alr/rule/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot list the alerts (403)' (Invoke-Api GET "$alr/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot read an alert (403)' (Invoke-Api GET "$alr/$($first.id)/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot evaluate (403)' (Invoke-Api PUT "$alr/evaluation/execute" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot pause a rule (403)' (Invoke-Api PUT "$alr/rule/$($ruleWeb.Body.id)/control/pause" $asRequester).Status 403
    Assert-Equal 'another tenant gets a 404 for the alert' (Invoke-Api GET "$alr/$($first.id)/retrieve" $otherTenant).Status 404
    Assert-Equal 'and for the rule' (Invoke-Api GET "$alr/rule/$($ruleWeb.Body.id)/retrieve" $otherTenant).Status 404
    Assert-Equal 'and finds no alert in the list' (@((Invoke-Api GET "$alr/retrieve" $otherTenant).Body).Count) 0
    Assert-Equal 'its evaluation finds nothing to do' "$((Invoke-Api PUT "$alr/evaluation/execute" $otherTenant).Body.opened)" 0
    Assert-Equal 'the tenant is mandatory (400)' (Invoke-Api GET "$alr/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
    Assert-Equal 'an alert cannot be written by hand (404 or 405)' (@(404, 405) -contains (Invoke-Api POST "$alr/initiate" $staff @{ checkId = $web }).Status) $true
    Assert-Equal 'there is no delete (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$alr/rule/$($ruleWeb.Body.id)" $staff).Status) $true

    # 7. The ledger.
    $ledger = "$LedgerUrl/compliance-audit-ledger/v1"
    $recorded = 0
    for ($i = 0; $i -lt 20; $i++) {
        $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-alerting' })
        $recorded = $entries.Count
        if ($recorded -ge 20) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 20) $true
    Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
    Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true
}
finally {
    if ($mockProcess) { Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Alerting smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
