<#
.SYNOPSIS
  Live proof of Journey 12, third service: problem management through the platform gateway (problem ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8100, routes it through the gateway and turns the ledger recording on). Uses
  its own tenant id (the service takes any UUID), then drives, through the GATEWAY:
    (1) a problem is opened with the priority the analyst chooses and linked to a REAL incident (opened on the incident service) and an
        asset; the problems that explain that incident are found from the problem side, and the incident itself is untouched;
    (2) it is assigned, investigated, refused as a known error until BOTH the root cause and a workaround are on record, declared a known
        error, resolved with the permanent fix, reopened with a reason (the fix is cleared), resolved again and closed, and its audit
        trail reads in order;
    (3) the service is staff only: a REQUESTER gets 403 on every route, and another tenant gets a 404;
    (4) two people moving the same problem at the same instant: never a lost or doubled move;
    (5) every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\problem-smoke.ps1
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

$prb = "$GatewayUrl/it-problem-management/v1"
$inc = "$GatewayUrl/it-incident-management/v1"
$tenantId = [guid]::NewGuid().ToString()
$staffUser = [guid]::NewGuid().ToString(); $staffUser2 = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString()
$assignee = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString(); $changeId = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
function Get-Problem([string]$Id) { (Invoke-Api GET "$prb/$Id/retrieve" $staff).Body }
function Ids($List) { (@($List | ForEach-Object { $_.id }) -join ',') }

# 1. A problem that explains a real incident.
$incident = Invoke-Api POST "$inc/initiate" $staff @{ title = 'Packet loss on floor 3'; description = 'Calls drop every hour'; impact = 'MEDIUM'; urgency = 'MEDIUM'; requesterId = $filedFor; affectedAssetIds = @($assetId) }
$incidentId = $incident.Body.id
Assert-Equal 'an incident is opened on the incident service' $incident.Status 201
$opened = Invoke-Api POST "$prb/initiate" $staff @{ title = 'Switch drops packets'; description = 'Intermittent loss on floor 3'; priority = 'P2'; relatedIncidentIds = @($incidentId); affectedAssetIds = @($assetId) }
$id = $opened.Body.id
Assert-Equal 'staff open a problem: 201, NEW, the priority they chose' "$($opened.Status)/$($opened.Body.status)/$($opened.Body.priority)" '201/NEW/P2'
Assert-Equal 'the links are kept as references' "$(@($opened.Body.relatedIncidentIds).Count)/$(@($opened.Body.affectedAssetIds).Count)" '1/1'
Assert-Equal 'a blank title is refused (400)' (Invoke-Api POST "$prb/initiate" $staff @{ title = ''; description = 'd'; priority = 'P3' }).Status 400
Assert-Equal 'a missing priority is refused (400)' (Invoke-Api POST "$prb/initiate" $staff @{ title = 't'; description = 'd' }).Status 400
Assert-Equal 'the tenant is mandatory on every route (400)' (Invoke-Api GET "$prb/$id/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
Assert-Equal 'the problems that explain the incident are found from the problem side' (Ids (Invoke-Api GET "$prb/retrieve?incidentId=$incidentId" $staff).Body) $id
Assert-Equal 'and the ones that involve the asset' (Ids (Invoke-Api GET "$prb/retrieve?assetId=$assetId&openOnly=true" $staff).Body) $id
Assert-Equal 'the incident itself is untouched by the link (still NEW)' (Invoke-Api GET "$inc/$incidentId/retrieve" $staff).Body.status 'NEW'
Assert-Equal 'update: P1 and a fixing change linked' (Invoke-Api PUT "$prb/$id/update" $staff @{ title = 'Switch drops packets'; description = 'Now every hour'; priority = 'P1'; relatedIncidentIds = @($incidentId); relatedChangeIds = @($changeId); affectedAssetIds = @($assetId) }).Status 204
$updated = Get-Problem $id
Assert-Equal 'it is P1 with the change linked' "$($updated.priority)/$(@($updated.relatedChangeIds).Count)" 'P1/1'

# 2. The lifecycle and the known error.
Assert-Equal 'assign' (Invoke-Api PUT "$prb/$id/assignment/update" $staff @{ assigneeId = $assignee }).Status 204
Assert-Equal 'an analysis before investigating is an illegal transition (409)' (Invoke-Api PUT "$prb/$id/analysis/update" $staff @{ rootCause = 'cause' }).Status 409
Assert-Equal 'investigate' (Invoke-Api PUT "$prb/$id/control/investigate" $staff).Status 204
Assert-Equal 'a known error without a root cause is refused (400)' (Invoke-Api PUT "$prb/$id/control/known-error" $staff).Status 400
Assert-Equal 'record the root cause' (Invoke-Api PUT "$prb/$id/analysis/update" $staff @{ rootCause = 'Firmware 2.1 leaks buffers under load' }).Status 204
Assert-Equal 'a known error with no workaround is still refused (400)' (Invoke-Api PUT "$prb/$id/control/known-error" $staff).Status 400
Assert-Equal 'an analysis that says nothing is refused (400)' (Invoke-Api PUT "$prb/$id/analysis/update" $staff @{}).Status 400
Assert-Equal 'record the workaround' (Invoke-Api PUT "$prb/$id/analysis/update" $staff @{ workaround = 'Reboot the switch every Sunday' }).Status 204
Assert-Equal 'declare the known error' (Invoke-Api PUT "$prb/$id/control/known-error" $staff).Status 204
$known = Get-Problem $id
Assert-Equal 'KNOWN_ERROR, with both the cause and the workaround' "$($known.status)/$($known.rootCause)/$($known.workaround)" 'KNOWN_ERROR/Firmware 2.1 leaks buffers under load/Reboot the switch every Sunday'
Assert-Equal 'a comment' (Invoke-Api POST "$prb/$id/comment/initiate" $staff @{ text = 'Vendor confirmed the leak' }).Status 201
Assert-Equal 'close before resolving is an illegal transition (409)' (Invoke-Api PUT "$prb/$id/control/close" $staff).Status 409
Assert-Equal 'resolve needs the resolution (400)' (Invoke-Api PUT "$prb/$id/control/resolve" $staff @{ resolution = '' }).Status 400
Assert-Equal 'resolve with the permanent fix' (Invoke-Api PUT "$prb/$id/control/resolve" $staff @{ resolution = 'Upgraded the fleet to firmware 2.2' }).Status 204
Assert-Equal 'a resolved problem takes no edit (409)' (Invoke-Api PUT "$prb/$id/update" $staff @{ title = 't'; description = 'd'; priority = 'P3' }).Status 409
Assert-Equal 'reopen needs a reason (400)' (Invoke-Api PUT "$prb/$id/control/reopen" $staff @{ reason = '' }).Status 400
Assert-Equal 'reopen: the fix did not hold' (Invoke-Api PUT "$prb/$id/control/reopen" $staff @{ reason = 'Still dropping packets' }).Status 204
$reopened = Get-Problem $id
Assert-Equal 'it is under investigation again, counted, the old resolution cleared' "$($reopened.status)/$($reopened.reopenCount)/$([bool]$reopened.resolution)" 'UNDER_INVESTIGATION/1/False'
Assert-Equal 'resolve again' (Invoke-Api PUT "$prb/$id/control/resolve" $staff @{ resolution = 'Replaced the faulty line card' }).Status 204
Assert-Equal 'close' (Invoke-Api PUT "$prb/$id/control/close" $staff).Status 204
Assert-Equal 'a closed problem takes no comment (409)' (Invoke-Api POST "$prb/$id/comment/initiate" $staff @{ text = 'late' }).Status 409
$trail = @((Invoke-Api GET "$prb/$id/audit-log/retrieve" $staff).Body)
Assert-Equal 'the audit trail reads in order' (($trail | ForEach-Object { $_.action }) -join ',') 'INITIATED,UPDATED,ASSIGNED,INVESTIGATION_STARTED,ANALYSIS_RECORDED,ANALYSIS_RECORDED,KNOWN_ERROR_DECLARED,COMMENT_ADDED,RESOLVED,REOPENED,RESOLVED,CLOSED'
Assert-Equal 'open-only leaves out the closed one' (@((Invoke-Api GET "$prb/retrieve?openOnly=true&incidentId=$incidentId" $staff).Body).Count) 0

# 3. Staff only, and the tenant.
$denied = Invoke-Api POST "$prb/initiate" $asRequester @{ title = 't'; description = 'd'; priority = 'P4' }
Assert-Equal 'a REQUESTER cannot open a problem (403 ERR-PRB-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-PRB-00403'
Assert-Equal 'a REQUESTER cannot read one (403)' (Invoke-Api GET "$prb/$id/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot list them (403)' (Invoke-Api GET "$prb/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot work one (403)' (Invoke-Api PUT "$prb/$id/control/investigate" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot read the audit trail (403)' (Invoke-Api GET "$prb/$id/audit-log/retrieve" $asRequester).Status 403
Assert-Equal 'another tenant gets a 404 for the problem' (Invoke-Api GET "$prb/$id/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }).Status 404
Assert-Equal 'another tenant finds none by incident' (@((Invoke-Api GET "$prb/retrieve?incidentId=$incidentId" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }).Body).Count) 0

# 4. A race: two people move the same problem at the same instant.
$raced = (Invoke-Api POST "$prb/initiate" $staff @{ title = 'Race'; description = 'd'; priority = 'P4' }).Body.id
$move = {
    param($url, $tenant, $executor)
    try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [int]$_.Exception.Response.StatusCode }
}
$jobs = @((Start-Job -ScriptBlock $move -ArgumentList "$prb/$raced/control/investigate", $tenantId, $staffUser),
          (Start-Job -ScriptBlock $move -ArgumentList "$prb/$raced/control/cancel", $tenantId, $staffUser2))
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'each racer is told 204 or 409, never an error' (@($codes | Where-Object { $_ -ne 204 -and $_ -ne 409 }).Count) 0
$final = Get-Problem $raced
Assert-Equal 'the problem ends in a legal state' (@('UNDER_INVESTIGATION', 'CANCELLED') -contains $final.status) $true
# Cancelling an UNDER_INVESTIGATION problem is legal, so both may win one after the other; what must never happen is a lost or doubled
# move: the trail is the opening plus exactly one entry for every request that was answered 204.
Assert-Equal 'the audit trail holds the opening plus one entry per accepted move' @((Invoke-Api GET "$prb/$raced/audit-log/retrieve" $staff).Body).Count (1 + @($codes | Where-Object { $_ -eq 204 }).Count)
Assert-Equal 'a delete is not a thing (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$prb/$id" $staff).Status) $true

# 5. The ledger.
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-problem-management' })
    $recorded = $entries.Count
    if ($recorded -ge 25) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 25) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Problem smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
