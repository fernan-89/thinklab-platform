<#
.SYNOPSIS
  Live proof of Journey 14, fourth service: the patch registry through the platform gateway (patch-registry ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8106, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a policy is a promise judged when read: a new one is ACTIVE and COMPLIANT, found by compliance and by asset;
    (2) the same patch reported by twenty scanners at once is ONE finding (one 201, nineteen 200);
    (3) a patch past its deadline makes the policy OVERDUE;
    (4) a waiver has a fixed reason and RUNS OUT BY ITSELF: COMPLIANT while it lasts, OVERDUE again afterwards with nobody doing anything;
        a reason in anyone's own words is refused (400) and not repeated;
    (5) two people waiving at once: one 204 and one 409;
    (6) applied is for good: reporting the same patch again answers 200 and never reopens it;
    (7) the policy: update, days out of order refused, two people pausing at once get one winner, the trails read in order;
    (8) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (9) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    powershell -File .\patch-smoke.ps1
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

function Days-Ago([double]$Days) { (Get-Date).ToUniversalTime().AddDays(-$Days).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
function Seconds-Ahead([int]$Seconds) { (Get-Date).ToUniversalTime().AddSeconds($Seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

$pch = "$GatewayUrl/it-patch-registry/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'scanner-1' }
$agent = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'update-agent-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Policy-Body([string]$Name, [int]$High = 7) { @{ name = $Name; assetId = $assetId; criticalDays = 2; highDays = $High; mediumDays = 30; lowDays = 90 } }
function Finding-Body([string]$Ref, [string]$Severity, [string]$Announced) { @{ policyId = $policy; patchRef = $Ref; severity = $Severity; announcedAt = $Announced } }
function Get-Policy { (Invoke-Api GET "$pch/$policy/retrieve" $staff).Body }
function Get-Finding([string]$Id) { (Invoke-Api GET "$pch/finding/$Id/retrieve" $staff).Body }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }

# 1. A policy is a promise, judged when read.
$created = Invoke-Api POST "$pch/initiate" $staff (Policy-Body 'Servers')
$policy = $created.Body.id
Assert-Equal 'staff promise 2/7/30/90 days: 201, ACTIVE, COMPLIANT with nothing open' "$($created.Status)/$($created.Body.status)/$($created.Body.compliance)" '201/ACTIVE/COMPLIANT'
Assert-Equal 'the list finds it by compliance and by asset' "$(@((Invoke-Api GET "$pch/retrieve?compliance=COMPLIANT&assetId=$assetId" $staff).Body)[0].id)/$(@((Invoke-Api GET "$pch/retrieve?assetId=$assetId" $staff).Body)[0].id)" "$policy/$policy"

# 2. A scanner reports; the same patch twenty times at once is one finding.
$fresh = Days-Ago 1
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$same = (Finding-Body 'KB5030211' 'HIGH' $fresh) | ConvertTo-Json
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$pch/finding/initiate", $tenantId, "scanner-$_", $same }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same patch reported by twenty scanners at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
$freshId = ($answers[0] -split '/')[1]
Assert-Equal 'every answer is the same finding' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'and the list holds exactly one finding for the policy' @((Invoke-Api GET "$pch/finding/retrieve?policyId=$policy" $staff).Body).Count 1
Assert-Equal 'within its 7 days the patch is open but not overdue, and the policy is COMPLIANT' "$((Get-Finding $freshId).overdue)/$((Get-Policy).compliance)/$((Get-Policy).openFindings)" 'False/COMPLIANT/1'

# 3. A patch past its deadline makes the policy OVERDUE.
$late = Invoke-Api POST "$pch/finding/initiate" $tool (Finding-Body 'CVE-2026-1234' 'CRITICAL' (Days-Ago 5))
$lateId = $late.Body.id
Assert-Equal 'a critical patch announced 5 days ago (2 days allowed) is reported: 201, overdue' "$($late.Status)/$($late.Body.overdue)" '201/True'
Assert-Equal 'the policy is OVERDUE with one overdue patch and the deadline that was missed' "$((Get-Policy).compliance)/$((Get-Policy).overdueFindings)/$($null -ne (Get-Policy).oldestOverdueDueAt)" 'OVERDUE/1/True'

# 4. A waiver has a fixed reason and runs out by itself.
Assert-Equal 'staff waive it for 4 seconds, accepted risk (204)' (Invoke-Api PUT "$pch/finding/$lateId/control/waive" $staff @{ reason = 'ACCEPTED_RISK'; until = (Seconds-Ahead 4) }).Status 204
Assert-Equal 'while the waiver lasts, the patch is out of the count: COMPLIANT, one waived' "$((Get-Finding $lateId).status)/$((Get-Policy).compliance)/$((Get-Policy).waivedFindings)" 'WAIVED/COMPLIANT/1'
Start-Sleep -Seconds 6
Assert-Equal 'when it ran out, with nobody doing anything, the policy is OVERDUE again' "$((Get-Policy).compliance)/$((Get-Policy).overdueFindings)/$((Get-Policy).waivedFindings)" 'OVERDUE/1/0'
$freeText = Invoke-Api PUT "$pch/finding/$lateId/control/waive" $staff @{ reason = 'password=hunter2'; until = (Seconds-Ahead 600) }
Assert-Equal "a waiver in anyone's own words is refused (400)" $freeText.Status 400
Assert-Equal 'and the answer does not repeat it' ($freeText.Text -like '*hunter2*') $false

# 5. Two people waive at once: one wins. (A waiver that ran out is withdrawn first.)
Assert-Equal 'the expired waiver is withdrawn (204)' (Invoke-Api PUT "$pch/finding/$lateId/control/unwaive" $staff).Status 204
Assert-Equal 'a waiver that ends in the past is refused (400)' (Invoke-Api PUT "$pch/finding/$lateId/control/waive" $staff @{ reason = 'ACCEPTED_RISK'; until = (Days-Ago 1) }).Status 400
$waive = {
    param($url, $tenant, $executor, $body)
    try { [string][int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [string][int]$_.Exception.Response.StatusCode }
}
$waiveBody = @{ reason = 'COMPENSATING_CONTROL'; until = (Seconds-Ahead 3600) } | ConvertTo-Json
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $waive -ArgumentList "$pch/finding/$lateId/control/waive", $tenantId, ([guid]::NewGuid().ToString()), $waiveBody }
$waiveCodes = @($jobs | Wait-Job | Receive-Job | Sort-Object)
$jobs | Remove-Job
Assert-Equal 'two people waiving at once: one 204 and one 409' ($waiveCodes -join '/') '204/409'
Assert-Equal 'the waiver is withdrawn (204) and the patch is pending again' "$((Invoke-Api PUT "$pch/finding/$lateId/control/unwaive" $staff).Status)/$((Get-Finding $lateId).status)" '204/PENDING'

# 6. Applied is for good.
Assert-Equal 'the update agent reports it applied (204)' (Invoke-Api PUT "$pch/finding/$lateId/control/apply" $agent).Status 204
Assert-Equal 'the finding is APPLIED and the policy is COMPLIANT again' "$((Get-Finding $lateId).status)/$((Get-Policy).compliance)" 'APPLIED/COMPLIANT'
$again = Invoke-Api POST "$pch/finding/initiate" $tool (Finding-Body 'CVE-2026-1234' 'CRITICAL' (Days-Ago 5))
Assert-Equal 'the scanner reports the same patch again: 200, still APPLIED, never reopened' "$($again.Status)/$($again.Body.status)" '200/APPLIED'
Assert-Equal 'applying it twice is a conflict (409)' (Invoke-Api PUT "$pch/finding/$lateId/control/apply" $agent).Status 409
Assert-Equal 'a reference that is a sentence is refused (400)' (Invoke-Api POST "$pch/finding/initiate" $tool (Finding-Body 'disk /dev/sda1 is full' 'LOW' $fresh)).Status 400
Assert-Equal 'a patch announced in the future is refused (400)' (Invoke-Api POST "$pch/finding/initiate" $tool (Finding-Body 'KB9' 'LOW' (Seconds-Ahead 7200))).Status 400
Assert-Equal 'the trail of the finding holds each real change once, in order' (Actions "$pch/finding/$lateId/audit-log/retrieve") 'REPORTED,WAIVED,UNWAIVED,WAIVED,UNWAIVED,APPLIED'

# 7. The policy.
Assert-Equal 'a tighter high of 3 days (update, 204)' (Invoke-Api PUT "$pch/$policy/update" $staff (Policy-Body 'Servers' 3)).Status 204
Assert-Equal 'days out of order are refused (400)' (Invoke-Api PUT "$pch/$policy/update" $staff @{ name = 'Servers'; assetId = $assetId; criticalDays = 10; highDays = 3; mediumDays = 30; lowDays = 90 }).Status 400
$pause = {
    param($url, $tenant, $executor)
    try { [string][int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [string][int]$_.Exception.Response.StatusCode }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$pch/$policy/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
$pauseCodes = @($jobs | Wait-Job | Receive-Job | Sort-Object)
$jobs | Remove-Job
Assert-Equal 'two people pausing at once: one 204 and one 409' ($pauseCodes -join '/') '204/409'
Assert-Equal 'a paused policy is not judged' "$((Get-Policy).status)/$((Get-Policy).compliance)" 'PAUSED/PAUSED'
Assert-Equal 'resume' (Invoke-Api PUT "$pch/$policy/control/resume" $staff).Status 204
Assert-Equal 'the policy trail holds each real change once, in order' (Actions "$pch/$policy/audit-log/retrieve") 'INITIATED,UPDATED,PAUSED,RESUMED'

# 8. Staff only, the tenant.
$deniedCreate = Invoke-Api POST "$pch/initiate" $asRequester (Policy-Body 'r')
Assert-Equal 'a REQUESTER cannot promise (403 ERR-PCH-00403)' "$($deniedCreate.Status)/$($deniedCreate.Body.error_code)" '403/ERR-PCH-00403'
Assert-Equal 'a REQUESTER cannot read a policy (403)' (Invoke-Api GET "$pch/$policy/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report a finding (403)' (Invoke-Api POST "$pch/finding/initiate" $asRequester (Finding-Body 'KB1' 'LOW' $fresh)).Status 403
Assert-Equal 'a REQUESTER cannot list the findings (403)' (Invoke-Api GET "$pch/finding/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot waive (403)' (Invoke-Api PUT "$pch/finding/$freshId/control/waive" $asRequester @{ reason = 'ACCEPTED_RISK'; until = (Seconds-Ahead 600) }).Status 403
Assert-Equal 'another tenant gets a 404 for the policy' (Invoke-Api GET "$pch/$policy/retrieve" $otherTenant).Status 404
Assert-Equal 'another tenant cannot report a finding for it (404)' (Invoke-Api POST "$pch/finding/initiate" $otherTenant (Finding-Body 'KB1' 'LOW' $fresh)).Status 404
Assert-Equal 'and finds no findings' @((Invoke-Api GET "$pch/finding/retrieve" $otherTenant).Body).Count 0
Assert-Equal 'there is no delete (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$pch/$policy" $staff).Status) $true

# 9. The ledger.
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-patch-registry' })
    $recorded = $entries.Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*hunter2*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Patch smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
