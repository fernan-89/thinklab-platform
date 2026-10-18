<#
.SYNOPSIS
  Live proof of Journey 15, first service: the vendor registry through the platform gateway (vendor-registry ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8108, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a vendor is a name and a category: registered, found by status and category, renamed; the same name twice is a 409;
    (2) four agreements judged on their own day: EXPIRING with the days left, IN_FORCE, EXPIRED with negative days, NOT_STARTED; the list finds
        each standing, kind, asset and vendor;
    (3) the same reference registered by twenty people at once is ONE agreement (one 201, nineteen 409); the same reference for another vendor is fine;
    (4) a renewal is a new last day; two people pausing at once get one winner; a paused agreement is not judged and has no days;
    (5) two people deactivating a vendor at once get one winner; an inactive vendor takes no new agreement; the trails read in order;
    (6) an unknown category and a date that cannot be read are refused (400) and never repeated; dates and notices out of range are refused;
    (7) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (8) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    powershell -File .\vendor-smoke.ps1
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

function Day([int]$Days) { (Get-Date).ToUniversalTime().Date.AddDays($Days).ToString('yyyy-MM-dd') }

$vnd = "$GatewayUrl/it-vendor-registry/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Vendor-Body([string]$Name, [string]$Category) { @{ name = $Name; category = $Category } }
function Agreement-Body([string]$Vendor, [string]$Kind, [string]$Reference, $Asset, [string]$StartsOn, [string]$EndsOn, [int]$Notice) {
    @{ vendorId = $Vendor; kind = $Kind; reference = $Reference; assetId = $Asset; startsOn = $StartsOn; endsOn = $EndsOn; noticeDays = $Notice; autoRenew = $false }
}
function Get-Agreement([string]$Id) { (Invoke-Api GET "$vnd/agreement/$Id/retrieve" $staff).Body }
function Ids([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.id }) | Sort-Object) -join ',' }
function Count([string]$Url) { @((Invoke-Api GET $Url $staff).Body).Count }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }

# 1. A vendor is a name and a category.
$created = Invoke-Api POST "$vnd/initiate" $staff (Vendor-Body 'Dell' 'HARDWARE')
$vendor = $created.Body.id
Assert-Equal 'staff register a vendor: 201, ACTIVE, with its category' "$($created.Status)/$($created.Body.status)/$($created.Body.category)" '201/ACTIVE/HARDWARE'
Assert-Equal 'the list finds it by status and category and not by another category' "$(Ids "$vnd/retrieve?status=ACTIVE&category=HARDWARE")/$(Count "$vnd/retrieve?category=CLOUD")" "$vendor/0"
Assert-Equal 'a vendor is renamed and recategorised (204)' (Invoke-Api PUT "$vnd/$vendor/update" $staff (Vendor-Body 'Dell Technologies' 'SERVICES')).Status 204
$renamed = (Invoke-Api GET "$vnd/$vendor/retrieve" $staff).Body
Assert-Equal 'and the change is kept' "$($renamed.name)/$($renamed.category)" 'Dell Technologies/SERVICES'
Assert-Equal 'the same name in the same organisation is a conflict (409)' (Invoke-Api POST "$vnd/initiate" $staff (Vendor-Body 'Dell Technologies' 'OTHER')).Status 409

# 2. Four agreements, one for each way of standing.
$expiring = Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'WARRANTY' 'WTY-2026/01' $assetId (Day -400) (Day 20) 30)
$expiringId = $expiring.Body.id
Assert-Equal 'a warranty ending in 20 days with 30 days of notice: 201, EXPIRING, 20 days left' "$($expiring.Status)/$($expiring.Body.standing)/$($expiring.Body.daysToEnd)" '201/EXPIRING/20'
$inForce = (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'CONTRACT' 'CT-2026/02' $null (Day -10) (Day 400) 30)).Body.id
$ended = (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'SUPPORT' 'SUP-1' $assetId (Day -400) (Day -10) 30)).Body.id
$future = (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'LICENSE' 'LIC-1' $null (Day 10) (Day 100) 30)).Body.id
Assert-Equal 'a contract in force for 400 days, a support plan that ended 10 days ago and a licence that starts in 10 days are judged on their own' "$((Get-Agreement $inForce).standing)/$((Get-Agreement $ended).standing)/$((Get-Agreement $ended).daysToEnd)/$((Get-Agreement $future).standing)" 'IN_FORCE/EXPIRED/-10/NOT_STARTED'
Assert-Equal 'the list finds each standing, kind and asset' "$(Ids "$vnd/agreement/retrieve?standing=EXPIRING")/$(Ids "$vnd/agreement/retrieve?standing=EXPIRED")/$(Ids "$vnd/agreement/retrieve?standing=NOT_STARTED")/$(Ids "$vnd/agreement/retrieve?assetId=$assetId")" "$expiringId/$ended/$future/$((@($expiringId, $ended) | Sort-Object) -join ',')"
Assert-Equal 'and by vendor and kind; all four are listed' "$(Ids "$vnd/agreement/retrieve?vendorId=$vendor&kind=CONTRACT")/$(Count "$vnd/agreement/retrieve")" "$inForce/4"

# 3. The same reference twenty times at once is one agreement.
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$same = (Agreement-Body $vendor 'CONTRACT' 'RACE-1' $null (Day -1) (Day 100) 10) | ConvertTo-Json
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$vnd/agreement/initiate", $tenantId, $user, $same }
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'the same reference registered by twenty people at once: one 201, nineteen 409, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '409' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '409' }).Count)" '1/19/0'
Assert-Equal 'and exactly one such agreement exists' @((Invoke-Api GET "$vnd/agreement/retrieve?kind=CONTRACT" $staff).Body | Where-Object { $_.reference -eq 'RACE-1' }).Count 1
$second = (Invoke-Api POST "$vnd/initiate" $staff (Vendor-Body 'Acme Cloud' 'CLOUD')).Body.id
Assert-Equal 'the same reference for another vendor is fine (201)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $second 'CONTRACT' 'RACE-1' $null (Day -1) (Day 100) 10)).Status 201

# 4. A renewal is a new last day; pausing stops the judging.
Assert-Equal 'the support plan is renewed: another kind and a last day a year ahead (204)' (Invoke-Api PUT "$vnd/agreement/$ended/update" $staff @{ kind = 'CONTRACT'; assetId = $null; startsOn = (Day -400); endsOn = (Day 365); noticeDays = 60; autoRenew = $true }).Status 204
$renewed = Get-Agreement $ended
Assert-Equal 'it is in force again, with the reference it had' "$($renewed.standing)/$($renewed.reference)/$($renewed.kind)" 'IN_FORCE/SUP-1/CONTRACT'
$pause = {
    param($url, $tenant, $executor)
    try { $r = Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$vnd/agreement/$expiringId/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
Assert-Equal 'two people pausing the same agreement at once: one 204 and one 409' ((@($jobs | Wait-Job | Receive-Job) | Sort-Object) -join '/') '204/409'
$jobs | Remove-Job
$paused = Get-Agreement $expiringId
Assert-Equal 'a paused agreement is not judged: PAUSED and no days (the field is left out)' "$($paused.status)/$($paused.standing)/$($null -eq $paused.daysToEnd)" 'PAUSED/PAUSED/True'
Assert-Equal 'resume' (Invoke-Api PUT "$vnd/agreement/$expiringId/control/resume" $staff).Status 204
Assert-Equal 'the agreement trail holds each real change once, in order' (Actions "$vnd/agreement/$expiringId/audit-log/retrieve") 'INITIATED,PAUSED,RESUMED'

# 5. An inactive vendor takes no new agreement; two people deactivating at once get one winner.
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$vnd/$second/control/deactivate", $tenantId, ([guid]::NewGuid().ToString()) }
Assert-Equal 'two people deactivating the same vendor at once: one 204 and one 409' ((@($jobs | Wait-Job | Receive-Job) | Sort-Object) -join '/') '204/409'
$jobs | Remove-Job
Assert-Equal 'an agreement with the inactive vendor is refused (409)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $second 'CONTRACT' 'LATE-1' $null (Day -1) (Day 100) 10)).Status 409
Assert-Equal 'the list shows it as INACTIVE' (Ids "$vnd/retrieve?status=INACTIVE") $second
Assert-Equal 'activate (204) and an agreement is accepted again (201)' "$((Invoke-Api PUT "$vnd/$second/control/activate" $staff).Status)/$((Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $second 'CONTRACT' 'LATE-1' $null (Day -1) (Day 100) 10)).Status)" '204/201'
Assert-Equal 'the vendor trail holds each real change once, in order' (Actions "$vnd/$second/audit-log/retrieve") 'INITIATED,DEACTIVATED,ACTIVATED'

# 6. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Invoke-Api POST "$vnd/initiate" $staff '{"name":"n","category":"HARDWARE-secret-value"}'
Assert-Equal 'an unknown category is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text.Contains('secret-value'))" '400/False'
$baddate = Invoke-Api POST "$vnd/agreement/initiate" $staff "{`"vendorId`":`"$vendor`",`"kind`":`"CONTRACT`",`"reference`":`"BAD-1`",`"startsOn`":`"secret-31/12/2026`",`"endsOn`":`"$(Day 100)`",`"noticeDays`":10,`"autoRenew`":false}"
Assert-Equal 'a date that cannot be read is refused (400) and the answer does not repeat it' "$($baddate.Status)/$($baddate.Text.Contains('secret'))" '400/False'
Assert-Equal 'an agreement that ends before it starts is refused (400)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'CONTRACT' 'BAD-2' $null (Day 100) (Day 10) 10)).Status 400
Assert-Equal 'a term over 3660 days is refused (400)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'CONTRACT' 'BAD-3' $null (Day -10) (Day 5000) 10)).Status 400
Assert-Equal 'a reference that is a sentence is refused (400)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'CONTRACT' 'not an identifier' $null (Day -10) (Day 100) 10)).Status 400
Assert-Equal 'a notice over 365 days is refused (400)' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body $vendor 'CONTRACT' 'BAD-4' $null (Day -10) (Day 100) 366)).Status 400
Assert-Equal 'an agreement for a vendor that is not the tenant''s is a 404' (Invoke-Api POST "$vnd/agreement/initiate" $staff (Agreement-Body ([guid]::NewGuid().ToString()) 'CONTRACT' 'BAD-5' $null (Day -10) (Day 100) 10)).Status 404

# 7. Staff only, the tenant.
$refused = Invoke-Api POST "$vnd/initiate" $asRequester (Vendor-Body 'r' 'OTHER')
Assert-Equal 'a REQUESTER cannot register a vendor (403 ERR-VND-00403)' "$($refused.Status)/$($refused.Body.error_code)" '403/ERR-VND-00403'
Assert-Equal 'a REQUESTER cannot read a vendor (403)' (Invoke-Api GET "$vnd/$vendor/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot record an agreement (403)' (Invoke-Api POST "$vnd/agreement/initiate" $asRequester (Agreement-Body $vendor 'CONTRACT' 'R-1' $null (Day -10) (Day 100) 10)).Status 403
Assert-Equal 'a REQUESTER cannot list the agreements (403)' (Invoke-Api GET "$vnd/agreement/retrieve" $asRequester).Status 403
Assert-Equal 'another tenant gets a 404 for the vendor and for the agreement' "$((Invoke-Api GET "$vnd/$vendor/retrieve" $otherTenant).Status)/$((Invoke-Api GET "$vnd/agreement/$expiringId/retrieve" $otherTenant).Status)" '404/404'
Assert-Equal 'and finds no vendor and no agreement' "$(@((Invoke-Api GET "$vnd/retrieve" $otherTenant).Body).Count)/$(@((Invoke-Api GET "$vnd/agreement/retrieve" $otherTenant).Body).Count)" '0/0'
$deleted = (Invoke-Api DELETE "$vnd/$vendor" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 8. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-vendor-registry' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-vendor-registry' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Vendor smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
