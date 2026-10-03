<#
.SYNOPSIS
  Live proof of Journey 13 (consumables): stock items and their movements through the platform gateway, the balance never
  going below zero even under concurrent issues, and the gateway recording every stock mutation on the compliance ledger.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts consumable-inventory on 8096, routes it through the gateway and turns the
  gateway's ledger recording on). Uses its own tenant id (the inventory takes any UUID), then drives, through the GATEWAY:
    (1) an item is registered with an opening balance; receive, issue and a counted adjustment move it, the reorder level flag
        and the low-stock list follow the balance, and an issue larger than the balance is refused (409) and changes nothing;
    (2) eight concurrent issues of one unit against five units: exactly five succeed, three are refused, the balance ends at 0;
    (3) update and discontinue work, a discontinued item accepts no movement, another tenant cannot see or move the item;
    (4) every stock mutation - and every refused one - is on the ledger with a masked path, the actor and its status, reads are
        not, and the chain verifies.

    powershell -File .\inventory-smoke.ps1
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
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$tenantId = [guid]::NewGuid().ToString()
$tenant = @{ 'X-Executor' = 'inventory-smoke'; 'X-Tenant-Id' = $tenantId }
$stock = "$GatewayUrl/consumable-inventory/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

function Balance([string]$Id) { (Invoke-Api GET "$stock/$Id/retrieve" $tenant).Body }

# 1. An item and its movements.
$a = Invoke-Api POST "$stock/initiate" $tenant @{ sku = "smk-toner-$stamp"; name = 'HP 85A toner'; unit = 'unit'; reorderLevel = 3; initialQuantity = 10 }
Assert-Status 'item registered through the gateway' $a 201
$aId = $a.Body.id
Assert-Equal 'the SKU is normalised to upper case' $a.Body.sku "SMK-TONER-$stamp"
Assert-Equal 'it starts with the opening balance' $a.Body.onHand 10
Assert-Status 'the same SKU again is refused (409), whatever its case' (Invoke-Api POST "$stock/initiate" $tenant @{ sku = "SMK-TONER-$stamp"; name = 'again'; unit = 'unit'; reorderLevel = 1 }) 409
Assert-Status 'receive 5' (Invoke-Api PUT "$stock/$aId/movement/receive" $tenant @{ quantity = 5; reason = 'delivery' }) 204
Assert-Equal 'the balance is 15' (Balance $aId).onHand 15
Assert-Status 'issue 12' (Invoke-Api PUT "$stock/$aId/movement/issue" $tenant @{ quantity = 12; reason = 'printers' }) 204
$low = Balance $aId
Assert-Equal 'the balance is 3' $low.onHand 3
Assert-Equal '3 on hand is at the reorder level: flagged low' $low.belowReorderLevel $true
Assert-Equal 'the low-stock list names it' (@((Invoke-Api GET "$stock/low-stock/retrieve" $tenant).Body | ForEach-Object { $_.id }) -contains $aId) $true
$refused = Invoke-Api PUT "$stock/$aId/movement/issue" $tenant @{ quantity = 4 }
Assert-Status 'an issue larger than the balance is refused (409)' $refused 409
Assert-Equal 'and the refusal says there is not enough' ($refused.Body.detail -match 'only 3 on hand') $true
Assert-Equal 'nothing changed' (Balance $aId).onHand 3
Assert-Status 'an adjustment without a reason is refused (400)' (Invoke-Api PUT "$stock/$aId/movement/adjust" $tenant @{ newQuantity = 8 }) 400
Assert-Status 'a counted adjustment with its reason' (Invoke-Api PUT "$stock/$aId/movement/adjust" $tenant @{ newQuantity = 8; reason = 'recount after audit' }) 204
$adjusted = Balance $aId
Assert-Equal 'the balance is the counted 8' $adjusted.onHand 8
Assert-Equal 'which is above the reorder level again' $adjusted.belowReorderLevel $false

# 2. Concurrency: eight callers race to issue one unit each from five units.
$b = Invoke-Api POST "$stock/initiate" $tenant @{ sku = "smk-race-$stamp"; name = 'Spare SSD'; unit = 'unit'; reorderLevel = 1; initialQuantity = 5 }
Assert-Status 'a second item with 5 units registered' $b 201
$bId = $b.Body.id
$jobs = 1..8 | ForEach-Object {
    Start-Job -ArgumentList "$stock/$bId/movement/issue", $tenantId -ScriptBlock {
        param($url, $tenant)
        try {
            (Invoke-WebRequest -Method Put -Uri $url -UseBasicParsing -ContentType 'application/json' -Body '{"quantity":1,"reason":"race"}' `
                -Headers @{ 'X-Executor' = 'inventory-smoke'; 'X-Tenant-Id' = $tenant }).StatusCode
        } catch { [int]$_.Exception.Response.StatusCode }
    }
}
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'exactly five of the eight concurrent issues succeeded' @($codes | Where-Object { $_ -eq 204 }).Count 5
Assert-Equal 'and the other three were refused (409)' @($codes | Where-Object { $_ -eq 409 }).Count 3
Assert-Equal 'the balance ends at exactly 0, never below' (Balance $bId).onHand 0
$raceHistory = (Invoke-Api GET "$stock/$bId/history/retrieve" $tenant).Body
Assert-Equal 'the history has the opening entry and five issues' @($raceHistory).Count 6
Assert-Equal 'newest first, and every issue is a -1' (($raceHistory | Select-Object -First 5 | ForEach-Object { $_.quantity }) -join ',') '-1,-1,-1,-1,-1'

# 3. Update, discontinue, and the rules around them.
Assert-Status 'update name, unit and reorder level' (Invoke-Api PUT "$stock/$aId/update" $tenant @{ name = 'HP 85A toner (2 pack)'; unit = 'pack'; reorderLevel = 10 }) 204
Assert-Equal 'the new reorder level flags 8 as low' (Balance $aId).belowReorderLevel $true
Assert-Status 'discontinue' (Invoke-Api PUT "$stock/$aId/control/discontinue" $tenant) 204
Assert-Status 'a discontinued item accepts no movement (409)' (Invoke-Api PUT "$stock/$aId/movement/receive" $tenant @{ quantity = 1 }) 409
Assert-Equal 'it keeps its balance' (Balance $aId).onHand 8
Assert-Equal 'and is no longer on the low-stock list' (@((Invoke-Api GET "$stock/low-stock/retrieve" $tenant).Body | ForEach-Object { $_.id }) -contains $aId) $false
$other = @{ 'X-Executor' = 'inventory-smoke'; 'X-Tenant-Id' = [guid]::NewGuid().ToString() }
Assert-Status 'another tenant cannot read it (404)' (Invoke-Api GET "$stock/$aId/retrieve" $other) 404
Assert-Status 'another tenant cannot move it (404)' (Invoke-Api PUT "$stock/$aId/movement/receive" $other @{ quantity = 1 }) 404
$audit = (Invoke-Api GET "$stock/$aId/history/retrieve" $tenant).Body
Assert-Equal 'the history reads newest first with signed balances' (($audit | ForEach-Object { "$($_.action):$($_.balanceAfter)" }) -join ',') 'DISCONTINUED:8,UPDATED:8,ADJUSTED:8,ISSUED:3,RECEIVED:15,INITIATED:10'

# 4. The gateway put every stock mutation on the compliance ledger (the refused ones too); reads are not recorded.
$expected = 19
$entries = @()
for ($i = 0; $i -lt 30; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=100" @{ 'X-Tenant-Id' = $tenantId }).Body)
    if ($entries.Count -ge $expected) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'every mutation with the tenant is on the ledger' $entries.Count $expected
$oldestFirst = @($entries | Sort-Object { [long]$_.sequence })
Assert-Equal 'the first recorded call is the first registration' $oldestFirst[0].action 'POST /consumable-inventory/v1/initiate'
Assert-Equal 'the resource type is the Service Domain' $oldestFirst[0].resourceType 'consumable-inventory'
Assert-Equal 'a movement is recorded with a masked path' $oldestFirst[2].action 'PUT /consumable-inventory/v1/{id}/movement/receive'
Assert-Equal 'its resource id is the item' $oldestFirst[2].resourceId $aId
Assert-Equal 'the actor is the caller' $oldestFirst[2].actor 'inventory-smoke'
Assert-Equal 'every refused call is recorded with its status (duplicate SKU, big issue, 3 lost races, discontinued)' (@($entries | Where-Object { $_.detail -eq 'status=409' }).Count) 6
Assert-Equal 'reads are not recorded' (@($entries | Where-Object { $_.action -like 'GET *' }).Count) 0
$integrity = Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }
Assert-Equal 'the tenant chain is valid' $integrity.Body.valid $true
Assert-Equal 'with every entry checked' $integrity.Body.entriesChecked $expected

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Inventory smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
