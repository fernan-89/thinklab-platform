<#
.SYNOPSIS
  Live proof of the DR registry (Journey 14, last slice; DR registry ADR-030..033): disaster recovery plans through the platform gateway
  (PowerShell port of dr-smoke.sh).

.DESCRIPTION
  A plan is judged when read (never exercised, ready, an objective missed, the latest exercise partial or failed, paused), a walk through the runbook
  counts as a pass but measures nothing while a failover or a full recovery measures the recovery time and point, the same exercise reported by twenty
  reporters at once is one exercise, a later pass clears an earlier failure, a late report moves nothing forward, a plan that restores from a backup
  cannot promise to lose nothing, the runbook is an identifier and never a sentence, nothing a reporter says is repeated, two people pausing at once get
  one winner, staff only, the tenant, and every mutation on the ledger.

    pwsh -File .\dr-smoke.ps1
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

$dr = "$GatewayUrl/it-dr-registry/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString(); $user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $asset = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$reporter = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'dr-drill-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

# An instant that many minutes in the past (negative: in the future), to the millisecond, in UTC.
function Ago([double]$Minutes) { [DateTime]::UtcNow.AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
function Plan-Json([string]$Name, [string]$Strategy, [int]$Rto, [int]$Rpo, [int]$Every, [string]$Runbook = '') {
    $d = [ordered]@{ name = $Name; assetId = $asset; strategy = $Strategy; rtoMinutes = $Rto; rpoMinutes = $Rpo; testEveryDays = $Every }
    if ($Runbook) { $d.runbookRef = $Runbook }
    $d | ConvertTo-Json -Compress
}
function Exercise-Json([string]$Plan, [string]$Kind, [string]$Outcome, [string]$Started, [string]$Finished, $Loss = $null, [string]$Reason = '') {
    $d = [ordered]@{ planId = $Plan; kind = $Kind; outcome = $Outcome; startedAt = $Started; finishedAt = $Finished }
    if ($null -ne $Loss) { $d.dataLossMinutes = [int]$Loss }
    if ($Reason) { $d.failureReason = $Reason }
    $d | ConvertTo-Json -Compress
}
function Report($Body) { Invoke-Api POST "$dr/exercise/initiate" $reporter $Body }
# readiness/rtoMet/rpoMet, with None for what is not there (as the bash smoke shows it)
function Judged([string]$Id) {
    $d = (Invoke-Api GET "$dr/$Id/retrieve" $staff).Body
    $show = { param($v) if ($null -eq $v) { 'None' } else { "$v" } }
    "$($d.readiness)/$(& $show $d.rtoMet)/$(& $show $d.rpoMet)"
}
function Count([string]$Url, $Headers = $staff) { @((Invoke-Api GET $Url $Headers).Body).Count }

# 1. A plan: the promise, judged now, never exercised.
$created = Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Orders failover' 'WARM_STANDBY' 120 30 30 'KB-1042')
$plan = $created.Body.id
Assert-Equal 'a plan is created (201) and starts ACTIVE and NEVER_TESTED' "$($created.Status)/$($created.Body.status)/$($created.Body.readiness)" '201/ACTIVE/NEVER_TESTED'
$read = (Invoke-Api GET "$dr/$plan/retrieve" $staff).Body
Assert-Equal 'it keeps the strategy, the objectives, the interval and the runbook reference' "$($read.strategy)/$($read.rtoMinutes)/$($read.rpoMinutes)/$($read.testEveryDays)/$($read.runbookRef)" 'WARM_STANDBY/120/30/30/KB-1042'
$duplicate = Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Orders failover' 'WARM_STANDBY' 120 30 30)
Assert-Equal 'the same name again in the tenant is a 409' "$($duplicate.Status)/$($duplicate.Body.error_code)" '409/ERR-DRR-00409'

# 2. What a plan may not promise.
Assert-Equal 'a plan that restores from a backup cannot promise to lose no data (400)' (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Backup only' 'BACKUP_RESTORE' 120 0 30)).Status 400
Assert-Equal 'a standby plan can (201)' (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Active active' 'ACTIVE_ACTIVE' 5 0 30)).Status 201
Assert-Equal 'a runbook reference that is a sentence is refused (400)' (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Sentence' 'WARM_STANDBY' 120 30 30 'restart the database first')).Status 400
Assert-Equal 'an unknown strategy is a 400' (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'x' 'MAGIC' 1 1 1)).Status 400
Assert-Equal 'an exercise interval of zero days is a 400' (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Zero' 'WARM_STANDBY' 120 30 0)).Status 400

# 3. A pass inside the objectives: READY.
$start1 = Ago 300; $end1 = Ago 240
$first = Report (Exercise-Json $plan 'FAILOVER' 'SUCCEEDED' $start1 $end1 10)
Assert-Equal 'a passed exercise is stored (201) and its recovery took 60 minutes' "$($first.Status)/$($first.Body.durationMinutes)" '201/60'
Assert-Equal 'the plan is READY, the recovery time and point met' (Judged $plan) 'READY/True/True'
$again = Report (Exercise-Json $plan 'FAILOVER' 'SUCCEEDED' $start1 $end1 10)
Assert-Equal 'the same exercise reported again is the stored one (200, same id)' "$($again.Status)/$($again.Body.id)" "200/$($first.Body.id)"

# 4. Twenty reporters of one exercise.
$post = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$same = Exercise-Json $plan 'TABLETOP' 'SUCCEEDED' (Ago 200) (Ago 180)
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $post -ArgumentList "$dr/exercise/initiate", $tenantId, "dr-drill-$_", $same }
$jobs | Wait-Job | Out-Null; $jobs | Remove-Job
Assert-Equal 'twenty simultaneous reports of one exercise leave exactly one' (Count "$dr/exercise/retrieve?planId=$plan&kind=TABLETOP") 1

# 5. A partial exercise: the plan is not proved; a later pass clears it.
$partial = Report (Exercise-Json $plan 'FULL_RECOVERY' 'PARTIAL' (Ago 120) (Ago 90) 20 'DEPENDENCY_MISSING')
Assert-Equal 'a partial exercise is stored with its fixed reason' "$($partial.Status)/$($partial.Body.failureReason)" '201/DEPENDENCY_MISSING'
Assert-Equal 'the plan is LAST_EXERCISE_FAILED whatever passed before' (Judged $plan) 'LAST_EXERCISE_FAILED/True/True'
Report (Exercise-Json $plan 'FAILOVER' 'SUCCEEDED' (Ago 50) (Ago 20) 5) | Out-Null
Assert-Equal 'a later pass clears it' (Judged $plan) 'READY/True/True'

# 6. A late report moves nothing forward.
Report (Exercise-Json $plan 'FAILOVER' 'FAILED' (Ago 1500) (Ago 1400) $null 'TIMEOUT') | Out-Null
Assert-Equal 'an old failure reported late changes nothing' (Judged $plan) 'READY/True/True'
Assert-Equal 'the last exercise is the newest one, not the one reported last' (Invoke-Api GET "$dr/$plan/retrieve" $staff).Body.lastOutcome 'SUCCEEDED'

# 7. An objective missed: slow, or lossy.
$slow = (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Slow' 'PILOT_LIGHT' 60 30 30)).Body.id
Report (Exercise-Json $slow 'FAILOVER' 'SUCCEEDED' (Ago 300) (Ago 150) 5) | Out-Null
Assert-Equal 'a pass that took 150 minutes against a 60 minute objective misses it' (Judged $slow) 'OBJECTIVE_MISSED/False/True'
$lossy = (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Lossy' 'PILOT_LIGHT' 120 10 30)).Body.id
Report (Exercise-Json $lossy 'FAILOVER' 'SUCCEEDED' (Ago 100) (Ago 50) 45) | Out-Null
Assert-Equal 'a pass that lost 45 minutes of data against a 10 minute objective misses it' (Judged $lossy) 'OBJECTIVE_MISSED/True/False'
$quiet = (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Quiet' 'PILOT_LIGHT' 120 10 30)).Body.id
Report (Exercise-Json $quiet 'FAILOVER' 'SUCCEEDED' (Ago 100) (Ago 50)) | Out-Null
Assert-Equal 'a measured pass that did not say what it lost says nothing about the recovery point' (Judged $quiet) 'READY/True/None'

# 7b. A walk through the runbook counts as a pass but measures nothing.
$paper = (Invoke-Api POST "$dr/initiate" $staff (Plan-Json 'Paper' 'PILOT_LIGHT' 120 30 30)).Body.id
Report (Exercise-Json $paper 'TABLETOP' 'SUCCEEDED' (Ago 100) (Ago 80)) | Out-Null
Assert-Equal 'a passed tabletop makes the plan READY but says nothing about the objectives' (Judged $paper) 'READY/None/None'
Report (Exercise-Json $paper 'FAILOVER' 'SUCCEEDED' (Ago 60) (Ago 20) 8) | Out-Null
Assert-Equal 'a failover that follows measures them' (Judged $paper) 'READY/True/True'
Report (Exercise-Json $paper 'TABLETOP' 'SUCCEEDED' (Ago 15) (Ago 5)) | Out-Null
Assert-Equal 'a later tabletop leaves the measured pass alone' (Judged $paper) 'READY/True/True'

# 8. What an exercise may not say.
Assert-Equal 'a failed exercise needs a reason (400)' (Report (Exercise-Json $plan 'TABLETOP' 'FAILED' (Ago 70) (Ago 65))).Status 400
Assert-Equal 'a passed exercise carries no reason (400)' (Report (Exercise-Json $plan 'TABLETOP' 'SUCCEEDED' (Ago 70) (Ago 65) $null 'TIMEOUT')).Status 400
Assert-Equal 'an exercise that finishes before it starts is a 400' (Report (Exercise-Json $plan 'TABLETOP' 'SUCCEEDED' (Ago 60) (Ago 65))).Status 400
Assert-Equal 'an exercise that finishes in the future is a 400' (Report (Exercise-Json $plan 'TABLETOP' 'SUCCEEDED' (Ago 60) (Ago -60))).Status 400
$leak = Report (Exercise-Json $plan 'TABLETOP' 'FAILED' (Ago 70) (Ago 65) $null 'secret-hostname-db01')
Assert-Equal 'a reason outside the fixed list is a 400, and is not repeated' "$($leak.Status)/$($leak.Text -like '*secret-hostname*')" '400/False'
Assert-Equal 'an exercise for a plan that does not exist is a 404' (Report (Exercise-Json ([guid]::NewGuid().ToString()) 'TABLETOP' 'SUCCEEDED' (Ago 70) (Ago 65))).Status 404

# 9. Lists and filters.
Assert-Equal 'the plans of the tenant are listed oldest first' (@((Invoke-Api GET "$dr/retrieve" $staff).Body)[0].name) 'Orders failover'
$missed = @((Invoke-Api GET "$dr/retrieve?readiness=OBJECTIVE_MISSED" $staff).Body)
Assert-Equal 'the list filters on readiness' "$($missed.Count)/$((@($missed.readiness) | Sort-Object -Unique) -join '/')" '2/OBJECTIVE_MISSED'
Assert-Equal 'exercises are filtered by kind and outcome' (Count "$dr/exercise/retrieve?planId=$plan&outcome=PARTIAL") 1
Assert-Equal 'the exercise list asks for 1 to 200 and refuses 0 (400)' (Invoke-Api GET "$dr/exercise/retrieve?limit=0" $staff).Status 400
Assert-Equal 'the limit is honoured' (Count "$dr/exercise/retrieve?limit=1") 1

# 10. Pause, resume, update.
Assert-Equal 'a plan is paused (204) and no longer judged' "$((Invoke-Api PUT "$dr/$plan/control/pause" $staff).Status)/$(((Judged $plan) -split '/')[0])" '204/PAUSED'
Assert-Equal 'pausing a paused plan is a 409' (Invoke-Api PUT "$dr/$plan/control/pause" $staff).Status 409
Assert-Equal 'resuming it brings the judgment back' "$((Invoke-Api PUT "$dr/$plan/control/resume" $staff).Status)/$(((Judged $plan) -split '/')[0])" '204/READY'
$updated = (Invoke-Api PUT "$dr/$plan/update" $staff (Plan-Json 'Orders failover' 'ACTIVE_ACTIVE' 15 5 14)).Status
Assert-Equal 'update replaces the whole definition and leaves the exercises alone: the last measured pass took 30 minutes, so 15 is missed (204)' `
    "$updated/$((Invoke-Api GET "$dr/$plan/retrieve" $staff).Body.strategy)/$(((Judged $plan) -split '/')[0])" '204/ACTIVE_ACTIVE/OBJECTIVE_MISSED'
Invoke-Api PUT "$dr/$plan/update" $staff (Plan-Json 'Orders failover' 'ACTIVE_ACTIVE' 45 10 14) | Out-Null
Assert-Equal 'and an objective of 45 minutes is met by the same pass' (Judged $plan) 'READY/True/True'
$pause = {
    param($url, $tenant, $executor)
    try { $r = Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$dr/$lossy/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
Assert-Equal 'two people pausing at once get one winner (one 204, one 409)' ((@($jobs | Wait-Job | Receive-Job) | Sort-Object) -join '/') '204/409'
$jobs | Remove-Job
Assert-Equal 'the audit trail is initiated, paused, resumed and updated twice, in order' ((@((Invoke-Api GET "$dr/$plan/audit-log/retrieve" $staff).Body) | ForEach-Object { $_.action }) -join ',') 'INITIATED,PAUSED,RESUMED,UPDATED,UPDATED'

# 11. Staff only, the tenant.
$denied = Invoke-Api POST "$dr/initiate" $asRequester (Plan-Json 'r' 'WARM_STANDBY' 120 30 30)
Assert-Equal 'a REQUESTER cannot create a plan (403 ERR-DRR-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-DRR-00403'
Assert-Equal 'a REQUESTER cannot read a plan (403)' (Invoke-Api GET "$dr/$plan/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report an exercise (403)' (Invoke-Api POST "$dr/exercise/initiate" $asRequester (Exercise-Json $plan 'TABLETOP' 'SUCCEEDED' (Ago 70) (Ago 65))).Status 403
Assert-Equal 'another tenant gets a 404 for the plan and finds no exercise' "$((Invoke-Api GET "$dr/$plan/retrieve" $otherTenant).Status)/$(Count "$dr/exercise/retrieve" $otherTenant)" '404/0'
$deleted = (Invoke-Api DELETE "$dr/$plan" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -in 404, 405) $true

# 12. The ledger.
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-dr-registry' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-dr-registry' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing a reporter said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret-hostname*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("DR smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
