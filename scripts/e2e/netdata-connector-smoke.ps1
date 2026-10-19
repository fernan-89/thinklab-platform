<#
.SYNOPSIS
  Live proof of the Netdata connector (scripts/connectors/netdata-sync.ps1 and .sh) through the platform gateway, against a test double of a Netdata
  agent (mock-netdata.mjs, started here; PowerShell port of netdata-connector-smoke.sh).

.DESCRIPTION
  The node reaches the discovery queue once however often it is seen, each configured chart becomes a capacity sample for its policy (dimensions added
  up, a factor applied), a run in the same minute reports the same samples, a chart or a dimension the agent does not have fails that entry only, an
  agent that cannot be reached fails every entry, the token is sent when given and is never printed, and a wrong call exits 2. The agent's own alerts
  are not mirrored (the samples feed the capacity policies). Needs Node (or Docker, which runs the double in a node:22 container).

    pwsh -File .\netdata-connector-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [int]$MockPort = 19998
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList
$here = $PSScriptRoot
$connector = Join-Path $here '..\connectors\netdata-sync.ps1'
$token = 'tok-smoke-9f3a71'

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

# The double needs Node: on a machine without it, the same file runs in a container.
$mockProcess = $null; $mockContainer = $null
if (Get-Command node -ErrorAction SilentlyContinue) {
    $env:MOCK_NETDATA_PORT = "$MockPort"; $env:MOCK_NETDATA_TOKEN = $token
    $mockProcess = Start-Process -FilePath node -ArgumentList (Join-Path $here 'mock-netdata.mjs') -PassThru -WindowStyle Hidden
} else {
    $mockContainer = "mock-netdata-smoke-$PID"
    docker run -d --rm --name $mockContainer --network host -e "MOCK_NETDATA_PORT=$MockPort" -e "MOCK_NETDATA_TOKEN=$token" -v "${here}:/m:ro" node:22 node /m/mock-netdata.mjs | Out-Null
}
try {
    for ($i = 0; $i -lt 30; $i++) {
        try { Invoke-WebRequest -Uri "http://localhost:$MockPort/api/v1/info" -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing | Out-Null; break } catch { Start-Sleep -Milliseconds 500 }
    }

    $cap = "$GatewayUrl/it-capacity-registry/v1"; $dsc = "$GatewayUrl/it-discovery/v1"
    $tenantId = [guid]::NewGuid().ToString(); $asset = [guid]::NewGuid().ToString()
    $staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'smoke' }
    function Policy([string]$Name, [string]$Metric, [int]$Limit) {
        "{`"name`":`"$Name`",`"assetId`":`"$asset`",`"metric`":`"$Metric`",`"limit`":$Limit,`"warnPercent`":70,`"criticalPercent`":90,`"windowDays`":7,`"horizonDays`":30,`"reportEveryHours`":1}" }
    $ram = (Invoke-Api POST "$cap/initiate" $staff (Policy 'RAM used' 'MEMORY' 10000)).Body.id
    $disk = (Invoke-Api POST "$cap/initiate" $staff (Policy 'Root disk' 'DISK' 100)).Body.id

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "netdata-smoke-$PID"; New-Item -ItemType Directory -Path $tmp | Out-Null
    function Write-Config([string]$Name, [string]$Url, [string]$RamDimensions, [string]$DiskChart) {
        $path = Join-Path $tmp $Name
        "{`"netdata`":`"$Url`",`"nodes`":true,`"samples`":[{`"policyId`":`"$ram`",`"chart`":`"system.ram`",`"dimensions`":$RamDimensions},{`"policyId`":`"$disk`",`"chart`":`"$DiskChart`",`"dimensions`":[`"used`"],`"factor`":2.0}]}" | Set-Content -LiteralPath $path
        $path
    }
    $good = Write-Config 'good.json' "http://localhost:$MockPort" '["used","buffers"]' 'disk_space./'
    $badDimension = Write-Config 'dimension.json' "http://localhost:$MockPort" '["nope"]' 'disk_space./'
    $badChart = Write-Config 'chart.json' "http://localhost:$MockPort" '["used","buffers"]' 'no.such.chart'
    $down = Write-Config 'down.json' 'http://localhost:1' '["used","buffers"]' 'disk_space./'

    # Runs the connector in its own process, so its exit code and its output are what a caller sees.
    function Sync([string[]]$Arguments, [string]$WithToken = $token) {
        $env:NETDATA_TOKEN = $WithToken; $env:GATEWAY_URL = $GatewayUrl
        $out = & pwsh -NoProfile -File $connector @Arguments 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String); Last = (@($out | ForEach-Object { "$_" } | Where-Object { $_ -like 'netdata-sync:*' }) | Select-Object -Last 1) }
    }
    function Last-Value([string]$Id) { '{0:0.00}' -f [double](Invoke-Api GET "$cap/$Id/retrieve" $staff).Body.lastValue }

    # 1. A good run: the node and both charts.
    $run = Sync @('-Config', $good, '-OrganisationId', $tenantId)
    Assert-Equal 'a run reports the node and both samples, none failed (exit 0)' "$($run.Code)/$($run.Last)" '0/netdata-sync: 3 reported, 0 failed'
    $nodes = @((Invoke-Api GET "$dsc/retrieve?source=netdata" $staff).Body)
    Assert-Equal 'the node is in the discovery queue, once' $nodes.Count 1
    Assert-Equal 'it waits for a person (DISCOVERED), named for the host' "$($nodes[0].status)/$($nodes[0].name)" 'DISCOVERED/smoke-node'
    Assert-Equal 'it carries what Netdata knows of the machine, as text' "$($nodes[0].rawAttributes.version)/$($nodes[0].rawAttributes.cores_total)" 'v2.12.1/12'
    Assert-Equal 'the memory sample is the dimensions added up (used 2000 + buffers 50)' (Last-Value $ram) '2050.00'
    Assert-Equal 'the disk sample is times its factor (20 x 2)' (Last-Value $disk) '40.00'

    # 2. A second run: the same node is a re-sighting, never a second item, and the samples do not break.
    $run = Sync @('-Config', $good, '-OrganisationId', $tenantId)
    Assert-Equal 'running again succeeds' "$($run.Code)/$($run.Last)" '0/netdata-sync: 3 reported, 0 failed'
    Assert-Equal 'the node is still one item' @((Invoke-Api GET "$dsc/retrieve?source=netdata" $staff).Body).Count 1
    Assert-Equal 'the samples are the same' "$(Last-Value $ram)/$(Last-Value $disk)" '2050.00/40.00'

    # 3. Failures: only the entry that cannot be read fails.
    $run = Sync @('-Config', $badDimension, '-OrganisationId', $tenantId)
    Assert-Equal 'a dimension the chart does not have fails that entry only (exit 1)' "$($run.Code)/$($run.Last)" '1/netdata-sync: 2 reported, 1 failed'
    Assert-Equal 'it says which chart' ($run.Out -like '*FAILED  system.ram*') $true
    $run = Sync @('-Config', $badChart, '-OrganisationId', $tenantId)
    Assert-Equal 'a chart the agent does not have fails that entry only (exit 1)' "$($run.Code)/$($run.Last)" '1/netdata-sync: 2 reported, 1 failed'
    $run = Sync @('-Config', $down, '-OrganisationId', $tenantId)
    Assert-Equal 'an agent that cannot be reached fails every entry (exit 1)' "$($run.Code)/$($run.Last)" '1/netdata-sync: 0 reported, 3 failed'

    # 4. The token: sent when given, never printed.
    $run = Sync @('-Config', $good, '-OrganisationId', $tenantId) ''
    Assert-Equal 'without the token the agent refuses and nothing is reported (exit 1)' $run.Code 1
    $run = Sync @('-Config', $good, '-OrganisationId', $tenantId)
    Assert-Equal 'the token is never printed' ($run.Out -like "*$token*") $false

    # 5. A wrong call.
    $run = Sync @()
    Assert-Equal 'no arguments exit 2' $run.Code 2
    $run = Sync @('-Config', (Join-Path $tmp 'does-not-exist.json'), '-OrganisationId', $tenantId)
    Assert-Equal 'a config that is not there exits 2' $run.Code 2

    # 6. The tenant: another tenant sees none of it.
    Assert-Equal 'another tenant finds no node' @((Invoke-Api GET "$dsc/retrieve?source=netdata" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = 'smoke' }).Body).Count 0
} finally {
    if ($mockProcess) { Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($mockContainer) { docker rm -f $mockContainer 2>&1 | Out-Null }
    Remove-Item Env:NETDATA_TOKEN -ErrorAction SilentlyContinue
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Netdata connector smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
