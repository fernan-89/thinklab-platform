<#
.SYNOPSIS
  Live proof of it-change-management's two synchronous cross-service integrations (ADR-032): a NORMAL
  change routed to CAB and resolved APPROVED by a real quorum on workflow-approval-service, an
  EMERGENCY change vetoed REJECTED by a single ECAB decision, and a real scheduling collision surfaced
  by operation-window-service's existing collision detection (ADR-033).

.DESCRIPTION
  Needs the CAB/ECAB ApprovalPolicy ids start-local-stack.ps1 provisions and writes to
  thinklab-platform\.e2e\change-management-policies.json - run that script (with -Build) first so
  it-change-management starts with THINKLAB_CAB_POLICY_ID/THINKLAB_ECAB_POLICY_ID already set:

    .\start-local-stack.ps1 -Build
    powershell -File .\change-management-smoke.ps1

  It creates an Organisation and an Asset, then: (1) drives a NORMAL change through CAB_REVIEW to a
  quorum-reached APPROVED, schedules its implementation window on operation-window-service and closes
  it; (2) drives an EMERGENCY change to ECAB_REVIEW and vetoes it REJECTED with a single decision;
  (3) schedules a second change against the same asset with an overlapping window and confirms
  operation-window-service's 409 collision surfaces as this service's own ERR-CHG-00409.
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
    [string]$AssetUrl = 'http://localhost:8083',
    [string]$ChangeManagementUrl = 'http://localhost:8086',
    [string]$OperationWindowUrl = 'http://localhost:8084',
    [string]$PoliciesFile = (Join-Path $PSScriptRoot '..\..\.e2e\change-management-policies.json')
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

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ($Actual -eq $Expected)
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

if (-not (Test-Path $PoliciesFile)) { throw "Missing $PoliciesFile - run start-local-stack.ps1 -Build first (it provisions the CAB/ECAB policies)." }
$policies = Get-Content $PoliciesFile -Raw | ConvertFrom-Json

$org = "$OrgUrl/party-reference-data-directory/v1"
$asset = "$AssetUrl/it-asset-registry/v1"
$chg = "$ChangeManagementUrl/it-change-management/v1"
$executorHeader = @{ 'X-Executor' = 'change-management-smoke' }

# 1. A real Organisation and a real Asset to be the change's target.
$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$orgResponse = Invoke-Api POST "$org/initiate" $executorHeader @{ corporateName = 'GMUD Corp'; tradeName = 'GMUD'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@gmud.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created' $orgResponse 201
$orgId = $orgResponse.Body.id
$tenantAndExecutor = $executorHeader + @{ 'X-Tenant-Id' = $orgId }

$serial = "SN-GMUD-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$assetResponse = Invoke-Api POST "$asset/initiate" $tenantAndExecutor @{ name = 'Core switch'; category = 'NETWORK_DEVICE'; serialNumber = $serial; specifications = @{ model = 'SW-9000' } }
Assert-Status 'asset created' $assetResponse 201
$assetId = $assetResponse.Body.id
$requesterId = [guid]::NewGuid().ToString()

# 2. NORMAL change -> CAB_REVIEW -> quorum-reached APPROVED -> scheduled -> implemented -> closed.
$normalResponse = Invoke-Api POST "$chg/initiate" $tenantAndExecutor @{ requesterId = $requesterId; title = 'Upgrade switch firmware'; description = 'Routine firmware bump'; changeType = 'NORMAL'; targetAssetIds = @($assetId) }
Assert-Status 'NORMAL change initiated (DRAFT)' $normalResponse 201
$normalId = $normalResponse.Body.id

Assert-Status 'control/submit (DRAFT -> SUBMITTED)' (Invoke-Api PUT "$chg/$normalId/control/submit" $executorHeader) 204
Assert-Status 'assess (SUBMITTED -> ASSESSED)' (Invoke-Api PUT "$chg/$normalId/assess" $executorHeader @{ riskLevel = 'MEDIUM'; impactLevel = 'MEDIUM' }) 204
Assert-Status 'route-for-approval (ASSESSED -> CAB_REVIEW)' (Invoke-Api PUT "$chg/$normalId/route-for-approval" $executorHeader) 204

$afterRouting = Invoke-Api GET "$chg/$normalId/retrieve" $executorHeader
Assert-Equal 'status after routing is CAB_REVIEW' $afterRouting.Body.status 'CAB_REVIEW'
Assert-Status 'approvalRequestId was recorded' ([pscustomobject]@{ Status = $(if ($afterRouting.Body.approvalRequestId) { 200 } else { 0 }) }) 200

$cabApprovers = $policies.cabApproverIds
$decision1 = Invoke-Api PUT "$chg/$normalId/approval/capture" @{ 'X-Executor' = $cabApprovers[0] } @{ outcome = 'APPROVE'; comment = 'Looks fine' }
Assert-Status 'decision 1/2 captured (still CAB_REVIEW)' $decision1 200
Assert-Equal 'decision 1/2 leaves the change in CAB_REVIEW' $decision1.Body.status 'CAB_REVIEW'

$decision2 = Invoke-Api PUT "$chg/$normalId/approval/capture" @{ 'X-Executor' = $cabApprovers[1] } @{ outcome = 'APPROVE'; comment = 'Agreed' }
Assert-Status 'decision 2/2 captured (quorum reached)' $decision2 200
Assert-Equal 'quorum reached: change is now APPROVED' $decision2.Body.status 'APPROVED'

$plannedStart = (Get-Date).AddHours(2).ToString('o')
$plannedEnd = (Get-Date).AddHours(4).ToString('o')
$scheduleResponse = Invoke-Api PUT "$chg/$normalId/schedule" $executorHeader @{ plannedStart = $plannedStart; plannedEnd = $plannedEnd }
Assert-Status 'schedule (APPROVED -> SCHEDULED, reserves a real operation-window)' $scheduleResponse 204

$afterScheduling = Invoke-Api GET "$chg/$normalId/retrieve" $executorHeader
Assert-Equal 'status after scheduling is SCHEDULED' $afterScheduling.Body.status 'SCHEDULED'
Assert-Status 'operationWindowId was recorded' ([pscustomobject]@{ Status = $(if ($afterScheduling.Body.operationWindowId) { 200 } else { 0 }) }) 200

Assert-Status 'control/start (SCHEDULED -> IN_PROGRESS)' (Invoke-Api PUT "$chg/$normalId/control/start" $executorHeader) 204
Assert-Status 'complete (IN_PROGRESS -> IMPLEMENTED)' (Invoke-Api PUT "$chg/$normalId/complete" $executorHeader @{ implementationNotes = 'Firmware updated, verified' }) 204
Assert-Status 'control/close (IMPLEMENTED -> CLOSED)' (Invoke-Api PUT "$chg/$normalId/control/close" $executorHeader @{ closeNotes = 'No incidents' }) 204

# 3. EMERGENCY change -> ECAB_REVIEW -> a single REJECT vetoes it immediately.
$emergencyResponse = Invoke-Api POST "$chg/initiate" $tenantAndExecutor @{ requesterId = $requesterId; title = 'Emergency patch'; description = 'CVE fix'; changeType = 'EMERGENCY'; targetAssetIds = @($assetId) }
Assert-Status 'EMERGENCY change initiated (DRAFT)' $emergencyResponse 201
$emergencyId = $emergencyResponse.Body.id

Assert-Status 'control/submit' (Invoke-Api PUT "$chg/$emergencyId/control/submit" $executorHeader) 204
Assert-Status 'assess' (Invoke-Api PUT "$chg/$emergencyId/assess" $executorHeader @{ riskLevel = 'HIGH'; impactLevel = 'HIGH' }) 204
Assert-Status 'route-for-approval (ASSESSED -> ECAB_REVIEW)' (Invoke-Api PUT "$chg/$emergencyId/route-for-approval" $executorHeader) 204

$ecabApprovers = $policies.ecabApproverIds
$vetoDecision = Invoke-Api PUT "$chg/$emergencyId/approval/capture" @{ 'X-Executor' = $ecabApprovers[0] } @{ outcome = 'REJECT'; comment = 'Needs more testing' }
Assert-Status 'single ECAB decision captured' $vetoDecision 200
Assert-Equal 'single REJECT resolves the change to REJECTED' $vetoDecision.Body.status 'REJECTED'

# 4. Scheduling collision: a second change against the same asset, overlapping the first (already-
#    scheduled, now CLOSED) window's time range, must be rejected by operation-window-service's own
#    collision check and surface here as ERR-CHG-00409.
$collisionResponse = Invoke-Api POST "$chg/initiate" $tenantAndExecutor @{ requesterId = $requesterId; title = 'Conflicting change'; description = 'd'; changeType = 'STANDARD'; targetAssetIds = @($assetId) }
Assert-Status 'second change initiated for the collision check' $collisionResponse 201
$collisionId = $collisionResponse.Body.id
Assert-Status 'control/submit' (Invoke-Api PUT "$chg/$collisionId/control/submit" $executorHeader) 204
Assert-Status 'assess' (Invoke-Api PUT "$chg/$collisionId/assess" $executorHeader @{ riskLevel = 'LOW'; impactLevel = 'LOW' }) 204
Assert-Status 'route-for-approval (STANDARD, pre-approved)' (Invoke-Api PUT "$chg/$collisionId/route-for-approval" $executorHeader) 204

$collisionSchedule = Invoke-Api PUT "$chg/$collisionId/schedule" $executorHeader @{ plannedStart = $plannedStart; plannedEnd = $plannedEnd }
Assert-Status 'schedule collides with the first change''s window (409)' $collisionSchedule 409
Assert-Equal 'collision error_code is ERR-CHG-00409' $collisionSchedule.Body.error_code 'ERR-CHG-00409'

# 5. CHANGE_FREEZE override (ADR-034 of change-management, ADR-020 of operation-window): an ECAB-approved
#    EMERGENCY change may be reserved over an active CHANGE_FREEZE, a plain schedule is still blocked, and an
#    override on a non-EMERGENCY change is refused before any window is reserved.
$ow = "$OperationWindowUrl/it-operation-window/v1"
$freezeStart = (Get-Date).AddHours(30)
$freezeResponse = Invoke-Api POST "$ow/initiate" $tenantAndExecutor @{ title = 'Year-end freeze'; windowType = 'CHANGE_FREEZE'; targetAssetIds = @($assetId); startAt = $freezeStart.ToString('o'); endAt = $freezeStart.AddHours(4).ToString('o') }
Assert-Status 'CHANGE_FREEZE window created' $freezeResponse 201

$freezeChange = Invoke-Api POST "$chg/initiate" $tenantAndExecutor @{ requesterId = $requesterId; title = 'Emergency during freeze'; description = 'P1 outage'; changeType = 'EMERGENCY'; targetAssetIds = @($assetId) }
Assert-Status 'EMERGENCY change initiated for the freeze check' $freezeChange 201
$freezeChangeId = $freezeChange.Body.id
Assert-Status 'control/submit' (Invoke-Api PUT "$chg/$freezeChangeId/control/submit" $executorHeader) 204
Assert-Status 'assess' (Invoke-Api PUT "$chg/$freezeChangeId/assess" $executorHeader @{ riskLevel = 'HIGH'; impactLevel = 'HIGH' }) 204
Assert-Status 'route-for-approval (ASSESSED -> ECAB_REVIEW)' (Invoke-Api PUT "$chg/$freezeChangeId/route-for-approval" $executorHeader) 204
$ecabApprove = Invoke-Api PUT "$chg/$freezeChangeId/approval/capture" @{ 'X-Executor' = $ecabApprovers[0] } @{ outcome = 'APPROVE'; comment = 'Emergency approved' }
Assert-Equal 'a single ECAB approval makes the EMERGENCY change APPROVED' $ecabApprove.Body.status 'APPROVED'

$freezePlan = @{ plannedStart = $freezeStart.AddHours(1).ToString('o'); plannedEnd = $freezeStart.AddHours(3).ToString('o') }
$blocked = Invoke-Api PUT "$chg/$freezeChangeId/schedule" $executorHeader $freezePlan
Assert-Status 'schedule over the CHANGE_FREEZE without an override is blocked (409)' $blocked 409
Assert-Equal 'blocked error_code is ERR-CHG-00409' $blocked.Body.error_code 'ERR-CHG-00409'

# Who may waive a freeze (change management ADR-036): an ADMIN/SERVICE, or anyone on the ECAB. Security is off here, so the role is
# whatever the caller states (X-Role); an OPERATOR who is not on the ECAB is refused, an OPERATOR who is on it may.
$override = $freezePlan + @{ freezeOverrideJustification = 'P1 outage, ECAB approved' }
$outsider = Invoke-Api PUT "$chg/$freezeChangeId/schedule" @{ 'X-Executor' = 'ops-not-on-the-ecab'; 'X-Role' = 'OPERATOR' } $override
Assert-Status 'an OPERATOR who is not on the ECAB cannot waive the freeze (403)' $outsider 403
Assert-Equal 'refusal error_code is ERR-CHG-00403' $outsider.Body.error_code 'ERR-CHG-00403'
Assert-Equal 'the refused change is still APPROVED' (Invoke-Api GET "$chg/$freezeChangeId/retrieve" $executorHeader).Body.status 'APPROVED'
$overridden = Invoke-Api PUT "$chg/$freezeChangeId/schedule" @{ 'X-Executor' = $ecabApprovers[0]; 'X-Role' = 'OPERATOR' } $override
Assert-Status 'an OPERATOR who sits on the ECAB can waive the freeze (204)' $overridden 204
Assert-Equal 'the overriding change is SCHEDULED' (Invoke-Api GET "$chg/$freezeChangeId/retrieve" $executorHeader).Body.status 'SCHEDULED'

$refused = Invoke-Api PUT "$chg/$collisionId/schedule" $executorHeader (@{ plannedStart = $plannedStart; plannedEnd = $plannedEnd; freezeOverrideJustification = 'not an emergency' })
Assert-Status 'an override on a non-EMERGENCY change is refused (400)' $refused 400

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Change management smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
