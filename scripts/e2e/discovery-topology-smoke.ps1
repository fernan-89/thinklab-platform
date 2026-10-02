<#
.SYNOPSIS
  Live proof of Journey 10: discovery -> promotion into a real Asset, tenant-configured specification
  schemas enforced by it-asset-registry (and relayed by it-discovery as ERR-DSC-00422), and a real
  $graphLookup blast radius on it-topology-graph.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 -Build) including it-discovery (8091), it-topology-graph
  (8092) and ci-type-catalog (8093). Creates its own Organisation, then:
    (1) ingest -> claim -> review/update -> promote a DiscoveredItem and reads back the REAL Asset it created;
    (2) activates a VIRTUAL_MACHINE schema requiring "cpu" on ci-type-catalog and shows it-asset-registry
        answering 422 for non-conforming specifications and 201 for conforming ones, and a promotion of a
        non-conforming item answering ERR-DSC-00422 while the item stays UNDER_REVIEW, then succeeding after a
        re-sighting supplies the missing attribute;
    (3) builds web -> app -> db on it-topology-graph and asserts the exact blast radius per direction.

    powershell -File .\discovery-topology-smoke.ps1
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
    [string]$AssetUrl = 'http://localhost:8083',
    [string]$DiscoveryUrl = 'http://localhost:8091',
    [string]$TopologyUrl = 'http://localhost:8092',
    [string]$CatalogUrl = 'http://localhost:8093'
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

function Get-Radius {
    param([string]$NodeId, [string]$Direction, [int]$MaxHops = 3)
    $r = Invoke-Api GET "$topo/$NodeId/blast-radius/retrieve?direction=$Direction&maxHops=$MaxHops" $tenant
    $pairs = @($r.Body.impactedNodes | Sort-Object hops, label | ForEach-Object { "$($_.label):$($_.hops)" })
    return ($pairs -join ',')
}

$org = "$OrgUrl/party-reference-data-directory/v1"
$asset = "$AssetUrl/it-asset-registry/v1"
$disc = "$DiscoveryUrl/it-discovery/v1"
$topo = "$TopologyUrl/it-topology-graph/v1"
$catalog = "$CatalogUrl/ci-type-catalog/v1"
$executor = @{ 'X-Executor' = 'discovery-topology-smoke' }

# 0. A real Organisation (the tenant for everything below).
$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$orgResponse = Invoke-Api POST "$org/initiate" $executor @{ corporateName = 'Journey10 Corp'; tradeName = 'J10'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@j10.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created' $orgResponse 201
$orgId = $orgResponse.Body.id
$tenant = @{ 'X-Tenant-Id' = $orgId }
$tenantAndExecutor = $executor + $tenant

# 1. Discovery: ingest -> claim -> review/update -> promote -> a REAL Asset.
$externalKey = "AA:BB:$([guid]::NewGuid().ToString('N').Substring(0,10))"
$ingest = Invoke-Api POST "$disc/initiate" $tenantAndExecutor @{ source = 'manual'; externalKey = $externalKey; name = 'Mystery sensor'; rawAttributes = @{ mac = $externalKey } }
Assert-Status 'ingest creates the item (201)' $ingest 201
$itemId = $ingest.Body.id
$again = Invoke-Api POST "$disc/initiate" $tenantAndExecutor @{ source = 'manual'; externalKey = $externalKey; name = 'Mystery sensor'; rawAttributes = @{ mac = $externalKey; vendor = 'Acme' } }
Assert-Status 're-ingesting the same key is idempotent (200)' $again 200
Assert-Equal 're-sighting keeps the same id' $again.Body.id $itemId
Assert-Status 'promote straight from DISCOVERED is refused (409)' (Invoke-Api PUT "$disc/$itemId/control/promote" $executor) 409
Assert-Status 'review/claim' (Invoke-Api PUT "$disc/$itemId/review/claim" $executor) 204
Assert-Status 'promote without a suggestedCategory is refused (409)' (Invoke-Api PUT "$disc/$itemId/control/promote" $executor) 409
Assert-Status 'review/update records the category' (Invoke-Api PUT "$disc/$itemId/review/update" $executor @{ suggestedCategory = 'IOT_SENSOR' }) 204
$promoted = Invoke-Api PUT "$disc/$itemId/control/promote" $executor
Assert-Status 'promote creates the Asset' $promoted 200
Assert-Equal 'item is PROMOTED' $promoted.Body.status 'PROMOTED'
$realAsset = Invoke-Api GET "$asset/$($promoted.Body.promotedAssetId)/retrieve" $executor
Assert-Status 'the promoted Asset really exists on it-asset-registry' $realAsset 200
Assert-Equal 'its serial number is the externalKey' $realAsset.Body.serialNumber $externalKey
Assert-Equal 'its category is the suggested one' $realAsset.Body.category 'IOT_SENSOR'
$reseenTerminal = Invoke-Api POST "$disc/initiate" $tenantAndExecutor @{ source = 'manual'; externalKey = $externalKey; name = 'Mystery sensor'; rawAttributes = @{ mac = $externalKey } }
Assert-Equal 're-detecting a PROMOTED item never reopens it' $reseenTerminal.Body.status 'PROMOTED'

# 2. Tenant-configured specification schema (ADR-027) enforced by it-asset-registry, relayed by it-discovery.
$schema = '{"type":"object","required":["cpu"]}'
$definition = Invoke-Api POST "$catalog/initiate" $tenantAndExecutor @{ category = 'VIRTUAL_MACHINE'; jsonSchema = $schema }
Assert-Status 'TypeDefinition (VIRTUAL_MACHINE) created' $definition 201
Assert-Status 'TypeDefinition activated' (Invoke-Api PUT "$catalog/$($definition.Body.id)/control/activate" $executor) 204

$bad = Invoke-Api POST "$asset/initiate" $tenantAndExecutor @{ name = 'vm-bad'; category = 'VIRTUAL_MACHINE'; serialNumber = "VM-BAD-$([guid]::NewGuid().ToString('N').Substring(0,8))"; specifications = @{} }
Assert-Status 'non-conforming specifications are rejected (422)' $bad 422
Assert-Equal 'asset error_code is ERR-AST-00422' $bad.Body.error_code 'ERR-AST-00422'
$good = Invoke-Api POST "$asset/initiate" $tenantAndExecutor @{ name = 'vm-good'; category = 'VIRTUAL_MACHINE'; serialNumber = "VM-OK-$([guid]::NewGuid().ToString('N').Substring(0,8))"; specifications = @{ cpu = '4' } }
Assert-Status 'conforming specifications are accepted (201)' $good 201
$noSchemaCategory = Invoke-Api POST "$asset/initiate" $tenantAndExecutor @{ name = 'laptop'; category = 'LAPTOP'; serialNumber = "LP-$([guid]::NewGuid().ToString('N').Substring(0,8))"; specifications = @{} }
Assert-Status 'a category with no schema is unaffected (201)' $noSchemaCategory 201

$vmKey = "VM:$([guid]::NewGuid().ToString('N').Substring(0,10))"
$vmItem = Invoke-Api POST "$disc/initiate" $tenantAndExecutor @{ source = 'manual'; externalKey = $vmKey; name = 'vm-discovered'; rawAttributes = @{ hostname = 'vm1' } }
Assert-Status 'VM item ingested' $vmItem 201
$vmId = $vmItem.Body.id
Assert-Status 'VM item claimed' (Invoke-Api PUT "$disc/$vmId/review/claim" $executor) 204
Assert-Status 'VM item categorised' (Invoke-Api PUT "$disc/$vmId/review/update" $executor @{ suggestedCategory = 'VIRTUAL_MACHINE' }) 204
$rejected = Invoke-Api PUT "$disc/$vmId/control/promote" $executor
Assert-Status 'promotion violating the schema is relayed (422)' $rejected 422
Assert-Equal 'discovery error_code is ERR-DSC-00422' $rejected.Body.error_code 'ERR-DSC-00422'
Assert-Equal 'the item stayed UNDER_REVIEW' (Invoke-Api GET "$disc/$vmId/retrieve" $executor).Body.status 'UNDER_REVIEW'
$resight = Invoke-Api POST "$disc/initiate" $tenantAndExecutor @{ source = 'manual'; externalKey = $vmKey; name = 'vm-discovered'; rawAttributes = @{ hostname = 'vm1'; cpu = '8' } }
Assert-Status 're-sighting supplies the missing cpu attribute (200)' $resight 200
Assert-Equal 'promotion now succeeds' (Invoke-Api PUT "$disc/$vmId/control/promote" $executor).Body.status 'PROMOTED'

# 3. Topology: web -> app -> db, exact blast radius per direction ($graphLookup on a real MongoDB).
function New-Node([string]$Label) {
    $r = Invoke-Api POST "$topo/initiate" $tenantAndExecutor @{ nodeType = 'ASSET'; externalId = [guid]::NewGuid().ToString(); label = $Label }
    Assert-Status "node '$Label' created" $r 201
    return $r.Body.id
}
$web = New-Node 'web'; $app = New-Node 'app'; $db = New-Node 'db'
$e1 = Invoke-Api POST "$topo/edge/initiate" $tenantAndExecutor @{ relationshipType = 'DEPENDS_ON'; sourceNodeId = $web; targetNodeId = $app }
$e2 = Invoke-Api POST "$topo/edge/initiate" $tenantAndExecutor @{ relationshipType = 'DEPENDS_ON'; sourceNodeId = $app; targetNodeId = $db }
Assert-Status 'edge web -> app created' $e1 201
Assert-Status 'edge app -> db created' $e2 201
Assert-Status 'duplicate edge is refused (409)' (Invoke-Api POST "$topo/edge/initiate" $tenantAndExecutor @{ relationshipType = 'DEPENDS_ON'; sourceNodeId = $web; targetNodeId = $app }) 409
Assert-Equal 'web DOWNSTREAM reaches app(1), db(2)' (Get-Radius $web 'DOWNSTREAM') 'app:1,db:2'
Assert-Equal 'db UPSTREAM reaches app(1), web(2)' (Get-Radius $db 'UPSTREAM') 'app:1,web:2'
Assert-Equal 'app BOTH reaches db(1), web(1)' (Get-Radius $app 'BOTH') 'db:1,web:1'
Assert-Equal 'maxHops=1 stops at the first hop' (Get-Radius $web 'DOWNSTREAM' 1) 'app:1'
Assert-Status 'retire the app -> db edge' (Invoke-Api PUT "$topo/edge/$($e2.Body.id)/control/retire" $executor) 204
Assert-Equal 'a RETIRED edge is no longer traversed' (Get-Radius $web 'DOWNSTREAM') 'app:1'
Assert-Status 'maxHops above the cap is refused (400)' (Invoke-Api GET "$topo/$web/blast-radius/retrieve?maxHops=11" $tenant) 400
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString() }
Assert-Status 'another tenant cannot see the node (404)' (Invoke-Api GET "$topo/$web/blast-radius/retrieve" $otherTenant) 404

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Discovery + topology smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
