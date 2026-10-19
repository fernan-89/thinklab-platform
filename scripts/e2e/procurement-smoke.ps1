<#
.SYNOPSIS
  Live proof of Journey 15, sixth service: purchase orders through the platform gateway, against the REAL approval service (procurement ADR-030..034).

.DESCRIPTION
  Needs the stack up with it-procurement started with THINKLAB_PO_POLICY_ID (start-local-stack.ps1 provisions the purchase-order ApprovalPolicy before starting
  it and writes it to the run directory as procurement-policy.json; provision-change-management.sh writes .e2e/procurement-policy.json in the Docker stack).
  Uses its own tenant id, then drives, through the GATEWAY:
    (1) a draft (the total, the lines in minor units), a duplicate reference (409), an update that replaces the lines;
    (2) approval on the REAL approval service: sent for approval, an approver who is not eligible refused (409), an eligible approver approves, a decision on an
        order not waiting refused, placed with the vendor; a rejection is final;
    (3) receiving: partial, the same receipt again (200), a delivery reference reused with another quantity (409), more than is left (409), an unknown line (400),
        complete, an order that received goods cannot be cancelled;
    (4) the same receipt received by twenty people at once is ONE (one 201, nineteen 200), and twenty receipts of one unit against five to arrive leave exactly
        five (never more than was ordered);
    (5) cancelling an unreceived order, the trail in order;
    (6) an unknown category, a sentence for an item, a price with three decimals, a quantity of zero and a bad day are refused (400) and never repeated;
    (7) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (8) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    pwsh -File .\procurement-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$LedgerUrl = 'http://localhost:8094',
    [string]$PolicyFile = (Join-Path $PSScriptRoot '..\..\.e2e\procurement-policy.json')
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList
if (-not (Test-Path $PolicyFile)) { throw "Missing $PolicyFile - run start-local-stack.ps1 (or provision-change-management.sh) first." }

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

$po = "$GatewayUrl/it-procurement/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$policy = Get-Content $PolicyFile -Raw | ConvertFrom-Json
$approver = @($policy.approverIds)[0]
$outsider = [guid]::NewGuid().ToString()
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $requesterUser = [guid]::NewGuid().ToString(); $vendor = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$dock = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'dock-1' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requesterUser; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }
function Day([int]$Offset) { (Get-Date).ToUniversalTime().Date.AddDays($Offset).ToString('yyyy-MM-dd') }

$defaultLines = '[{"category":"HARDWARE","item":"LAP-14","quantity":10,"unitPrice":1500.00},{"category":"SOFTWARE","item":"OFFICE-E3","quantity":5,"unitPrice":20}]'
function Order-Body([string]$Reference, [string]$Lines = $defaultLines, [string]$ExpectedOn = 'null', [string]$Currency = 'BRL') {
    "{`"reference`":`"$Reference`",`"vendorId`":`"$vendor`",`"requesterId`":`"$requester`",`"currency`":`"$Currency`",`"expectedOn`":$ExpectedOn,`"lines`":$Lines}" }
function Line-Body([string]$Item, [int]$Quantity) { "[{`"category`":`"SUPPLIES`",`"item`":`"$Item`",`"quantity`":$Quantity,`"unitPrice`":1.50}]" }
function Decide([string]$Id, [string]$Approver, [string]$Outcome) { Invoke-Api PUT "$po/$Id/approval/capture" $staff "{`"approverId`":`"$Approver`",`"outcome`":`"$Outcome`"}" }
function Receive([string]$Id, [int]$Line, [string]$Ref, [int]$Quantity) { Invoke-Api POST "$po/$Id/receipt/initiate" $dock "{`"lineNo`":$Line,`"deliveryRef`":`"$Ref`",`"quantity`":$Quantity}" }
function Get-Order([string]$Id) { (Invoke-Api GET "$po/$Id/retrieve" $staff).Body }
function Count([string]$Url, $Headers = $staff) { @((Invoke-Api GET $Url $Headers).Body).Count }
function Placed([string]$Reference, [string]$Lines) {
    $id = (Invoke-Api POST "$po/initiate" $staff (Order-Body $Reference $Lines)).Body.id
    [void](Invoke-Api PUT "$po/$id/control/submit" $staff)
    [void](Decide $id $approver 'APPROVE')
    [void](Invoke-Api PUT "$po/$id/control/place" $staff)
    $id
}

# 1. A draft.
$first = Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-1' $defaultLines "`"$(Day 30)`"")
$order = $first.Body.id
Assert-Equal 'a purchase order is drafted (201): DRAFT, a total of 15100.00 in BRL, two lines, NOT_ORDERED' "$($first.Status)/$($first.Body.status)/$($first.Body.total)/$($first.Body.currency)/$(@($first.Body.lines).Count)/$($first.Body.fulfilment)" '201/DRAFT/15100/BRL/2/NOT_ORDERED'
Assert-Equal 'the same reference again is a conflict (409)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-1')).Status 409
$updated = Invoke-Api PUT "$po/$order/update" $staff "{`"vendorId`":`"$vendor`",`"expectedOn`":null,`"lines`":$(Line-Body 'PEN-BLUE' 20)}"
Assert-Equal 'a draft is updated (204): the lines are replaced and the total follows' "$($updated.Status)/$(@((Get-Order $order).lines).Count)/$((Get-Order $order).total)" '204/1/30'
Assert-Equal 'the list finds it by status and by vendor, and not by another status' "$(@((Invoke-Api GET "$po/retrieve?status=DRAFT&vendorId=$vendor" $staff).Body)[0].id)/$(Count "$po/retrieve?status=APPROVED")" "$order/0"

# 2. Approval through the REAL approval service.
$emptyId = (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-EMPTY' '[]')).Body.id
Assert-Equal 'an order with no lines cannot be sent for approval (400)' (Invoke-Api PUT "$po/$emptyId/control/submit" $staff).Status 400
$submitted = Invoke-Api PUT "$po/$order/control/submit" $staff
$afterSubmit = Get-Order $order
Assert-Equal 'it is sent for approval (204): PENDING_APPROVAL, with the approval request kept' "$($submitted.Status)/$($afterSubmit.status)/$([bool]$afterSubmit.approvalRequestId)" '204/PENDING_APPROVAL/True'
$updateBody = "{`"vendorId`":`"$vendor`",`"expectedOn`":null,`"lines`":$(Line-Body 'PEN-BLUE' 1)}"
$sentAgain = (Invoke-Api PUT "$po/$order/control/submit" $staff).Status
$updatedAgain = (Invoke-Api PUT "$po/$order/update" $staff $updateBody).Status
Assert-Equal 'it cannot be sent again (409) and no longer updated (409)' "$sentAgain/$updatedAgain" '409/409'
$refused = Decide $order $outsider 'APPROVE'
Assert-Equal 'an approver who is not eligible is refused by the approval service (409 ERR-PRC-00409) and the order stays waiting' "$($refused.Status)/$($refused.Body.error_code)/$((Get-Order $order).status)" '409/ERR-PRC-00409/PENDING_APPROVAL'
$approved = Decide $order $approver 'APPROVE'
Assert-Equal 'an eligible approver approves (one approval is the quorum): the order is APPROVED' "$($approved.Status)/$($approved.Body.status)" '200/APPROVED'
Assert-Equal 'a decision on an order not waiting is refused (409)' (Decide $order $approver 'APPROVE').Status 409
$placedResponse = Invoke-Api PUT "$po/$order/control/place" $staff
Assert-Equal 'it is placed with the vendor (204): ORDERED, NONE received' "$($placedResponse.Status)/$((Get-Order $order).status)/$((Get-Order $order).fulfilment)" '204/ORDERED/NONE'

# 3. A rejection is final.
$rejectedOrder = (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-REJ' (Line-Body 'CABLE' 2))).Body.id
[void](Invoke-Api PUT "$po/$rejectedOrder/control/submit" $staff)
Assert-Equal 'an eligible approver rejects: REJECTED' (Decide $rejectedOrder $approver 'REJECT').Body.status 'REJECTED'
Assert-Equal 'a rejected order cannot be placed or cancelled (409 each)' "$((Invoke-Api PUT "$po/$rejectedOrder/control/place" $staff).Status)/$((Invoke-Api PUT "$po/$rejectedOrder/control/cancel" $staff).Status)" '409/409'

# 4. Receiving: partial, idempotent, never more than ordered.
$two = Placed 'PO-2' $defaultLines
$firstReceipt = Receive $two 1 'DN-100' 4
Assert-Equal 'four of line 1 arrive (201): PARTIAL, six still to arrive' "$($firstReceipt.Status)/$((Get-Order $two).fulfilment)/$(@((Get-Order $two).lines)[0].remaining)" '201/PARTIAL/6'
Assert-Equal 'the same receipt again is 200 and nothing is counted twice' "$((Receive $two 1 'DN-100' 4).Status)/$(@((Get-Order $two).lines)[0].remaining)" '200/6'
Assert-Equal 'a delivery reference reused with another quantity is a conflict (409)' (Receive $two 1 'DN-100' 5).Status 409
Assert-Equal 'more than is still to arrive is a conflict (409)' (Receive $two 1 'DN-101' 7).Status 409
Assert-Equal 'an unknown line is refused (400)' (Receive $two 9 'DN-102' 1).Status 400
[void](Receive $two 1 'DN-103' 6); [void](Receive $two 2 'DN-103' 5)
Assert-Equal 'the rest of line 1 and all of line 2 arrive: COMPLETE' (Get-Order $two).fulfilment 'COMPLETE'
$receipts = @((Invoke-Api GET "$po/$two/receipt/retrieve" $staff).Body)
Assert-Equal 'the receipts are kept in order, with who reported them' "$(($receipts | ForEach-Object { $_.deliveryRef }) -join ',')/$($receipts[0].reportedBy)" 'DN-100,DN-103,DN-103/dock-1'
Assert-Equal 'an order that received goods cannot be cancelled (409)' (Invoke-Api PUT "$po/$two/control/cancel" $staff).Status 409
$draftId = (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-DRAFT')).Body.id
Assert-Equal 'a draft takes no receipt (409)' (Receive $draftId 1 'DN-1' 1).Status 409

# 5. The same receipt twenty times at once is one; twenty receipts of one unit against five to arrive leave exactly five.
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$race = Placed 'PO-RACE' (Line-Body 'PEN-RED' 10)
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$po/$race/receipt/initiate", $tenantId, "dock-$_", '{"lineNo":1,"deliveryRef":"DN-SAME","quantity":4}' }
$codes = @($jobs | Wait-Job | Receive-Job); $jobs | Remove-Job
Assert-Equal 'the same delivery reference received by twenty people at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'it was counted once: six still to arrive, one receipt' "$(@((Get-Order $race).lines)[0].remaining)/$(Count "$po/$race/receipt/retrieve")" '6/1'
$five = Placed 'PO-FIVE' (Line-Body 'PEN-GREEN' 5)
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$po/$five/receipt/initiate", $tenantId, "dock-$_", "{`"lineNo`":1,`"deliveryRef`":`"DN-$_`",`"quantity`":1}" }
$codes = @($jobs | Wait-Job | Receive-Job); $jobs | Remove-Job
Assert-Equal 'twenty receipts of one unit against five to arrive: exactly five accepted (201), fifteen refused (409), no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '409' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '409' }).Count)" '5/15/0'
Assert-Equal 'never more than was ordered: nothing is left to arrive, five receipts, COMPLETE' "$(@((Get-Order $five).lines)[0].remaining)/$(Count "$po/$five/receipt/retrieve")/$((Get-Order $five).fulfilment)" '0/5/COMPLETE'

# 6. Cancelling, and the trail.
$unreceived = Placed 'PO-CANCEL' (Line-Body 'PEN-BLACK' 3)
Assert-Equal 'a placed order with nothing received is cancelled (204), and cannot be cancelled twice (409)' "$((Invoke-Api PUT "$po/$unreceived/control/cancel" $staff).Status)/$((Get-Order $unreceived).status)/$((Invoke-Api PUT "$po/$unreceived/control/cancel" $staff).Status)" '204/CANCELLED/409'
Assert-Equal 'the trail holds each real change once, in order' ((@((Invoke-Api GET "$po/$two/audit-log/retrieve" $staff).Body) | ForEach-Object { $_.action }) -join ',') 'INITIATED,SUBMITTED,APPROVED,PLACED,RECEIVED,RECEIVED,RECEIVED'
Assert-Equal 'the list finds the ordered ones that are complete and none that are late' "$(@((Invoke-Api GET "$po/retrieve?fulfilment=COMPLETE&limit=1" $staff).Body)[0].fulfilment)/$(Count "$po/retrieve?late=true")" 'COMPLETE/0'

# 7. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B1' '[{"category":"JEWELRY-secret","item":"X","quantity":1,"unitPrice":1}]')
Assert-Equal 'an unknown category is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text -like '*JEWELRY*')" '400/False'
$sentence = Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B2' '[{"category":"OTHER","item":"two red pens, please secret","quantity":1,"unitPrice":1}]')
Assert-Equal 'an item that is a sentence is refused (400) and not repeated' "$($sentence.Status)/$($sentence.Text -like '*secret*')" '400/False'
Assert-Equal 'a price with three decimals is refused (400)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B3' '[{"category":"OTHER","item":"X","quantity":1,"unitPrice":1.005}]')).Status 400
Assert-Equal 'a quantity of zero is refused (400)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B4' '[{"category":"OTHER","item":"X","quantity":0,"unitPrice":1}]')).Status 400
Assert-Equal 'a reference with a space is refused (400)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO B5')).Status 400
Assert-Equal 'an unknown currency is refused (400)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B6' $defaultLines 'null' 'JPY')).Status 400
Assert-Equal 'an expected day in the past is refused (400)' (Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B7' $defaultLines "`"$(Day -1)`"")).Status 400
$badDay = Invoke-Api POST "$po/initiate" $staff (Order-Body 'PO-B8' $defaultLines '"secret-tomorrow"')
Assert-Equal 'a day that cannot be read is refused (400) and not repeated' "$($badDay.Status)/$($badDay.Text -like '*secret*')" '400/False'

# 8. Staff only, the tenant.
$refusedRequester = Invoke-Api POST "$po/initiate" $asRequester (Order-Body 'PO-R1')
Assert-Equal 'a REQUESTER cannot draft an order (403 ERR-PRC-00403)' "$($refusedRequester.Status)/$($refusedRequester.Body.error_code)" '403/ERR-PRC-00403'
Assert-Equal 'a REQUESTER cannot read, list or receive (403)' "$((Invoke-Api GET "$po/$order/retrieve" $asRequester).Status)/$((Invoke-Api GET "$po/retrieve" $asRequester).Status)/$((Invoke-Api POST "$po/$two/receipt/initiate" $asRequester '{"lineNo":1,"deliveryRef":"DN-R","quantity":1}').Status)" '403/403/403'
Assert-Equal 'another tenant gets a 404 for the order and finds none' "$((Invoke-Api GET "$po/$order/retrieve" $otherTenant).Status)/$(Count "$po/retrieve" $otherTenant)" '404/0'
$deleted = (Invoke-Api DELETE "$po/$order" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 9. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-procurement' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-procurement' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
$ledgerText = $entries | ConvertTo-Json -Depth 6
Assert-Equal 'nothing anyone said is on the ledger' (($ledgerText -like '*secret*') -or ($ledgerText -like '*JEWELRY*')) $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Procurement smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
