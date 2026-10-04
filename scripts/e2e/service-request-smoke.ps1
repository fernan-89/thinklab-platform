<#
.SYNOPSIS
  Live proof of Journey 12, second service: the service catalog and requests through the platform gateway (service-request ADR-030..034).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8099, routes it through the gateway and turns the ledger recording on). Uses
  its own tenant id (the service takes any UUID), then drives, through the GATEWAY:
    (1) the catalog: a draft item is edited, published and refused a duplicate code; a REQUESTER sees only what is published;
    (2) a request for an item with no approval: its answers are validated, the lifecycle runs to CLOSED with the SLA judged when read,
        and the audit trail reads in order;
    (3) a request for an item whose approval is a CHAIN on workflow-approval: it waits, the first stage's decision leaves it waiting, the
        last stage's decision releases it, and a rejection ends it; cancelling a waiting request withdraws its approval;
    (4) self-service: a REQUESTER orders for themselves, sees only their own requests and never the internal notes, and cannot do a staff
        action (403) nor read the audit trail; another requester and another tenant get a 404;
    (5) two people moving the same request at the same instant: never a lost or doubled move;
    (6) every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\service-request-smoke.ps1
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

$srq = "$GatewayUrl/it-service-request/v1"
$cat = "$srq/catalog"
$wf = "$GatewayUrl/workflow-approval/v1"
$tenantId = [guid]::NewGuid().ToString()
$staffUser = [guid]::NewGuid().ToString(); $staffUser2 = [guid]::NewGuid().ToString()
$requesterA = [guid]::NewGuid().ToString(); $requesterB = [guid]::NewGuid().ToString(); $requesterC = [guid]::NewGuid().ToString()
$assignee = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString()
$lead = [guid]::NewGuid().ToString(); $secA = [guid]::NewGuid().ToString(); $secB = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
function AsRequester([string]$User, [string]$Tenant = $tenantId) { @{ 'X-Tenant-Id' = $Tenant; 'X-Executor' = $User; 'X-Role' = 'REQUESTER' } }
function Get-Request([string]$Id) { (Invoke-Api GET "$srq/$Id/retrieve" $staff).Body }
function Decide([string]$Id, [string]$Approver, [string]$Outcome, [string]$Comment = $null) {
    $body = @{ outcome = $Outcome }
    if ($Comment) { $body.comment = $Comment }
    Invoke-Api PUT "$srq/$Id/approval/capture" @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $Approver } $body
}
function New-Request([string]$ItemId, [hashtable]$Answers) { Invoke-Api POST "$srq/initiate" $staff @{ catalogItemId = $ItemId; answers = $Answers; requesterId = $filedFor } }

# 1. The catalog.
$laptop = Invoke-Api POST "$cat/initiate" $staff @{ code = 'laptop'; name = 'New laptop'; category = 'HARDWARE'; fulfilmentTargetHours = 72
    fields = @(@{ key = 'model'; label = 'Which model?'; required = $true }, @{ key = 'notes'; label = 'Anything else?'; required = $false }) }
$laptopId = $laptop.Body.id
Assert-Equal 'a draft item is created (201), DRAFT, code upper-cased' "$($laptop.Status)/$($laptop.Body.status)/$($laptop.Body.code)" '201/DRAFT/LAPTOP'
Assert-Equal 'the same code again, in another case, is refused (409)' (Invoke-Api POST "$cat/initiate" $staff @{ code = 'Laptop'; name = 'Other'; fields = @(); fulfilmentTargetHours = 8 }).Status 409
Assert-Equal 'a DRAFT item cannot be requested (409)' (New-Request $laptopId @{ model = 'X1' }).Status 409
Assert-Equal 'a REQUESTER does not see a DRAFT item (404)' (Invoke-Api GET "$cat/$laptopId/retrieve" (AsRequester $requesterA)).Status 404
Assert-Equal 'the draft is edited (204)' (Invoke-Api PUT "$cat/$laptopId/update" $staff @{ name = 'New laptop (standard)'; category = 'HARDWARE'; fulfilmentTargetHours = 72
    fields = @(@{ key = 'model'; label = 'Which model?'; required = $true }, @{ key = 'notes'; label = 'Anything else?'; required = $false }) }).Status 204
Assert-Equal 'publish' (Invoke-Api PUT "$cat/$laptopId/control/publish" $staff).Status 204
Assert-Equal 'a PUBLISHED item can no longer be edited (409)' (Invoke-Api PUT "$cat/$laptopId/update" $staff @{ name = 'x'; fields = @(); fulfilmentTargetHours = 8 }).Status 409
Assert-Equal 'a REQUESTER sees it now' (Invoke-Api GET "$cat/$laptopId/retrieve" (AsRequester $requesterA)).Body.status 'PUBLISHED'
Assert-Equal 'a REQUESTER lists only PUBLISHED items, even asking for DRAFT' (@((Invoke-Api GET "$cat/retrieve?status=DRAFT" (AsRequester $requesterA)).Body | ForEach-Object { $_.id }) -join ',') $laptopId
Assert-Equal 'a REQUESTER cannot manage the catalog (403)' (Invoke-Api POST "$cat/initiate" (AsRequester $requesterA) @{ code = 'SNEAKY'; name = 's'; fields = @(); fulfilmentTargetHours = 1 }).Status 403

# 2. A request with no approval.
Assert-Equal 'a missing mandatory answer is refused (400)' (New-Request $laptopId @{ notes = 'n' }).Status 400
Assert-Equal 'an unknown question is refused (400)' (New-Request $laptopId @{ model = 'X1'; size = 'XL' }).Status 400
Assert-Equal 'staff must name the requester (400)' (Invoke-Api POST "$srq/initiate" $staff @{ catalogItemId = $laptopId; answers = @{ model = 'X1' } }).Status 400
$opened = New-Request $laptopId @{ model = 'X1' }
$id = $opened.Body.id
Assert-Equal 'staff order on someone behalf: 201, SUBMITTED, SLA PENDING' "$($opened.Status)/$($opened.Body.status)/$($opened.Body.fulfilment.state)" '201/SUBMITTED/PENDING'
Assert-Equal 'it snapshots the item' "$($opened.Body.catalogItemCode)/$($opened.Body.catalogItemName)" 'LAPTOP/New laptop (standard)'
Assert-Equal 'the tenant is mandatory on every route (400)' (Invoke-Api GET "$srq/$id/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
Assert-Equal 'fulfil before starting is an illegal transition (409)' (Invoke-Api PUT "$srq/$id/control/fulfil" $staff @{ notes = 'done' }).Status 409
Assert-Equal 'assign' (Invoke-Api PUT "$srq/$id/assignment/update" $staff @{ assigneeId = $assignee }).Status 204
Assert-Equal 'a public comment' (Invoke-Api POST "$srq/$id/comment/initiate" $staff @{ text = 'Stock is on its way'; internal = $false }).Status 201
Assert-Equal 'an internal note' (Invoke-Api POST "$srq/$id/comment/initiate" $staff @{ text = 'Supplier says Thursday'; internal = $true }).Status 201
Assert-Equal 'start fulfilment' (Invoke-Api PUT "$srq/$id/control/start-fulfilment" $staff).Status 204
Assert-Equal 'fulfil needs notes (400)' (Invoke-Api PUT "$srq/$id/control/fulfil" $staff @{ notes = '' }).Status 400
Assert-Equal 'fulfil with notes' (Invoke-Api PUT "$srq/$id/control/fulfil" $staff @{ notes = 'Laptop handed over' }).Status 204
$done = Get-Request $id
Assert-Equal 'FULFILLED, the SLA is MET, staff see both comments' "$($done.status)/$($done.fulfilment.state)/$(@($done.comments).Count)" 'FULFILLED/MET/2'
Assert-Equal 'close' (Invoke-Api PUT "$srq/$id/control/close" $staff).Status 204
Assert-Equal 'a closed request takes no comment (409)' (Invoke-Api POST "$srq/$id/comment/initiate" $staff @{ text = 'late' }).Status 409
Assert-Equal 'a closed request cannot be cancelled (409)' (Invoke-Api PUT "$srq/$id/control/cancel" $staff).Status 409
$trail = @((Invoke-Api GET "$srq/$id/audit-log/retrieve" $staff).Body)
Assert-Equal 'the audit trail reads in order' (($trail | ForEach-Object { $_.action }) -join ',') 'INITIATED,ASSIGNED,COMMENT_ADDED,COMMENT_ADDED,FULFILMENT_STARTED,FULFILLED,CLOSED'

# 3. A request whose approval is a chain on workflow-approval: team lead first, then security (either of two).
$wfTenant = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'service-request-smoke' }
$policy = Invoke-Api POST "$wf/policy/initiate" $wfTenant @{ name = 'Software seat'; stages = @(
    @{ requiredApprovals = 1; eligibleApproverIds = @($lead) },
    @{ requiredApprovals = 1; eligibleApproverIds = @($secA, $secB) }) }
Assert-Equal 'the approval chain exists on workflow-approval' "$($policy.Status)/$(@($policy.Body.stages).Count)" '201/2'
$seat = Invoke-Api POST "$cat/initiate" $staff @{ code = 'SEAT'; name = 'Software seat'; fulfilmentTargetHours = 24; approvalPolicyId = $policy.Body.id; fields = @(@{ key = 'product'; label = 'Which product?'; required = $true }) }
Assert-Equal 'an item naming the policy is created' $seat.Status 201
Assert-Equal 'publish it' (Invoke-Api PUT "$cat/$($seat.Body.id)/control/publish" $staff).Status 204
$waiting = New-Request $seat.Body.id @{ product = 'IDE' }
$wid = $waiting.Body.id
Assert-Equal 'the request waits for approval and carries the approval request id' "$($waiting.Status)/$($waiting.Body.status)/$([bool]$waiting.Body.approvalRequestId)" '201/PENDING_APPROVAL/True'
$approvalId = $waiting.Body.approvalRequestId
Assert-Equal 'the first approver has it in their inbox on workflow-approval' (@((Invoke-Api GET "$wf/retrieve?pendingFor=$lead" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.id -eq $approvalId }).Count) 1
Assert-Equal 'fulfilment cannot start before approval (409)' (Invoke-Api PUT "$srq/$wid/control/start-fulfilment" $staff).Status 409
$stranger = Decide $wid ([guid]::NewGuid().ToString()) 'APPROVE'
Assert-Equal 'an approver who is not eligible is told why (409 ERR-SRQ-00409, not a generic 500)' "$($stranger.Status)/$($stranger.Body.error_code)" '409/ERR-SRQ-00409'
Assert-Equal 'and the request is still waiting' (Get-Request $wid).status 'PENDING_APPROVAL'
$firstStage = Decide $wid $lead 'APPROVE'
Assert-Equal 'the first stage approving leaves the request waiting (the chain has a stage left)' "$($firstStage.Status)/$($firstStage.Body.status)" '200/PENDING_APPROVAL'
$lastStage = Decide $wid $secA 'APPROVE'
Assert-Equal 'the last stage approving releases it: APPROVED' "$($lastStage.Status)/$($lastStage.Body.status)" '200/APPROVED'
Assert-Equal 'a decision on a request that is no longer waiting is refused (409)' (Decide $wid $secB 'APPROVE').Status 409
Assert-Equal 'the approved request can start fulfilment' (Invoke-Api PUT "$srq/$wid/control/start-fulfilment" $staff).Status 204
Assert-Equal 'and be fulfilled' (Invoke-Api PUT "$srq/$wid/control/fulfil" $staff @{ notes = 'Seat assigned' }).Status 204
Assert-Equal 'its trail records the approval' ((@((Invoke-Api GET "$srq/$wid/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action })) -join ',') 'INITIATED,APPROVED,FULFILMENT_STARTED,FULFILLED'
$rejected = New-Request $seat.Body.id @{ product = 'CAD' }
$rid = $rejected.Body.id
$rejection = Decide $rid $lead 'REJECT'
Assert-Equal 'a rejection ends it: REJECTED' "$($rejection.Status)/$($rejection.Body.status)" '200/REJECTED'
Assert-Equal 'a rejected request cannot start fulfilment (409)' (Invoke-Api PUT "$srq/$rid/control/start-fulfilment" $staff).Status 409
Assert-Equal 'a rejected request owes no SLA' ((Get-Request $rid).fulfilment) $null
$cancelled = New-Request $seat.Body.id @{ product = 'VM' }
$cid = $cancelled.Body.id
$cancelledApproval = $cancelled.Body.approvalRequestId
Assert-Equal 'cancel a request that waits for approval' (Invoke-Api PUT "$srq/$cid/control/cancel" $staff).Status 204
Assert-Equal 'its approval request was withdrawn on workflow-approval' (Invoke-Api GET "$wf/$cancelledApproval/retrieve" $wfTenant).Body.status 'CANCELLED'
Assert-Equal 'and it left the approver inbox' (@((Invoke-Api GET "$wf/retrieve?pendingFor=$lead" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.id -eq $cancelledApproval }).Count) 0

# 3b. An approver sends a request back with what to fix; the requester edits it and it goes through a NEW approval.
$ret = Invoke-Api POST "$srq/initiate" (AsRequester $requesterC) @{ catalogItemId = $seat.Body.id; answers = @{ product = 'IDE' } }
$retId = $ret.Body.id; $firstApproval = $ret.Body.approvalRequestId
Assert-Equal 'a REQUESTER orders the item that needs approval: it waits' "$($ret.Status)/$($ret.Body.status)" '201/PENDING_APPROVAL'
Assert-Equal 'a RETURN needs a comment saying what to fix (400)' (Decide $retId $lead 'RETURN').Status 400
Assert-Equal 'and the request is still waiting' (Get-Request $retId).status 'PENDING_APPROVAL'
$returned = Decide $retId $lead 'RETURN' 'Say which product and why you need it'
Assert-Equal 'RETURN sends it back: RETURNED, with the approver comment as the reason' "$($returned.Status)/$($returned.Body.status)/$($returned.Body.returnReason)" '200/RETURNED/Say which product and why you need it'
Assert-Equal 'the approval on workflow-approval is RETURNED and left the inbox' "$((Invoke-Api GET "$wf/$firstApproval/retrieve" $wfTenant).Body.status)/$(@((Invoke-Api GET "$wf/retrieve?pendingFor=$lead" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.id -eq $firstApproval }).Count)" 'RETURNED/0'
Assert-Equal 'a decision on a returned request is refused (409)' (Decide $retId $secA 'APPROVE').Status 409
Assert-Equal 'the REQUESTER sees the reason on their own request' (Invoke-Api GET "$srq/$retId/retrieve" (AsRequester $requesterC)).Body.returnReason 'Say which product and why you need it'
Assert-Equal 'another requester cannot resubmit it (404)' (Invoke-Api PUT "$srq/$retId/control/resubmit" (AsRequester $requesterB) @{ answers = @{ product = 'CAD' } }).Status 404
Assert-Equal 'answers the item does not ask are refused (400), nothing is filed' (Invoke-Api PUT "$srq/$retId/control/resubmit" (AsRequester $requesterC) @{ answers = @{ colour = 'red' } }).Status 400
Assert-Equal 'a request that was not returned cannot be resubmitted (409)' (Invoke-Api PUT "$srq/$wid/control/resubmit" $staff @{ answers = @{ product = 'IDE' } }).Status 409
$resubmitted = Invoke-Api PUT "$srq/$retId/control/resubmit" (AsRequester $requesterC) @{ answers = @{ product = 'IDE for the data team' } }
Assert-Equal 'the REQUESTER edits and resubmits: waiting again, the new answers, a NEW approval request' "$($resubmitted.Status)/$($resubmitted.Body.status)/$($resubmitted.Body.answers.product)/$($resubmitted.Body.approvalRequestId -ne $firstApproval)" '200/PENDING_APPROVAL/IDE for the data team/True'
Assert-Equal 'it is back in the first approver inbox, from stage one' (@((Invoke-Api GET "$wf/retrieve?pendingFor=$lead" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.id -eq $resubmitted.Body.approvalRequestId }).Count) 1
Assert-Equal 'the first stage approves' (Decide $retId $lead 'APPROVE').Body.status 'PENDING_APPROVAL'
Assert-Equal 'the second stage approves: APPROVED' (Decide $retId $secB 'APPROVE').Body.status 'APPROVED'
Assert-Equal 'its trail tells the story' ((@((Invoke-Api GET "$srq/$retId/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action })) -join ',') 'INITIATED,RETURNED,RESUBMITTED,APPROVED'
$retCancel = Invoke-Api POST "$srq/initiate" (AsRequester $requesterC) @{ catalogItemId = $seat.Body.id; answers = @{ product = 'VM' } }
Assert-Equal 'staff return another one, which the REQUESTER cancels instead of resubmitting' (Decide $retCancel.Body.id $lead 'RETURN' 'Not enough detail').Body.status 'RETURNED'
Assert-Equal 'a returned request can be cancelled by its REQUESTER' (Invoke-Api PUT "$srq/$($retCancel.Body.id)/control/cancel" (AsRequester $requesterC)).Status 204

# 4. Self-service.
$mine = Invoke-Api POST "$srq/initiate" (AsRequester $requesterA) @{ catalogItemId = $laptopId; answers = @{ model = 'X1' }; requesterId = $filedFor }
$mineId = $mine.Body.id
Assert-Equal 'a REQUESTER orders for themselves, whatever the body says' "$($mine.Status)/$($mine.Body.requesterId)" "201/$requesterA"
Assert-Equal 'staff add an internal note to it' (Invoke-Api POST "$srq/$mineId/comment/initiate" $staff @{ text = 'Check the budget'; internal = $true }).Status 201
Assert-Equal 'the REQUESTER comments (an internal flag is ignored)' (Invoke-Api POST "$srq/$mineId/comment/initiate" (AsRequester $requesterA) @{ text = 'Needed by Monday'; internal = $true }).Status 201
$seen = (Invoke-Api GET "$srq/$mineId/retrieve" (AsRequester $requesterA)).Body
Assert-Equal 'the REQUESTER sees only the public comment' "$(@($seen.comments).Count)/$($seen.comments[0].internal)" '1/False'
Assert-Equal 'the REQUESTER lists only their own requests' (@((Invoke-Api GET "$srq/retrieve" (AsRequester $requesterA)).Body | ForEach-Object { $_.id }) -join ',') $mineId
Assert-Equal 'staff list sees them all' (@((Invoke-Api GET "$srq/retrieve" $staff).Body | Where-Object { $_.id -eq $id -or $_.id -eq $mineId -or $_.id -eq $wid }).Count) 3
Assert-Equal 'open-only leaves out the finished ones' (@((Invoke-Api GET "$srq/retrieve?openOnly=true" $staff).Body | Where-Object { $_.id -eq $id -or $_.id -eq $rid -or $_.id -eq $cid }).Count) 0
Assert-Equal 'another requester gets a 404 for it' (Invoke-Api GET "$srq/$mineId/retrieve" (AsRequester $requesterB)).Status 404
Assert-Equal 'another requester cannot comment on it (404)' (Invoke-Api POST "$srq/$mineId/comment/initiate" (AsRequester $requesterB) @{ text = 'hi' }).Status 404
$denied = Invoke-Api PUT "$srq/$mineId/control/start-fulfilment" (AsRequester $requesterA)
Assert-Equal 'a REQUESTER cannot start fulfilment (403 ERR-SRQ-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-SRQ-00403'
Assert-Equal 'another requester cannot cancel it (404)' (Invoke-Api PUT "$srq/$mineId/control/cancel" (AsRequester $requesterB)).Status 404
Assert-Equal 'a REQUESTER cancels their own request (204)' (Invoke-Api PUT "$srq/$mineId/control/cancel" (AsRequester $requesterA)).Status 204
Assert-Equal 'it is CANCELLED and owes no SLA' "$((Get-Request $mineId).status)/$([bool](Get-Request $mineId).fulfilment)" 'CANCELLED/False'
Assert-Equal 'a REQUESTER cannot decide an approval (403)' (Invoke-Api PUT "$srq/$mineId/approval/capture" (AsRequester $requesterA) @{ outcome = 'APPROVE' }).Status 403
Assert-Equal 'a REQUESTER cannot read the audit trail (403)' (Invoke-Api GET "$srq/$mineId/audit-log/retrieve" (AsRequester $requesterA)).Status 403
Assert-Equal 'another tenant gets a 404 for the request' (Invoke-Api GET "$srq/$mineId/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }).Status 404
Assert-Equal 'another tenant cannot order this tenant item (404)' (Invoke-Api POST "$srq/initiate" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser } @{ catalogItemId = $laptopId; answers = @{ model = 'X1' }; requesterId = $filedFor }).Status 404

# 5. A race: two people move the same request at the same instant.
$raced = (New-Request $laptopId @{ model = 'X2' }).Body.id
$move = {
    param($url, $tenant, $executor)
    try { [int](Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }).StatusCode }
    catch { [int]$_.Exception.Response.StatusCode }
}
$jobs = @((Start-Job -ScriptBlock $move -ArgumentList "$srq/$raced/control/start-fulfilment", $tenantId, $staffUser),
          (Start-Job -ScriptBlock $move -ArgumentList "$srq/$raced/control/cancel", $tenantId, $staffUser2))
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'each racer is told 204 or 409, never an error' (@($codes | Where-Object { $_ -ne 204 -and $_ -ne 409 }).Count) 0
$final = (Get-Request $raced)
Assert-Equal 'the request ends in a legal state' (@('IN_FULFILMENT', 'CANCELLED') -contains $final.status) $true
# Cancelling an IN_FULFILMENT request is legal, so both may win one after the other; what must never happen is a lost or doubled move:
# the trail is the opening plus exactly one entry for every request that was answered 204.
Assert-Equal 'the audit trail holds the opening plus one entry per accepted move' @((Invoke-Api GET "$srq/$raced/audit-log/retrieve" $staff).Body).Count (1 + @($codes | Where-Object { $_ -eq 204 }).Count)

# 6. Retire, and the ledger.
Assert-Equal 'retire the item' (Invoke-Api PUT "$cat/$laptopId/control/retire" $staff).Status 204
Assert-Equal 'a RETIRED item can no longer be requested (409)' (New-Request $laptopId @{ model = 'X1' }).Status 409
Assert-Equal 'a request made before stays as it was (snapshot intact)' "$((Get-Request $id).status)/$((Get-Request $id).catalogItemName)" 'CLOSED/New laptop (standard)'
Assert-Equal 'a delete is not a thing (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$srq/$id" $staff).Status) $true
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-service-request' })
    $recorded = $entries.Count
    if ($recorded -ge 40) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 40) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Service request smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
