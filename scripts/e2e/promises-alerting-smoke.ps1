<#
.SYNOPSIS
  Live proof of alerting on broken promises (alerting ADR-037) through the platform gateway, against the REAL patch, capacity and backup registries
  and the REAL incident service.

.DESCRIPTION
  Needs the stack up. Uses its own tenant id, then drives, through the GATEWAY:
    (1) an overdue patch, a disk at 96 of 100 and a backup that never ran are three promises judged by their registries;
    (2) a rule keeps the registry it watches (PATCH, CAPACITY, or the health checks when it says nothing); an unknown source is refused (400) and
        a REQUESTER is refused (403);
    (3) the overdue patch and the CRITICAL disk each open ONE alert and ONE incident that says a promise is not being kept, with a fixed error
        code and the asset of the policy; a second evaluation opens nothing;
    (4) a backup that has never run is not judged: a rule for the backup registry opens nothing;
    (5) the promises kept again (a waiver, a newer sample) resolve both alerts and the incidents are not closed.

    pwsh -File .\promises-alerting-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088'
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

function Ahead([double]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

$alr = "$GatewayUrl/it-alerting/v1"; $pch = "$GatewayUrl/it-patch-registry/v1"; $cap = "$GatewayUrl/it-capacity-registry/v1"
$bkp = "$GatewayUrl/it-backup-registry/v1"; $inc = "$GatewayUrl/it-incident-management/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString()
$patchAsset = [guid]::NewGuid().ToString(); $diskAsset = [guid]::NewGuid().ToString(); $backupAsset = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'scanner-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $filedFor; 'X-Role' = 'REQUESTER' }

function Evaluate { $r = (Invoke-Api PUT "$alr/evaluation/execute" $staff).Body; "$($r.opened)/$($r.resolved)/$($r.incidentsOpened)" }
function AlertOf($checkId) { @((Invoke-Api GET "$alr/retrieve?checkId=$checkId" $staff).Body)[0] }
function Rule-Body($name, $source, $checkId = $null) {
    $b = [ordered]@{ name = $name; source = $source; impact = 'HIGH'; urgency = 'MEDIUM'; requesterId = $filedFor }
    if ($checkId) { $b.checkId = $checkId }
    $b | ConvertTo-Json
}

# 1. Three promises: an overdue patch, a disk at 96 of 100, a backup that never ran (not yet judged).
$patch = (Invoke-Api POST "$pch/initiate" $staff @{ name = 'Servers'; assetId = $patchAsset; criticalDays = 2; highDays = 7; mediumDays = 30; lowDays = 90 }).Body.id
$finding = (Invoke-Api POST "$pch/finding/initiate" $tool @{ policyId = $patch; patchRef = 'CVE-2026-1234'; severity = 'CRITICAL'; announcedAt = (Ahead -7200) }).Body.id
$disk = (Invoke-Api POST "$cap/initiate" $staff @{ name = 'Orders disk'; assetId = $diskAsset; metric = 'DISK'; limit = 100; warnPercent = 70; criticalPercent = 90; windowDays = 30; horizonDays = 30; reportEveryHours = 24 }).Body.id
[void](Invoke-Api POST "$cap/sample/initiate" $tool @{ policyId = $disk; value = 96; measuredAt = (Ahead -5) })
$backup = (Invoke-Api POST "$bkp/initiate" $staff @{ name = 'Database nightly'; assetId = $backupAsset; frequencyHours = 24; rpoHours = 48; rtoMinutes = 120; retentionDays = 30 }).Body.id
Assert-Equal 'the patch is OVERDUE, the disk CRITICAL and the backup, which never ran, NEVER' "$((Invoke-Api GET "$pch/$patch/retrieve" $staff).Body.compliance)/$((Invoke-Api GET "$cap/$disk/retrieve" $staff).Body.level)/$((Invoke-Api GET "$bkp/$backup/retrieve" $staff).Body.protection)" 'OVERDUE/CRITICAL/NEVER'

# 2. Rules keep their source; staff only; an unknown source is refused.
Assert-Equal 'no rule yet: an evaluation opens nothing' (Evaluate) '0/0/0'
Assert-Equal 'a rule with an unknown source is refused (400)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Printers' 'PRINTERS')).Status 400
Assert-Equal 'a REQUESTER cannot set a rule for the registries (403)' (Invoke-Api POST "$alr/rule/initiate" $asRequester (Rule-Body 'Patches' 'PATCH')).Status 403
$patchRule = (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Patches' 'PATCH')).Body
Assert-Equal 'a rule for the patch registry keeps its source and covers every policy' "$($patchRule.source)/$($patchRule.checkId)" 'PATCH/'
Assert-Equal 'a rule for one disk policy keeps its source and its policy (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Orders disk only' 'CAPACITY' $disk)).Status 201
Assert-Equal 'a rule for a policy that is not the disk (a stranger id) watches nothing (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Stranger' 'CAPACITY' ([guid]::NewGuid().ToString()))).Status 201
Assert-Equal 'and a rule with no source is a health check rule' (Invoke-Api POST "$alr/rule/initiate" $staff @{ name = 'Checks'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }).Body.source 'HEALTH_CHECK'

# 3. One alert and one incident per broken promise; the backup, which no rule watches, is not judged.
Assert-Equal 'the patch and the disk each open one alert and one incident' (Evaluate) '2/0/2'
Assert-Equal 'a second evaluation opens nothing more' (Evaluate) '0/0/0'
Assert-Equal 'two alerts and two incidents, and none for the backup' "$(@((Invoke-Api GET "$alr/retrieve" $staff).Body).Count)/$(@((Invoke-Api GET "$inc/retrieve" $staff).Body).Count)/$(@((Invoke-Api GET "$alr/retrieve?checkId=$backup" $staff).Body).Count)" '2/2/0'
$patchAlert = AlertOf $patch
Assert-Equal 'the patch alert is OPEN, names the policy and the fixed code, and has its incident' "$($patchAlert.status)/$($patchAlert.checkName)/$($patchAlert.lastError)/$([bool]$patchAlert.incidentId)" 'OPEN/Servers/PATCH_OVERDUE/True'
$diskAlert = AlertOf $disk
Assert-Equal 'the disk alert says CAPACITY_CRITICAL' "$($diskAlert.checkName)/$($diskAlert.lastError)" 'Orders disk/CAPACITY_CRITICAL'
$incident = (Invoke-Api GET "$inc/$($patchAlert.incidentId)/retrieve" $staff).Body
Assert-Equal 'the incident says a promise is not being kept, for the asset of the policy' "$($incident.title)/$($incident.description.Contains('is not being kept (PATCH_OVERDUE)'))/$($incident.affectedAssetIds -join ',')" "Promise broken: Servers/True/$patchAsset"

# 4. A rule for the backup registry: a backup that has never run is not judged, so it opens nothing.
Assert-Equal 'a rule for the backup registry is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Backups' 'BACKUP')).Status 201
Assert-Equal 'a backup that never ran is not a broken promise: nothing opens' (Evaluate) '0/0/0'

# 5. Kept again: a waiver and a newer sample resolve the alerts and the incidents are not closed.
Assert-Equal 'the patch is waived for ten minutes, accepted risk (204)' (Invoke-Api PUT "$pch/finding/$finding/control/waive" $staff @{ reason = 'ACCEPTED_RISK'; until = (Ahead 10) }).Status 204
Assert-Equal 'a newer sample at 40 is reported (201)' (Invoke-Api POST "$cap/sample/initiate" $tool @{ policyId = $disk; value = 40; measuredAt = (Ahead -1) }).Status 201
Assert-Equal 'both promises are kept again: two alerts resolved, nothing opened' (Evaluate) '0/2/0'
Assert-Equal 'the alerts are RESOLVED and the incidents were not closed' "$((AlertOf $patch).status)/$((AlertOf $disk).status)/$((Invoke-Api GET "$inc/$($patchAlert.incidentId)/retrieve" $staff).Body.status)" 'RESOLVED/RESOLVED/NEW'
Assert-Equal 'and a further evaluation changes nothing' (Evaluate) '0/0/0'

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Promises alerting smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
