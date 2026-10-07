<#
.SYNOPSIS
  Live proof of Journey 14, third service: the backup registry through the platform gateway (backup-registry ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8105, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a policy is a promise judged when read: a new one is ACTIVE and NEVER backed up yet, found by protection and by asset;
    (2) the same backup reported by twenty agents at once is ONE run (one 201, nineteen 200), and the policy is OK afterwards;
    (3) the summary only moves forward: a late, older backup is stored but moves nothing back, a failed backup moves the last run and not
        the last success, and the list is newest start first and limited;
    (4) a failure reason is never what the tool said: free text is refused (400) and is not repeated in the answer or on the ledger;
    (5) the recovery is proved by a restore test: unknown before it, met or missed against the objective after it;
    (6) two people pausing at once: one 204 and one 409; a paused policy is not judged; the trail holds each real change once;
    (7) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (8) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    powershell -File .\backup-smoke.ps1
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
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 6 }
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

function Minutes-Ago([int]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

$bkp = "$GatewayUrl/it-backup-registry/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'backup-agent-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Policy-Body([string]$Name, [int]$Rto) {
    @{ name = $Name; assetId = $assetId; frequencyHours = 24; rpoHours = 48; rtoMinutes = $Rto; retentionDays = 30; restoreTestEveryDays = 30 }
}
function Run-Body([string]$Kind, [string]$Outcome, [string]$Start, [string]$Finish, $Extra = @{}) {
    $body = @{ policyId = $policy; kind = $Kind; outcome = $Outcome; startedAt = $Start; finishedAt = $Finish }
    foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] }
    $body
}
function Get-Policy { (Invoke-Api GET "$bkp/$policy/retrieve" $staff).Body }
function Runs([string]$Query = '') { @((Invoke-Api GET "$bkp/run/retrieve?policyId=$policy$Query" $staff).Body) }
function Stamp($Value) { ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

# 1. A policy is a promise, judged when read.
$created = Invoke-Api POST "$bkp/initiate" $staff (Policy-Body 'Database nightly' 120)
$policy = $created.Body.id
Assert-Equal 'staff promise a backup every 24 h with at most 48 h lost: 201, ACTIVE, NEVER backed up yet' "$($created.Status)/$($created.Body.status)/$($created.Body.protection)" '201/ACTIVE/NEVER'
Assert-Equal 'the list finds it by protection NEVER and by asset' "$(@((Invoke-Api GET "$bkp/retrieve?protection=NEVER&assetId=$assetId" $staff).Body)[0].id)/$(@((Invoke-Api GET "$bkp/retrieve?assetId=$assetId" $staff).Body)[0].id)" "$policy/$policy"

# 2. A tool reports; the same run twenty times at once is one run.
$start = Minutes-Ago 300; $finish = Minutes-Ago 280
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$sameRun = (Run-Body 'BACKUP' 'SUCCEEDED' $start $finish @{ sizeBytes = 1048576 }) | ConvertTo-Json
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$bkp/run/initiate", $tenantId, "backup-agent-$_", $sameRun }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same backup reported by twenty agents at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'every answer is the same run' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'and the list holds exactly one run for the policy' (Runs).Count 1
Assert-Equal 'the policy is OK, and the run lasted 20 minutes' "$((Get-Policy).protection)/$((Runs)[0].durationMinutes)" 'OK/20'

# 3. The summary only moves forward.
$newerStart = Minutes-Ago 120; $newerFinish = Minutes-Ago 100
$olderStart = Minutes-Ago 200; $olderFinish = Minutes-Ago 180
Assert-Equal 'a newer backup is reported (201)' (Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'SUCCEEDED' $newerStart $newerFinish)).Status 201
Assert-Equal 'an older backup reported late is stored too (201)' (Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'SUCCEEDED' $olderStart $olderFinish)).Status 201
Assert-Equal 'but the last success is still the newer one: a late report moves nothing back' (Stamp (Get-Policy).lastSuccessAt) $newerFinish
$failedStart = Minutes-Ago 60; $failedFinish = Minutes-Ago 55
$failedRun = Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'FAILED' $failedStart $failedFinish @{ failureReason = 'STORAGE_FULL' })
Assert-Equal 'a failed backup names one reason from the list (201)' "$($failedRun.Status)/$($failedRun.Body.failureReason)" '201/STORAGE_FULL'
Assert-Equal 'it moves the last run, not the last success' "$(Stamp (Get-Policy).lastRunAt)/$(Stamp (Get-Policy).lastSuccessAt)" "$failedFinish/$newerFinish"
Assert-Equal 'the runs are listed newest start first, and limited' "$((Runs)[0].outcome)/$((Runs '&limit=1').Count)" 'FAILED/1'

# 4. A failure reason is never what the tool said.
$secret = 'password=hunter2'
$denied = Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'FAILED' (Minutes-Ago 40) (Minutes-Ago 35) @{ failureReason = $secret })
Assert-Equal "a failure reason in the tool's own words is refused (400)" $denied.Status 400
Assert-Equal 'and the answer does not repeat it' ($denied.Text -like '*hunter2*') $false
Assert-Equal 'a failed run without a reason is refused (400)' (Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'FAILED' (Minutes-Ago 40) (Minutes-Ago 35))).Status 400
Assert-Equal 'a run that finishes in the future is refused (400)' (Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'BACKUP' 'SUCCEEDED' (Minutes-Ago -60) (Minutes-Ago -90))).Status 400

# 5. The recovery is proved by a restore test.
Assert-Equal 'before a restore test, the recovery time is unknown (the field is left out)' ($null -eq (Get-Policy).rtoMet) $true
Assert-Equal 'a restore test that took 20 minutes is reported (201)' (Invoke-Api POST "$bkp/run/initiate" $tool (Run-Body 'RESTORE_TEST' 'SUCCEEDED' (Minutes-Ago 30) (Minutes-Ago 10))).Status 201
Assert-Equal 'it meets the 120 minute objective, took 20, and left the last success alone' "$((Get-Policy).rtoMet)/$((Get-Policy).lastRestoreMinutes)/$(Stamp (Get-Policy).lastSuccessAt)" "True/20/$newerFinish"
Assert-Equal 'a tighter objective of 10 minutes (update, 204)' (Invoke-Api PUT "$bkp/$policy/update" $staff (Policy-Body 'Database nightly' 10)).Status 204
Assert-Equal 'the same restore test now misses it, and the summary was kept' "$((Get-Policy).rtoMet)/$((Get-Policy).lastRestoreMinutes)" 'False/20'
Assert-Equal 'an RPO shorter than the frequency is refused (400)' (Invoke-Api PUT "$bkp/$policy/update" $staff @{ name = 'n'; assetId = $assetId; frequencyHours = 24; rpoHours = 12; rtoMinutes = 10; retentionDays = 30 }).Status 400

# 6. Two people pause at once: one wins.
$pause = {
    param($url, $tenant, $executor)
    try { [string][int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [string][int]$_.Exception.Response.StatusCode }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$bkp/$policy/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
$pauseCodes = @($jobs | Wait-Job | Receive-Job | Sort-Object)
$jobs | Remove-Job
Assert-Equal 'two people pausing at once: one 204 and one 409' ($pauseCodes -join '/') '204/409'
Assert-Equal 'a paused policy is not judged' "$((Get-Policy).status)/$((Get-Policy).protection)" 'PAUSED/PAUSED'
Assert-Equal 'resume' (Invoke-Api PUT "$bkp/$policy/control/resume" $staff).Status 204
Assert-Equal 'the trail holds each real change once, in order' ((@((Invoke-Api GET "$bkp/$policy/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action })) -join ',') 'INITIATED,UPDATED,PAUSED,RESUMED'

# 7. Staff only, the tenant.
$deniedCreate = Invoke-Api POST "$bkp/initiate" $asRequester (Policy-Body 'r' 120)
Assert-Equal 'a REQUESTER cannot promise a backup (403 ERR-BKP-00403)' "$($deniedCreate.Status)/$($deniedCreate.Body.error_code)" '403/ERR-BKP-00403'
Assert-Equal 'a REQUESTER cannot read a policy (403)' (Invoke-Api GET "$bkp/$policy/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report a run (403)' (Invoke-Api POST "$bkp/run/initiate" $asRequester (Run-Body 'BACKUP' 'SUCCEEDED' (Minutes-Ago 500) (Minutes-Ago 490))).Status 403
Assert-Equal 'a REQUESTER cannot list the runs (403)' (Invoke-Api GET "$bkp/run/retrieve" $asRequester).Status 403
Assert-Equal 'another tenant gets a 404 for the policy' (Invoke-Api GET "$bkp/$policy/retrieve" $otherTenant).Status 404
Assert-Equal 'another tenant cannot report a run for it (404)' (Invoke-Api POST "$bkp/run/initiate" $otherTenant (Run-Body 'BACKUP' 'SUCCEEDED' (Minutes-Ago 500) (Minutes-Ago 490))).Status 404
Assert-Equal 'and finds no runs' @((Invoke-Api GET "$bkp/run/retrieve" $otherTenant).Body).Count 0
Assert-Equal 'there is no delete (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$bkp/$policy" $staff).Status) $true

# 8. The ledger.
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-backup-registry' })
    $recorded = $entries.Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing a tool said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*hunter2*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Backup smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
