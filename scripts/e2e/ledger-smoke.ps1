<#
.SYNOPSIS
  Live proof of Journey 8: the platform gateway records every mutating request on the compliance ledger, and the
  ledger's hash chain verifies.

.DESCRIPTION
  Needs the stack up with the gateway started with GATEWAY_AUDIT_ENABLED=true (start-local-stack.ps1 does that) and
  the ledger on 8094. Creates its own Organisation, then drives an Asset through the GATEWAY:
    (1) initiate, assignment/update and control/ready are each recorded (method + masked path, actor, resource,
        status), a read is not, and a refused call (deploy without a location, 409) is recorded with its status;
    (2) the entries chain: positions 1..4, each linked to the hash before it;
    (3) integrity-check/evaluate answers valid with the head at the last entry, through the gateway too.

    powershell -File .\ledger-smoke.ps1
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
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

$executor = @{ 'X-Executor' = 'ledger-smoke' }

# 0. A real Organisation (the tenant whose chain we inspect).
$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$orgResponse = Invoke-Api POST "$OrgUrl/party-reference-data-directory/v1/initiate" $executor @{ corporateName = 'Ledger Corp'; tradeName = 'LED'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@led.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created' $orgResponse 201
$tenant = $executor + @{ 'X-Tenant-Id' = $orgResponse.Body.id }
$gw = "$GatewayUrl/it-asset-registry/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"

# 1. Mutations through the gateway: three that succeed, a read that must not be recorded, one that is refused.
$serial = "SN-LED-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$created = Invoke-Api POST "$gw/initiate" $tenant @{ name = 'Audited switch'; category = 'NETWORK_DEVICE'; serialNumber = $serial; specifications = @{ model = 'SW-1' } }
Assert-Status 'asset initiated through the gateway' $created 201
$assetId = $created.Body.id
Assert-Status 'assignment/update through the gateway' (Invoke-Api PUT "$gw/$assetId/assignment/update" $tenant @{ locationId = [guid]::NewGuid().ToString() }) 204
Assert-Status 'control/ready through the gateway' (Invoke-Api PUT "$gw/$assetId/control/ready" $tenant) 204
Assert-Status 'a read through the gateway' (Invoke-Api GET "$gw/$assetId/retrieve" $tenant) 200
Assert-Status 'control/ready again is refused (409)' (Invoke-Api PUT "$gw/$assetId/control/ready" $tenant) 409

# 2. The gateway appends asynchronously: wait (bounded) until all four land.
$entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve" @{ 'X-Tenant-Id' = $orgResponse.Body.id }).Body)
    if ($entries.Count -ge 4) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'exactly the four mutations were recorded (the read was not)' $entries.Count 4

# Newest first.
$refused, $ready, $assignment, $initiate = $entries
Assert-Equal 'oldest: POST initiate, masked' $initiate.action 'POST /it-asset-registry/v1/initiate'
Assert-Equal 'oldest: status=201' $initiate.detail 'status=201'
Assert-Equal 'assignment/update, masked' $assignment.action 'PUT /it-asset-registry/v1/{id}/assignment/update'
Assert-Equal 'control/ready, masked' $ready.action 'PUT /it-asset-registry/v1/{id}/control/ready'
Assert-Equal 'control/ready: the resource id is the asset' $ready.resourceId $assetId
Assert-Equal 'the refused call is on the ledger too, with its status' $refused.detail 'status=409'
Assert-Equal 'actor is the caller (X-Executor)' $ready.actor 'ledger-smoke'
Assert-Equal 'resourceType is the Service Domain' $ready.resourceType 'it-asset-registry'
Assert-Equal 'source is the gateway' $ready.source 'platform-gateway'
Assert-Equal 'the writer recorded as executor is the gateway' $ready.recordedBy 'platform-gateway'

# 3. The entries form one chain.
Assert-Equal 'positions 1..4 (oldest to newest)' (($initiate, $assignment, $ready, $refused | ForEach-Object { $_.sequence }) -join ',') '1,2,3,4'
Assert-Equal 'the first entry sits on the genesis hash' $initiate.previousHash ('0' * 64)
Assert-Equal 'each entry links to the one before' (($assignment.previousHash -eq $initiate.hash) -and ($ready.previousHash -eq $assignment.hash) -and ($refused.previousHash -eq $ready.hash)) $true

$byResource = Invoke-Api GET "$ledger/retrieve?resourceType=it-asset-registry&resourceId=$assetId" @{ 'X-Tenant-Id' = $orgResponse.Body.id }
Assert-Equal 'filtering by resource id finds the three calls on that asset' @($byResource.Body).Count 3

# 4. Integrity, directly and through the gateway (reads are not recorded, so the chain does not grow).
$direct = Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $orgResponse.Body.id }
Assert-Equal 'chain is valid' $direct.Body.valid $true
Assert-Equal 'four entries checked' $direct.Body.entriesChecked 4
Assert-Equal 'head hash is the newest entry hash' $direct.Body.headHash $refused.hash
$viaGateway = Invoke-Api GET "$GatewayUrl/compliance-audit-ledger/v1/integrity-check/evaluate" @{ 'X-Tenant-Id' = $orgResponse.Body.id }
Assert-Status 'integrity check is reachable through the gateway' $viaGateway 200
Assert-Equal 'same verdict through the gateway' $viaGateway.Body.headHash $refused.hash

# 5. Another tenant sees none of it.
$other = Invoke-Api GET "$ledger/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString() }
Assert-Equal 'another tenant has an empty ledger' @($other.Body).Count 0

# 6. Data protection (ledger ADR-033, gateway ADR-024): a sign-in attempt is recorded with a keyed pseudonym of the email and the
#    outcome - and neither the password nor the email appears anywhere on the ledger.
$secretEmail = "smoke.$([guid]::NewGuid().ToString('N').Substring(0,8))@example.com"
$secretPassword = "Sm0ke-P@ss-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$signIn = Invoke-Api POST "$GatewayUrl/party-authentication/v1/session/initiate" @{} @{ organisationId = $orgResponse.Body.id; email = $secretEmail; password = $secretPassword }
Assert-Equal 'a sign-in with unknown credentials is refused (4xx)' ($signIn.Status -ge 400 -and $signIn.Status -lt 500) $true
$loginEntry = $null
for ($i = 0; $i -lt 20; $i++) {
    $all = @((Invoke-Api GET "$ledger/retrieve?limit=50" @{ 'X-Tenant-Id' = $orgResponse.Body.id }).Body)
    $loginEntry = $all | Where-Object { $_.action -eq 'POST /party-authentication/v1/session/initiate' } | Select-Object -First 1
    if ($loginEntry) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the sign-in attempt was recorded' ($null -ne $loginEntry) $true
Assert-Equal 'actor is a keyed pseudonym, not the email' ($loginEntry.actor -match '^login:[0-9a-f]{32}$') $true
Assert-Equal 'the outcome is recorded' $loginEntry.detail "status=$($signIn.Status)"
$ledgerDump = (Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $orgResponse.Body.id }).Body | ConvertTo-Json -Depth 6
Assert-Equal 'the password appears nowhere on the ledger' $ledgerDump.Contains($secretPassword) $false
Assert-Equal 'the email appears nowhere on the ledger' $ledgerDump.ToLower().Contains($secretEmail.ToLower().Split('@')[0]) $false
$stillValid = Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $orgResponse.Body.id }
Assert-Equal 'the chain is still valid with the sign-in entry on it' $stillValid.Body.valid $true

# 7. Anchoring (ledger ADR-034): the head of the chain is published outside the database, and the chain then verifies against it.
$anchor = Invoke-Api POST "$ledger/anchor/initiate" $tenant
Assert-Status 'anchor/initiate publishes the chain head (201)' $anchor 201
Assert-Equal 'anchor outcome is PUBLISHED' $anchor.Body.status 'PUBLISHED'
Assert-Equal 'the anchor sits at the current head' $anchor.Body.anchor.headSequence ((Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $orgResponse.Body.id }).Body.headSequence)
$again = Invoke-Api POST "$ledger/anchor/initiate" $tenant
Assert-Status 'anchoring again with nothing new answers 200' $again 200
Assert-Equal 'and reports UNCHANGED' $again.Body.status 'UNCHANGED'
$anchored = Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $orgResponse.Body.id }
Assert-Equal 'the chain is valid against its anchor' $anchored.Body.valid $true
Assert-Equal 'one anchor was verified' $anchored.Body.anchorsVerified 1
Assert-Equal 'anchor/retrieve lists the published anchor' @((Invoke-Api GET "$ledger/anchor/retrieve" @{ 'X-Tenant-Id' = $orgResponse.Body.id }).Body).Count 1

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Ledger smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
