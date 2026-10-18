<#
.SYNOPSIS
  Live proof of Journey 14, fifth service: the capacity registry through the platform gateway (capacity-registry ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8107, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a policy is a watch judged when read: a new one is ACTIVE with NO_DATA, found by level, asset and metric;
    (2) samples a day apart draw a straight line: OK, WITHIN_HORIZON, four days to the limit and the date it would be reached; a different value
        for a moment already reported never overwrites the first (200, the stored sample);
    (3) the same new sample reported by twenty tools at once is ONE sample (one 201, nineteen 200);
    (4) the latest sample only moves forward, whatever the order three simultaneous reports arrive in; a late sample joins the trend only;
    (5) tightening the limit changes the verdict at once (nothing of it is stored);
    (6) a tool that went silent is stale and still judged on its last known value;
    (7) two people pausing at once get one winner; a paused policy is not judged but still takes samples; the trail reads in order;
    (8) a metric the registry does not know is refused and never repeated; values that make no sense are refused;
    (9) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (10) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    powershell -File .\capacity-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$LedgerUrl = 'http://localhost:8094'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 } }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Text = $r.Content; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Text = $text; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$Day = 1440
function Ago([double]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
function Ahead([double]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

$cap = "$GatewayUrl/it-capacity-registry/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString(); $quietAsset = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'disk-agent-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Policy-Body([string]$Name, [string]$Asset, [double]$Limit, [string]$Metric = 'DISK', [int]$Warn = 70, [int]$Critical = 90) {
    @{ name = $Name; assetId = $Asset; metric = $Metric; limit = $Limit; warnPercent = $Warn; criticalPercent = $Critical; windowDays = 30; horizonDays = 30; reportEveryHours = 24 }
}
function Sample-Body([string]$PolicyId, [double]$Value, [string]$At) { @{ policyId = $PolicyId; value = $Value; measuredAt = $At } }
function Get-Policy([string]$Id = $policy) { (Invoke-Api GET "$cap/$Id/retrieve" $staff).Body }
function Report($Body) { Invoke-Api POST "$cap/sample/initiate" $tool $Body }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }

# 1. A policy is a watch, judged when read.
$created = Invoke-Api POST "$cap/initiate" $staff (Policy-Body 'Orders disk' $assetId 100)
$policy = $created.Body.id
Assert-Equal 'staff watch a disk of 100 units: 201, ACTIVE, NO_DATA, no forecast yet' "$($created.Status)/$($created.Body.status)/$($created.Body.level)/$($created.Body.forecast)" '201/ACTIVE/NO_DATA/NOT_ENOUGH_DATA'
Assert-Equal 'the list finds it by level, by asset and by metric' "$(@((Invoke-Api GET "$cap/retrieve?level=NO_DATA&assetId=$assetId" $staff).Body)[0].id)/$(@((Invoke-Api GET "$cap/retrieve?metric=DISK&assetId=$assetId" $staff).Body)[0].id)/$(@((Invoke-Api GET "$cap/retrieve?status=ACTIVE" $staff).Body)[0].id)" "$policy/$policy/$policy"

# 2. Samples a day apart draw a straight line: 10 units a day, 4 days to the limit.
$day3 = Ago (3 * $Day); $day2 = Ago (2 * $Day); $day1 = Ago $Day
$first = Report (Sample-Body $policy 40 $day3)
Assert-Equal 'the first sample is a new fact: 201, value kept, reported by the tool' "$($first.Status)/$($first.Body.value)/$($first.Body.reportedBy)" '201/40/disk-agent-1'
$one = Get-Policy
Assert-Equal 'one sample says nothing about the trend: OK at 40 percent, not enough data' "$($one.level)/$($one.utilisationPercent)/$($one.forecast)" 'OK/40/NOT_ENOUGH_DATA'
$again = Report (Sample-Body $policy 99 $day3)
Assert-Equal 'the same moment with another value is the stored sample (200), the first value kept' "$($again.Status)/$($again.Body.id -eq $first.Body.id)/$($again.Body.value)" '200/True/40'
Assert-Equal 'the second and third samples are new (201)' "$((Report (Sample-Body $policy 50 $day2)).Status)/$((Report (Sample-Body $policy 60 $day1)).Status)" '201/201'
$line = Get-Policy
Assert-Equal 'three samples a day apart: WITHIN_HORIZON, four days to the limit' "$($line.level)/$($line.forecast)/$([math]::Round($line.daysToLimit, 3))" 'OK/WITHIN_HORIZON/4'
$gap = ([datetime]::Parse($line.projectedExhaustionAt).ToUniversalTime() - [datetime]::Parse($line.lastMeasuredAt).ToUniversalTime()).TotalSeconds
Assert-Equal 'and it says when: four days after the latest sample' ([math]::Abs($gap - 4 * 86400) -lt 5) $true

# 3. The same new moment reported by twenty tools at once is one sample.
$moment = Ago 120
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$same = (Sample-Body $policy 61 $moment) | ConvertTo-Json
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$cap/sample/initiate", $tenantId, "disk-agent-$_", $same }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same sample reported by twenty tools at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'every answer is the same sample' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'and the policy holds exactly four samples' @((Invoke-Api GET "$cap/sample/retrieve?policyId=$policy" $staff).Body).Count 4

# 4. The latest sample only moves forward, whatever the order the reports arrive in.
$specs = @(@(50, 70), @(40, 71), @(30, 72))
$jobs = $specs | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$cap/sample/initiate", $tenantId, 'disk-agent-1', ((Sample-Body $policy $_[1] (Ago $_[0])) | ConvertTo-Json) }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'three samples reported at once: all new (201)' (@($answers | ForEach-Object { ($_ -split '/')[0] }) -join '/') '201/201/201'
$latest = Get-Policy
Assert-Equal 'the latest is the one with the newest moment, whichever arrived last: 72, now WARNING' "$($latest.lastValue)/$($latest.level)" '72/WARNING'
$late = Report (Sample-Body $policy 10 (Ago (5 * $Day)))
Assert-Equal 'a late sample (five days ago) is new, joins the trend and does not move the latest back' "$($late.Status)/$((Get-Policy).lastValue)" '201/72'
Assert-Equal 'the samples are listed newest first and limited' "$((@((Invoke-Api GET "$cap/sample/retrieve?policyId=$policy&limit=2" $staff).Body) | ForEach-Object { $_.value }) -join ',')/$(@((Invoke-Api GET "$cap/sample/retrieve?policyId=$policy" $staff).Body).Count)" '72,71/8'

# 5. Tightening the limit changes the verdict at once, because nothing of it is stored.
Assert-Equal 'update to a limit of 75 (204)' (Invoke-Api PUT "$cap/$policy/update" $staff (Policy-Body 'Orders disk' $assetId 75)).Status 204
$tight = Get-Policy
Assert-Equal '72 of 75 is now CRITICAL' "$($tight.level)/$($tight.utilisationPercent)" 'CRITICAL/96'
Assert-Equal 'the list finds it by level CRITICAL and not by OK' "$(@((Invoke-Api GET "$cap/retrieve?level=CRITICAL" $staff).Body)[0].id)/$(@((Invoke-Api GET "$cap/retrieve?level=OK" $staff).Body).Count)" "$policy/0"
Assert-Equal 'a critical level not above the warning one is refused (400)' (Invoke-Api PUT "$cap/$policy/update" $staff (Policy-Body 'x' $assetId 100 'DISK' 80 80)).Status 400

# 6. A tool that went silent is stale, and still judged on its last known value.
$quiet = Invoke-Api POST "$cap/initiate" $staff (Policy-Body 'Quiet disk' $quietAsset 100)
$quietId = $quiet.Body.id
Assert-Equal 'a sample ten days old is accepted (201)' (Report (Sample-Body $quietId 95 (Ago (10 * $Day)))).Status 201
$silent = Get-Policy $quietId
Assert-Equal 'that policy is stale (more than twice 24 hours), CRITICAL on 95, and has no trend' "$($silent.stale)/$($silent.level)/$($silent.forecast)" 'True/CRITICAL/NOT_ENOUGH_DATA'
Assert-Equal 'the first policy is not stale' (Get-Policy).stale $false

# 7. Two people pause at once: one wins.
$pause = {
    param($url, $tenant, $executor)
    try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [int]$_.Exception.Response.StatusCode }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$cap/$policy/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
$codes = @($jobs | Wait-Job | Receive-Job | Sort-Object)
$jobs | Remove-Job
Assert-Equal 'two people pausing at once: one 204 and one 409' ($codes -join '/') '204/409'
$paused = Get-Policy
Assert-Equal 'a paused policy is not judged and has no forecast (the field is left out)' "$($paused.status)/$($paused.level)/$($paused.forecast)" 'PAUSED/PAUSED/'
Assert-Equal 'a paused policy still accepts samples (201)' (Report (Sample-Body $policy 73 (Ago 5))).Status 201
Assert-Equal 'resume' (Invoke-Api PUT "$cap/$policy/control/resume" $staff).Status 204
Assert-Equal 'the policy trail holds each real change once, in order' (Actions "$cap/$policy/audit-log/retrieve") 'INITIATED,UPDATED,PAUSED,RESUMED'

# 8. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Invoke-Api POST "$cap/initiate" $staff ((Policy-Body 'n' $assetId 100 'DISK-secret-value'))
Assert-Equal 'an unknown metric is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text -like '*secret-value*')" '400/False'
Assert-Equal 'a value that is not a number is refused (400)' (Report "{`"policyId`":`"$policy`",`"value`":`"lots`",`"measuredAt`":`"$(Ago 3)`"}").Status 400
Assert-Equal 'a negative value is refused (400)' (Report (Sample-Body $policy -1 (Ago 3))).Status 400
Assert-Equal 'a sample taken in the future is refused (400)' (Report (Sample-Body $policy 10 (Ahead 120))).Status 400
Assert-Equal 'a sample for a policy that is not the tenant''s is a 404' (Report (Sample-Body ([guid]::NewGuid().ToString()) 10 (Ago 3))).Status 404

# 9. Staff only, the tenant.
$deniedCreate = Invoke-Api POST "$cap/initiate" $asRequester (Policy-Body 'r' $assetId 100)
Assert-Equal 'a REQUESTER cannot watch (403 ERR-CAP-00403)' "$($deniedCreate.Status)/$($deniedCreate.Body.error_code)" '403/ERR-CAP-00403'
Assert-Equal 'a REQUESTER cannot read a policy (403)' (Invoke-Api GET "$cap/$policy/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report a sample (403)' (Invoke-Api POST "$cap/sample/initiate" $asRequester (Sample-Body $policy 10 (Ago 3))).Status 403
Assert-Equal 'a REQUESTER cannot list the samples (403)' (Invoke-Api GET "$cap/sample/retrieve" $asRequester).Status 403
Assert-Equal 'another tenant gets a 404 for the policy' (Invoke-Api GET "$cap/$policy/retrieve" $otherTenant).Status 404
Assert-Equal 'another tenant cannot report a sample for it (404)' (Invoke-Api POST "$cap/sample/initiate" $otherTenant (Sample-Body $policy 10 (Ago 3))).Status 404
Assert-Equal 'and finds no samples' @((Invoke-Api GET "$cap/sample/retrieve" $otherTenant).Body).Count 0
Assert-Equal 'there is no delete (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$cap/$policy" $staff).Status) $true

# 10. The ledger.
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-capacity-registry' })
    $recorded = $entries.Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret-value*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Capacity smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
