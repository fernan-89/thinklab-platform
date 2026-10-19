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
    (5) the promises kept again (a waiver, a newer sample) resolve both alerts and the incidents are not closed;
    (6) a vendor agreement about to end opens one alert and one incident (ADR-038), and a renewal resolves it;
    (7) a licence over its limit opens one alert and one incident (ADR-039), and freed seats resolve it;
    (8) a recovery plan whose exercise failed opens one alert and one incident (ADR-041), and a later pass resolves it;
    (9) a cloud resource the tool has not seen for days opens one alert and one incident (ADR-042), seeing it again resolves it, and a terminated one opens nothing
        (the smoke moves the moment the tool last saw the resource back in the store with docker exec on the MongoDB container, MONGO_CONTAINER, the way two days passing would).

    pwsh -File .\promises-alerting-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$MongoContainer = 'thinklab-mongo-1'
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
$bkp = "$GatewayUrl/it-backup-registry/v1"; $vnd = "$GatewayUrl/it-vendor-registry/v1"; $lic = "$GatewayUrl/it-license-registry/v1"; $dr = "$GatewayUrl/it-dr-registry/v1"; $invReg = "$GatewayUrl/it-cloud-inventory/v1"; $inc = "$GatewayUrl/it-incident-management/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString()
$patchAsset = [guid]::NewGuid().ToString(); $diskAsset = [guid]::NewGuid().ToString(); $backupAsset = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'scanner-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $filedFor; 'X-Role' = 'REQUESTER' }

# The alerting scheduler also evaluates every few seconds, so a check never relies on what one evaluation did: it evaluates, then waits for the state.
function Wait-For([int]$Seconds, [scriptblock]$Condition) { $end = (Get-Date).AddSeconds($Seconds); while ((Get-Date) -lt $end) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 500 }; return [bool](& $Condition) }
function Alerts-Are([string]$Expected) { "$(@((Invoke-Api GET "$alr/retrieve" $staff).Body).Count)/$(@((Invoke-Api GET "$inc/retrieve" $staff).Body).Count)" -eq $Expected }
function Status-Is($CheckId, [string]$Expected) { $a = @((Invoke-Api GET "$alr/retrieve?checkId=$CheckId" $staff).Body); ($a.Count -gt 0) -and ($a[0].status -eq $Expected) }
function Linked($CheckId) { $a = @((Invoke-Api GET "$alr/retrieve?checkId=$CheckId" $staff).Body); ($a.Count -gt 0) -and [bool]$a[0].incidentId }
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
[void](Evaluate)
Assert-Equal 'the patch and the disk each get one alert and one incident (by an evaluation or by the scheduler)' (Wait-For 20 { Alerts-Are '2/2' }) $true
[void](Evaluate)
Assert-Equal 'more evaluations open nothing more' (Alerts-Are '2/2') $true
Assert-Equal 'two alerts and two incidents, and none for the backup' "$(@((Invoke-Api GET "$alr/retrieve" $staff).Body).Count)/$(@((Invoke-Api GET "$inc/retrieve" $staff).Body).Count)/$(@((Invoke-Api GET "$alr/retrieve?checkId=$backup" $staff).Body).Count)" '2/2/0'
$patchAlert = AlertOf $patch
Assert-Equal 'the patch alert is OPEN, names the policy and the fixed code, and has its incident' "$($patchAlert.status)/$($patchAlert.checkName)/$($patchAlert.lastError)/$([bool]$patchAlert.incidentId)" 'OPEN/Servers/PATCH_OVERDUE/True'
$diskAlert = AlertOf $disk
Assert-Equal 'the disk alert says CAPACITY_CRITICAL' "$($diskAlert.checkName)/$($diskAlert.lastError)" 'Orders disk/CAPACITY_CRITICAL'
$incident = (Invoke-Api GET "$inc/$($patchAlert.incidentId)/retrieve" $staff).Body
Assert-Equal 'the incident says a promise is not being kept, for the asset of the policy' "$($incident.title)/$($incident.description.Contains('is not being kept (PATCH_OVERDUE)'))/$($incident.affectedAssetIds -join ',')" "Promise broken: Servers/True/$patchAsset"

# 4. A rule for the backup registry: a backup that has never run is not judged, so it opens nothing.
Assert-Equal 'a rule for the backup registry is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Backups' 'BACKUP')).Status 201
[void](Evaluate)
Assert-Equal 'a backup that never ran is not a broken promise: nothing opens' (Alerts-Are '2/2') $true

# 5. Kept again: a waiver and a newer sample resolve the alerts and the incidents are not closed.
Assert-Equal 'the patch is waived for ten minutes, accepted risk (204)' (Invoke-Api PUT "$pch/finding/$finding/control/waive" $staff @{ reason = 'ACCEPTED_RISK'; until = (Ahead 10) }).Status 204
Assert-Equal 'a newer sample at 40 is reported (201)' (Invoke-Api POST "$cap/sample/initiate" $tool @{ policyId = $disk; value = 40; measuredAt = (Ahead -1) }).Status 201
[void](Evaluate)
Assert-Equal 'both promises are kept again: both alerts are resolved, nothing opened' ((Wait-For 20 { Status-Is $patch 'RESOLVED' }) -and (Wait-For 20 { Status-Is $disk 'RESOLVED' }) -and (Alerts-Are '2/2')) $true
Assert-Equal 'the alerts are RESOLVED and the incidents were not closed' "$((AlertOf $patch).status)/$((AlertOf $disk).status)/$((Invoke-Api GET "$inc/$($patchAlert.incidentId)/retrieve" $staff).Body.status)" 'RESOLVED/RESOLVED/NEW'
[void](Evaluate)
Assert-Equal 'and a further evaluation changes nothing' (Alerts-Are '2/2') $true

# 6. A vendor agreement about to end (ADR-038): one alert and one incident; a renewal resolves it.
function Day([int]$Days) { (Get-Date).ToUniversalTime().Date.AddDays($Days).ToString('yyyy-MM-dd') }
$vendorId = (Invoke-Api POST "$vnd/initiate" $staff @{ name = 'Dell'; category = 'HARDWARE' }).Body.id
$agreement = (Invoke-Api POST "$vnd/agreement/initiate" $staff @{ vendorId = $vendorId; kind = 'WARRANTY'; reference = 'WTY-77'; assetId = $patchAsset; startsOn = (Day -300); endsOn = (Day 10); noticeDays = 30; autoRenew = $false }).Body.id
Assert-Equal 'a warranty ending in 10 days with 30 days of notice is EXPIRING' (Invoke-Api GET "$vnd/agreement/$agreement/retrieve" $staff).Body.standing 'EXPIRING'
Assert-Equal 'a rule for the vendor registry is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Agreements' 'VENDOR')).Status 201
[void](Evaluate)
Assert-Equal 'the agreement about to end gets one alert and one incident' (Wait-For 20 { Linked $agreement }) $true
$agreementAlert = AlertOf $agreement
Assert-Equal 'the alert names the reference and AGREEMENT_EXPIRING, and the incident says so' "$($agreementAlert.checkName)/$($agreementAlert.lastError)/$((Invoke-Api GET "$inc/$($agreementAlert.incidentId)/retrieve" $staff).Body.title)" 'WTY-77/AGREEMENT_EXPIRING/Promise broken: WTY-77'
Assert-Equal 'the warranty is renewed for two years (204)' (Invoke-Api PUT "$vnd/agreement/$agreement/update" $staff @{ kind = 'WARRANTY'; assetId = $patchAsset; startsOn = (Day -300); endsOn = (Day 730); noticeDays = 30; autoRenew = $false }).Status 204
[void](Evaluate)
Assert-Equal 'the renewal resolves the alert' (Wait-For 20 { Status-Is $agreement 'RESOLVED' }) $true
Assert-Equal 'the alert is RESOLVED' (AlertOf $agreement).status 'RESOLVED'

# 7. A licence over its limit (ADR-039): one alert and one incident; seats freed resolve it.
function CountAt([int]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
$license = (Invoke-Api POST "$lic/initiate" $staff @{ product = 'Office 365 E3'; unit = 'USER'; entitled = 10; warnPercent = 90; reportEveryHours = 24 }).Body.id
Assert-Equal '12 seats in use of 10 bought is OVER_LIMIT' "$((Invoke-Api POST "$lic/usage/initiate" $tool @{ licenseId = $license; inUse = 12; measuredAt = (CountAt 10) }).Status)/$((Invoke-Api GET "$lic/$license/retrieve" $staff).Body.level)" '201/OVER_LIMIT'
Assert-Equal 'a rule for the licence registry is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Licences' 'LICENSE')).Status 201
[void](Evaluate)
Assert-Equal 'the licence over its limit gets one alert and one incident' (Wait-For 20 { Linked $license }) $true
$licenseAlert = AlertOf $license
Assert-Equal 'the alert names the product and LICENSE_OVER_LIMIT' "$($licenseAlert.checkName)/$($licenseAlert.lastError)" 'Office 365 E3/LICENSE_OVER_LIMIT'
Assert-Equal 'seats are freed: 9 in use is reported (201)' (Invoke-Api POST "$lic/usage/initiate" $tool @{ licenseId = $license; inUse = 9; measuredAt = (CountAt 1) }).Status 201
[void](Evaluate)
Assert-Equal 'back within the limit (NEAR_LIMIT is not an incident): the alert is resolved' (Wait-For 20 { Status-Is $license 'RESOLVED' }) $true

# 8. A recovery plan that stops being ready (ADR-041): a failed exercise opens one alert and one incident, a later pass resolves it.
function MinutesFromNow([int]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
$plan = (Invoke-Api POST "$dr/initiate" $staff @{ name = 'Orders failover'; assetId = $patchAsset; strategy = 'WARM_STANDBY'; rtoMinutes = 120; rpoMinutes = 30; testEveryDays = 30 }).Body.id
Assert-Equal 'a plan never exercised is NEVER_TESTED' (Invoke-Api GET "$dr/$plan/retrieve" $staff).Body.readiness 'NEVER_TESTED'
Assert-Equal 'a rule for the DR registry is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Recovery plans' 'DR')).Status 201
[void](Evaluate)
Assert-Equal 'a plan never exercised is not judged: nothing opens' @((Invoke-Api GET "$alr/retrieve?checkId=$plan" $staff).Body).Count 0
Assert-Equal 'a failover that failed is reported with its fixed reason (201)' (Invoke-Api POST "$dr/exercise/initiate" $tool @{ planId = $plan; kind = 'FAILOVER'; outcome = 'FAILED'; startedAt = (MinutesFromNow -120); finishedAt = (MinutesFromNow -100); failureReason = 'DEPENDENCY_MISSING' }).Status 201
Assert-Equal 'the plan is LAST_EXERCISE_FAILED' (Invoke-Api GET "$dr/$plan/retrieve" $staff).Body.readiness 'LAST_EXERCISE_FAILED'
[void](Evaluate)
Assert-Equal 'the plan gets one alert and one incident' (Wait-For 20 { Linked $plan }) $true
$planAlert = AlertOf $plan
$planIncident = (Invoke-Api GET "$inc/$($planAlert.incidentId)/retrieve" $staff).Body
Assert-Equal 'the alert names the plan and the fixed code DR_EXERCISE_FAILED, and the incident says a promise is not being kept' "$($planAlert.checkName)/$($planAlert.lastError)/$($planIncident.title)/$($planIncident.description -like '*is not being kept (DR_EXERCISE_FAILED)*')" 'Orders failover/DR_EXERCISE_FAILED/Promise broken: Orders failover/True'
[void](Evaluate)
Assert-Equal 'more evaluations open nothing more for the plan' @((Invoke-Api GET "$alr/retrieve?checkId=$plan" $staff).Body).Count 1
Assert-Equal 'a later failover that passed inside the objectives is reported (201)' (Invoke-Api POST "$dr/exercise/initiate" $tool @{ planId = $plan; kind = 'FAILOVER'; outcome = 'SUCCEEDED'; startedAt = (MinutesFromNow -60); finishedAt = (MinutesFromNow -30); dataLossMinutes = 5 }).Status 201
Assert-Equal 'the plan is READY again' (Invoke-Api GET "$dr/$plan/retrieve" $staff).Body.readiness 'READY'
[void](Evaluate)
Assert-Equal 'the pass resolves the alert' (Wait-For 20 { Status-Is $plan 'RESOLVED' }) $true

# 9. A cloud resource that goes missing (ADR-042). The inventory judges a resource missing after 48 hours of silence, so the smoke moves the moment the tool last
# saw it back in the store, the way two days passing would; everything else goes through the gateway.
$account = [guid]::NewGuid().ToString()
function Resource-Body([string]$ExternalId, [string]$Name, [string]$State) { @{ accountId = $account; provider = 'AWS'; externalId = $ExternalId; name = $Name; kind = 'COMPUTE'; region = 'us-east-1'; state = $State; tags = @{} } }
function Report-Resource([string]$ExternalId, [string]$Name, [string]$State) { Invoke-Api POST "$invReg/initiate" $tool (Resource-Body $ExternalId $Name $State) }
function Age([string]$Id) { docker exec $MongoContainer mongosh --quiet --eval "db.getSiblingDB('thinklab_it_cloud_inventory_db').cloud_resources.updateOne({_id: UUID('$Id')}, {`$set: {lastSeenAt: new Date(Date.now() - 5 * 24 * 3600 * 1000)}})" | Out-Null }
$vm = (Report-Resource 'i-0missing' 'web-1' 'RUNNING').Body.id
Assert-Equal 'a resource the tool saw just now is PRESENT' (Invoke-Api GET "$invReg/$vm/retrieve" $staff).Body.presence 'PRESENT'
Assert-Equal 'a rule for the cloud inventory is set (201)' (Invoke-Api POST "$alr/rule/initiate" $staff (Rule-Body 'Cloud resources' 'CLOUD_INVENTORY')).Status 201
[void](Evaluate)
Assert-Equal 'a resource seen lately opens nothing' @((Invoke-Api GET "$alr/retrieve?checkId=$vm" $staff).Body).Count 0
Age $vm
Assert-Equal 'five days of silence: the inventory says MISSING' (Invoke-Api GET "$invReg/$vm/retrieve" $staff).Body.presence 'MISSING'
[void](Evaluate)
Assert-Equal 'the resource gets one alert and one incident' (Wait-For 20 { Linked $vm }) $true
$vmAlert = AlertOf $vm
Assert-Equal 'the alert names the resource and the fixed code CLOUD_RESOURCE_MISSING, and carries no provider id' "$($vmAlert.checkName)/$($vmAlert.lastError)/$((($vmAlert | ConvertTo-Json -Depth 6) -like '*i-0missing*'))" 'web-1/CLOUD_RESOURCE_MISSING/False'
[void](Evaluate)
Assert-Equal 'more evaluations open nothing more for the resource' @((Invoke-Api GET "$alr/retrieve?checkId=$vm" $staff).Body).Count 1
[void](Report-Resource 'i-0missing' 'web-1' 'RUNNING')
Assert-Equal 'the tool sees it again: PRESENT' (Invoke-Api GET "$invReg/$vm/retrieve" $staff).Body.presence 'PRESENT'
[void](Evaluate)
Assert-Equal 'seeing it again resolves the alert' (Wait-For 20 { Status-Is $vm 'RESOLVED' }) $true
$gone = (Report-Resource 'i-0gone' 'old-1' 'RUNNING').Body.id
Age $gone
[void](Report-Resource 'i-0gone' 'old-1' 'TERMINATED')
Assert-Equal 'a resource the tool said is terminated is GONE' (Invoke-Api GET "$invReg/$gone/retrieve" $staff).Body.presence 'GONE'
[void](Evaluate)
Assert-Equal 'a terminated resource opens nothing, however long ago it was seen' @((Invoke-Api GET "$alr/retrieve?checkId=$gone" $staff).Body).Count 0

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Promises alerting smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
