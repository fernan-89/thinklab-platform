<#
.SYNOPSIS
  Netdata connector: reads one Netdata agent and reports to ThinkLab through the gateway (PowerShell port of netdata-sync.sh).
.DESCRIPTION
  Runs outside the services, as the tool that measures (capacity-registry ADR-030): no ThinkLab service reaches an asset or holds a credential.
    1. The node goes to the discovery queue (source "netdata", keyed by the agent's id): a human still reviews and promotes it. A second run is a
       re-sighting (200), not a second item.
    2. Every entry of "samples" becomes one capacity sample for its policy: the chart's average over the last few seconds, the named dimensions added
       up, times "factor" (the policy's limit and the sample must use the same unit, and Netdata's is in the chart: system.ram is MiB, disk_space GiB).
       The moment is rounded to the minute, so running twice in one minute reports one sample.
  Alerts are not mirrored: the samples feed the capacity policies, which the alerting service already watches.

  Config: {"netdata":"http://localhost:19999","nodes":true,"samples":[{"policyId":"<uuid>","chart":"system.ram","dimensions":["used"],"factor":1.0}]}
  Environment: GATEWAY_URL (default http://localhost:8088); NETDATA_TOKEN, if the agent asks for one, sent as a bearer token and never written anywhere.
  Exit codes: 0 all reported, 1 something failed, 2 wrong call.

    pwsh -File .\netdata-sync.ps1 -Config .\netdata.json -OrganisationId <uuid>
#>
param(
    [string]$Config,
    [string]$OrganisationId,
    [string]$Gateway = $(if ($env:GATEWAY_URL) { $env:GATEWAY_URL } else { 'http://localhost:8088' })
)

$ErrorActionPreference = 'Stop'
if (-not $Config -or -not $OrganisationId -or -not (Test-Path -LiteralPath $Config -PathType Leaf)) {
    [Console]::Error.WriteLine("usage: netdata-sync.ps1 -Config <config.json> -OrganisationId <organisationId>")
    exit 2
}
$cfg = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
$netdata = if ($cfg.netdata) { "$($cfg.netdata)".TrimEnd('/') } else { 'http://localhost:19999' }
$ndHeaders = @{}
if ($env:NETDATA_TOKEN) { $ndHeaders['Authorization'] = "Bearer $($env:NETDATA_TOKEN)" }
$tlHeaders = @{ 'X-Tenant-Id' = $OrganisationId; 'X-Executor' = 'netdata-sync' }
$script:reported = 0
$script:failed = 0

function Report([string]$What, [string]$Url, [string]$Body) {
    try {
        $r = Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json' -Body $Body -Headers $tlHeaders -SkipHttpErrorCheck -TimeoutSec 15
        $code = [int]$r.StatusCode
    } catch { $code = 0 }
    if ($code -eq 200 -or $code -eq 201) { $script:reported++; Write-Output ("ok      {0} ({1})" -f $What, $code) }
    else { $script:failed++; [Console]::Error.WriteLine(("FAILED  {0} (HTTP {1})" -f $What, $code)) }
}

function Read-Netdata([string]$Url) {
    $r = Invoke-WebRequest -Method Get -Uri $Url -Headers $ndHeaders -SkipHttpErrorCheck -TimeoutSec 15
    if ([int]$r.StatusCode -ne 200) { throw "HTTP $([int]$r.StatusCode)" }
    $r.Content | ConvertFrom-Json
}

$nodes = if ($null -eq $cfg.nodes) { $true } else { [bool]$cfg.nodes }
if ($nodes) {
    $info = $null
    try { $info = Read-Netdata "$netdata/api/v1/info" } catch { }
    if ($null -eq $info) {
        $script:failed++; [Console]::Error.WriteLine("FAILED  node (Netdata not reachable at $netdata, or it refused)")
    } elseif (-not $info.uid) {
        $script:failed++; [Console]::Error.WriteLine('FAILED  node (unreadable /api/v1/info)')
    } else {
        $attrs = [ordered]@{}
        foreach ($key in 'version', 'os_name', 'os_version', 'kernel_name', 'kernel_version', 'architecture', 'virtualization', 'cores_total', 'ram_total', 'total_disk_space', 'cloud_provider_type', 'cloud_instance_type') {
            $value = $info.$key
            if ($null -ne $value -and "$value" -ne '' -and "$value" -ne 'unknown') { $attrs[$key] = "$value" }
        }
        $hostName = if ($info.mirrored_hosts -and $info.mirrored_hosts.Count -gt 0) { "$($info.mirrored_hosts[0])" } else { 'netdata-node' }
        $body = [ordered]@{ source = 'netdata'; externalKey = "$($info.uid)"; name = $hostName; rawAttributes = $attrs } | ConvertTo-Json -Depth 4 -Compress
        Report 'node' "$Gateway/it-discovery/v1/initiate" $body
    }
}

$now = [DateTime]::UtcNow
$now = [DateTime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0, [DateTimeKind]::Utc).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
foreach ($entry in @($cfg.samples)) {
    if ($null -eq $entry) { continue }
    $policy = "$($entry.policyId)"; $chart = "$($entry.chart)"
    $query = "chart=$([uri]::EscapeDataString($chart))&after=-20&points=1&group=average&format=json"
    try { $data = Read-Netdata "$netdata/api/v1/data?$query" }
    catch { $script:failed++; [Console]::Error.WriteLine("FAILED  $chart (Netdata not reachable, or it refused)"); continue }
    $labels = @($data.labels | Select-Object -Skip 1)
    $row = @($data.data | Select-Object -First 1)
    $wanted = if ($entry.dimensions) { @($entry.dimensions) } else { $labels }
    $missing = @($wanted | Where-Object { $labels -notcontains $_ })
    if ($row.Count -eq 0 -or $missing.Count -gt 0) {
        $script:failed++; [Console]::Error.WriteLine("FAILED  $chart (no data, or a dimension that the chart does not have)"); continue
    }
    $values = @($row[0] | Select-Object -Skip 1)
    $total = [double]0
    foreach ($w in $wanted) { $v = $values[[array]::IndexOf($labels, $w)]; if ($null -ne $v) { $total += [double]$v } }
    $factor = if ($null -ne $entry.factor) { [double]$entry.factor } else { 1.0 }
    $value = [math]::Round($total * $factor, 4)
    $body = '{{"policyId":"{0}","value":{1},"measuredAt":"{2}"}}' -f $policy, $value.ToString([Globalization.CultureInfo]::InvariantCulture), $now
    Report ("{0} -> policy {1}" -f $chart, $policy.Substring(0, [math]::Min(8, $policy.Length))) "$Gateway/it-capacity-registry/v1/sample/initiate" $body
}

Write-Output ("netdata-sync: {0} reported, {1} failed" -f $script:reported, $script:failed)
exit ([int]($script:failed -gt 0))
