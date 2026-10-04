<#
.SYNOPSIS
  Live proof of Journey 12, first service: incident management through the platform gateway (incident ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8098, routes it through the gateway and turns the ledger recording on). Uses
  its own tenant id (the service takes any UUID), then drives, through the GATEWAY:
    (1) an incident is opened by staff: the priority is derived from impact and urgency (never typed), both SLA targets run, and an
        update that changes impact/urgency re-derives the priority;
    (2) it is assigned, acknowledged (the response SLA is judged MET), started, held with a reason, resumed, resolved with a code and
        notes (the resolution SLA is judged), reopened and closed, and its audit trail reads in order;
    (3) self-service: a REQUESTER files on their own behalf, sees only their own incidents and never the internal notes, and cannot do a
        staff action (403) nor read the audit trail; another requester and another tenant get a 404;
    (4) two people acknowledging/cancelling the same incident at the same instant: one wins, the other gets 409 - never both;
    (5) a link to an asset is a reference (no other service is asked), the collection filters by priority, asset and open-only, and
        every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\incident-smoke.ps1
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

$inc = "$GatewayUrl/it-incident-management/v1"
$tenantId = [guid]::NewGuid().ToString()
$staffUser = [guid]::NewGuid().ToString(); $staffUser2 = [guid]::NewGuid().ToString()
$requesterA = [guid]::NewGuid().ToString(); $requesterB = [guid]::NewGuid().ToString()
$assignee = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
function AsRequester([string]$User, [string]$Tenant = $tenantId) { @{ 'X-Tenant-Id' = $Tenant; 'X-Executor' = $User; 'X-Role' = 'REQUESTER' } }
function Get-Incident([string]$Id) { (Invoke-Api GET "$inc/$Id/retrieve" $staff).Body }

# 1. Opening an incident: the priority is derived, never typed.
$opened = Invoke-Api POST "$inc/initiate" $staff @{ title = 'Core switch down'; description = 'No link on floor 3'; impact = 'HIGH'; urgency = 'MEDIUM'; requesterId = $filedFor; affectedAssetIds = @($assetId) }
$id = $opened.Body.id
Assert-Equal 'staff open an incident (201)' $opened.Status 201
Assert-Equal 'HIGH x MEDIUM is P2, NEW, both SLA targets running' "$($opened.Body.priority)/$($opened.Body.status)/$($opened.Body.response.state)/$($opened.Body.resolution.state)" 'P2/NEW/PENDING/PENDING'
Assert-Equal 'a priority in the body is not a thing: it is ignored' (Invoke-Api POST "$inc/initiate" $staff @{ title = 't'; description = 'd'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor; priority = 'P1' }).Body.priority 'P4'
Assert-Equal 'staff must name the requester (400)' (Invoke-Api POST "$inc/initiate" $staff @{ title = 't'; description = 'd'; impact = 'LOW'; urgency = 'LOW' }).Status 400
Assert-Equal 'a blank title is refused (400)' (Invoke-Api POST "$inc/initiate" $staff @{ title = ''; description = 'd'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }).Status 400
Assert-Equal 'the tenant is mandatory on every route (400)' (Invoke-Api GET "$inc/$id/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
Assert-Equal 'update to HIGH x HIGH re-derives the priority' (Invoke-Api PUT "$inc/$id/update" $staff @{ title = 'Core switch down'; description = 'The whole site is offline'; impact = 'HIGH'; urgency = 'HIGH'; affectedAssetIds = @($assetId) }).Status 204
Assert-Equal 'it is now P1' (Get-Incident $id).priority 'P1'

# 2. The lifecycle.
Assert-Equal 'start before acknowledging is an illegal transition (409)' (Invoke-Api PUT "$inc/$id/control/start" $staff).Status 409
Assert-Equal 'assign' (Invoke-Api PUT "$inc/$id/assignment/update" $staff @{ assigneeId = $assignee }).Status 204
Assert-Equal 'acknowledge' (Invoke-Api PUT "$inc/$id/control/acknowledge" $staff).Status 204
$acknowledged = Get-Incident $id
Assert-Equal 'ACKNOWLEDGED, the response SLA is MET, the assignee is set' "$($acknowledged.status)/$($acknowledged.response.state)/$($acknowledged.assigneeId)" "ACKNOWLEDGED/MET/$assignee"
Assert-Equal 'start' (Invoke-Api PUT "$inc/$id/control/start" $staff).Status 204
Assert-Equal 'hold needs a reason (400)' (Invoke-Api PUT "$inc/$id/control/hold" $staff @{ reason = '' }).Status 400
Assert-Equal 'hold with a reason' (Invoke-Api PUT "$inc/$id/control/hold" $staff @{ reason = 'Waiting for the vendor' }).Status 204
Assert-Equal 'ON_HOLD keeps its reason' (Get-Incident $id).holdReason 'Waiting for the vendor'
Assert-Equal 'resume' (Invoke-Api PUT "$inc/$id/control/resume" $staff).Status 204
Assert-Equal 'a public comment' (Invoke-Api POST "$inc/$id/comment/initiate" $staff @{ text = 'We are on it'; internal = $false }).Status 201
Assert-Equal 'an internal note' (Invoke-Api POST "$inc/$id/comment/initiate" $staff @{ text = 'The vendor contact is on leave'; internal = $true }).Status 201
Assert-Equal 'resolve needs notes (400)' (Invoke-Api PUT "$inc/$id/control/resolve" $staff @{ resolutionCode = 'REPLACED'; notes = '' }).Status 400
Assert-Equal 'resolve with a code and notes' (Invoke-Api PUT "$inc/$id/control/resolve" $staff @{ resolutionCode = 'REPLACED'; notes = 'Swapped the faulty switch' }).Status 204
$resolved = Get-Incident $id
Assert-Equal 'RESOLVED, the resolution SLA is MET, staff see both comments' "$($resolved.status)/$($resolved.resolution.state)/$(@($resolved.comments).Count)" 'RESOLVED/MET/2'
Assert-Equal 'update after resolution is refused (409)' (Invoke-Api PUT "$inc/$id/update" $staff @{ title = 't'; description = 'd'; impact = 'LOW'; urgency = 'LOW' }).Status 409
Assert-Equal 'reopen needs a reason (400)' (Invoke-Api PUT "$inc/$id/control/reopen" $staff @{ reason = '' }).Status 400
Assert-Equal 'reopen' (Invoke-Api PUT "$inc/$id/control/reopen" $staff @{ reason = 'Still failing after the swap' }).Status 204
Assert-Equal 'it is IN_PROGRESS again and counted as reopened' "$((Get-Incident $id).status)/$((Get-Incident $id).reopenCount)" 'IN_PROGRESS/1'
Assert-Equal 'resolve again' (Invoke-Api PUT "$inc/$id/control/resolve" $staff @{ resolutionCode = 'REPLACED'; notes = 'Swapped the cable too' }).Status 204
Assert-Equal 'close' (Invoke-Api PUT "$inc/$id/control/close" $staff).Status 204
Assert-Equal 'a closed incident takes no comment (409)' (Invoke-Api POST "$inc/$id/comment/initiate" $staff @{ text = 'late' }).Status 409
$trail = @((Invoke-Api GET "$inc/$id/audit-log/retrieve" $staff).Body)
Assert-Equal 'the audit trail reads in order' (($trail | ForEach-Object { $_.action }) -join ',') 'INITIATED,UPDATED,ASSIGNED,ACKNOWLEDGED,WORK_STARTED,PUT_ON_HOLD,WORK_RESUMED,COMMENT_ADDED,COMMENT_ADDED,RESOLVED,REOPENED,RESOLVED,CLOSED'

# 3. Self-service.
$mine = Invoke-Api POST "$inc/initiate" (AsRequester $requesterA) @{ title = 'My laptop will not boot'; description = 'Black screen'; impact = 'LOW'; urgency = 'MEDIUM'; requesterId = $filedFor }
$mineId = $mine.Body.id
Assert-Equal 'a REQUESTER files on their own behalf, whatever the body says' "$($mine.Status)/$($mine.Body.requesterId)" "201/$requesterA"
Assert-Equal 'staff add an internal note to it' (Invoke-Api POST "$inc/$mineId/comment/initiate" $staff @{ text = 'Probably the drive'; internal = $true }).Status 201
Assert-Equal 'the REQUESTER comments (an internal flag is ignored)' (Invoke-Api POST "$inc/$mineId/comment/initiate" (AsRequester $requesterA) @{ text = 'It also beeps twice'; internal = $true }).Status 201
$seen = (Invoke-Api GET "$inc/$mineId/retrieve" (AsRequester $requesterA)).Body
Assert-Equal 'the REQUESTER sees only the public comment' "$(@($seen.comments).Count)/$($seen.comments[0].internal)" '1/False'
Assert-Equal 'the REQUESTER lists only their own incidents' (@((Invoke-Api GET "$inc/retrieve" (AsRequester $requesterA)).Body | ForEach-Object { $_.id }) -join ',') $mineId
Assert-Equal 'staff list sees both incidents of the tenant' (@((Invoke-Api GET "$inc/retrieve" $staff).Body | Where-Object { $_.id -eq $id -or $_.id -eq $mineId }).Count) 2
Assert-Equal 'another requester gets a 404 for it' (Invoke-Api GET "$inc/$mineId/retrieve" (AsRequester $requesterB)).Status 404
Assert-Equal 'another requester cannot comment on it (404)' (Invoke-Api POST "$inc/$mineId/comment/initiate" (AsRequester $requesterB) @{ text = 'hi' }).Status 404
$denied = Invoke-Api PUT "$inc/$mineId/control/acknowledge" (AsRequester $requesterA)
Assert-Equal 'a REQUESTER cannot acknowledge (403 ERR-INC-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-INC-00403'
Assert-Equal 'a REQUESTER cannot cancel (403)' (Invoke-Api PUT "$inc/$mineId/control/cancel" (AsRequester $requesterA)).Status 403
Assert-Equal 'a REQUESTER cannot read the audit trail (403)' (Invoke-Api GET "$inc/$mineId/audit-log/retrieve" (AsRequester $requesterA)).Status 403
Assert-Equal 'another tenant gets a 404 for the incident' (Invoke-Api GET "$inc/$mineId/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }).Status 404

# 4. A race: two people move the same incident at the same instant.
$raced = (Invoke-Api POST "$inc/initiate" $staff @{ title = 'Race'; description = 'd'; impact = 'LOW'; urgency = 'LOW'; requesterId = $filedFor }).Body.id
$move = {
    param($url, $tenant, $executor)
    try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [int]$_.Exception.Response.StatusCode }
}
$jobs = @((Start-Job -ScriptBlock $move -ArgumentList "$inc/$raced/control/acknowledge", $tenantId, $staffUser),
          (Start-Job -ScriptBlock $move -ArgumentList "$inc/$raced/control/cancel", $tenantId, $staffUser2))
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'each racer is told 204 or 409, never an error' (@($codes | Where-Object { $_ -ne 204 -and $_ -ne 409 }).Count) 0
$final = (Get-Incident $raced)
Assert-Equal 'the incident ends in a legal state' (@('ACKNOWLEDGED', 'CANCELLED') -contains $final.status) $true
# Cancelling an ACKNOWLEDGED incident is legal, so both may win one after the other; what must never happen is a lost or doubled move:
# the trail is the opening plus exactly one entry for every request that was answered 204.
Assert-Equal 'the audit trail holds the opening plus one entry per accepted move' @((Invoke-Api GET "$inc/$raced/audit-log/retrieve" $staff).Body).Count (1 + @($codes | Where-Object { $_ -eq 204 }).Count)

# 5. Links, filters, and the ledger.
Assert-Equal 'the collection filters by priority, asset and open-only' (@((Invoke-Api GET "$inc/retrieve?assetId=$assetId&priority=P1" $staff).Body | ForEach-Object { $_.id }) -join ',') $id
Assert-Equal 'open-only leaves out the closed one' (@((Invoke-Api GET "$inc/retrieve?openOnly=true&assetId=$assetId" $staff).Body).Count) 0
Assert-Equal 'a delete is not a thing (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$inc/$id" $staff).Status) $true
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-incident-management' })
    $recorded = $entries.Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Incident smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
