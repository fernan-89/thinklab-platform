<#
.SYNOPSIS
  Seeds a demo tenant through the gateway so the web app (thinklab-web) has something to show.
.DESCRIPTION
  Creates one Organisation, a handful of assets in different lifecycle states, a few items waiting in the
  discovery queue (one already claimed), and a small web -> app -> db dependency graph. Prints the
  organisation id to sign in with. Needs the stack from start-local-stack.ps1 (security off).
#>
param([string]$Gateway = 'http://localhost:8088')

$ErrorActionPreference = 'Stop'
$executor = @{ 'X-Executor' = 'demo-seed' }

function Invoke-Gateway([string]$Method, [string]$Path, [hashtable]$Headers, $Body) {
    $args = @{ Method = $Method; Uri = "$Gateway$Path"; Headers = $Headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $args.Body = ($Body | ConvertTo-Json -Depth 6) }
    Invoke-RestMethod @args
}

$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$org = Invoke-Gateway POST '/party-reference-data-directory/v1/initiate' $executor @{
    corporateName = 'Demo Corp'; tradeName = 'Demo'; taxIdentifier = $taxId
    billing = @{ billingEmail = 'billing@demo.example'; currency = 'USD'; taxRegime = 'SIMPLES' }
}
$tenant = $executor + @{ 'X-Tenant-Id' = $org.id }

# Assets: a spread of categories and lifecycle states.
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
$assets = @(
    @{ name = 'Core switch'; category = 'NETWORK_DEVICE'; serial = "SW-$suffix-1"; spec = @{ model = 'SW-9000'; ports = '48' }; steps = @('ready', 'deploy') },
    @{ name = 'Database server'; category = 'SERVER'; serial = "SRV-$suffix-2"; spec = @{ cpu = 'Xeon 6'; ram = '512 GB' }; steps = @('ready', 'deploy', 'maintenance') },
    @{ name = 'Reception laptop'; category = 'LAPTOP'; serial = "LT-$suffix-3"; spec = @{ model = 'ThinkBook 14' }; steps = @('ready') },
    @{ name = 'Spare firewall'; category = 'NETWORK_DEVICE'; serial = "FW-$suffix-4"; spec = @{ model = 'FG-100F' }; steps = @() },
    @{ name = 'Old print server'; category = 'SERVER'; serial = "PS-$suffix-5"; spec = @{}; steps = @('decommission') }
)
foreach ($a in $assets) {
    $created = Invoke-Gateway POST '/it-asset-registry/v1/initiate' $tenant @{ name = $a.name; category = $a.category; serialNumber = $a.serial; specifications = $a.spec }
    # An asset cannot be DEPLOYED without a location (a real business rule the web app surfaces too).
    if ($a.steps -contains 'deploy') { Invoke-Gateway PUT "/it-asset-registry/v1/$($created.id)/assignment/update" $executor @{ locationId = [guid]::NewGuid().ToString() } | Out-Null }
    foreach ($step in $a.steps) { Invoke-Gateway PUT "/it-asset-registry/v1/$($created.id)/control/$step" $executor $null | Out-Null }
}

# Discovery queue: two waiting, one already claimed and ready to be promoted.
$found = @(
    @{ source = 'nmap-scanner-01'; externalKey = "aa:bb:cc:${suffix}:01"; name = 'unknown-host-17'; rawAttributes = @{ ip = '10.0.4.17'; os = 'Linux 6.1' } },
    @{ source = 'nmap-scanner-01'; externalKey = "aa:bb:cc:${suffix}:02"; name = 'printer-2f'; rawAttributes = @{ ip = '10.0.4.40'; vendor = 'HP' } },
    @{ source = 'manual'; externalKey = "rack-9-$suffix"; name = 'rack-9 switch'; rawAttributes = @{ location = 'DC1 / rack 9' } }
)
$items = foreach ($f in $found) { Invoke-Gateway POST '/it-discovery/v1/initiate' $tenant $f }
Invoke-Gateway PUT "/it-discovery/v1/$($items[2].id)/review/claim" $executor $null | Out-Null

# Topology: users -> web -> app -> db, plus a cache the app also depends on.
function New-Node([string]$label, [string]$type) {
    Invoke-Gateway POST '/it-topology-graph/v1/initiate' $tenant @{ nodeType = $type; externalId = [guid]::NewGuid().ToString(); label = $label }
}
$web = New-Node 'web-frontend' 'SERVICE'
$app = New-Node 'orders-api' 'SERVICE'
$db = New-Node 'orders-db' 'ASSET'
$cache = New-Node 'redis-cache' 'ASSET'
$host1 = New-Node 'esx-host-1' 'ASSET'
foreach ($e in @(@($web, $app, 'DEPENDS_ON'), @($app, $db, 'DEPENDS_ON'), @($app, $cache, 'DEPENDS_ON'), @($db, $host1, 'HOSTED_ON'), @($cache, $host1, 'HOSTED_ON'))) {
    Invoke-Gateway POST '/it-topology-graph/v1/edge/initiate' $tenant @{ relationshipType = $e[2]; sourceNodeId = $e[0].id; targetNodeId = $e[1].id } | Out-Null
}

Write-Output "Seeded demo tenant. Sign in to the web app with:"
Write-Output "  Organisation ID: $($org.id)"
Write-Output "  Name: any (e.g. demo)"
