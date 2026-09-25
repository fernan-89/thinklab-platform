<#
.SYNOPSIS
  Stops the services started by start-local-stack.ps1 (and MongoDB with -IncludeMongo).
#>
param([switch]$IncludeMongo)

. (Join-Path $PSScriptRoot 'Common.ps1')
$file = Join-Path $RunDir 'pids.json'
if (Test-Path $file) {
    $pids = Get-Content $file -Raw | ConvertFrom-Json
    foreach ($prop in $pids.PSObject.Properties) {
        if ($prop.Name -eq 'mongod' -and -not $IncludeMongo) { continue }
        Stop-Process -Id $prop.Value -Force -ErrorAction SilentlyContinue
        Write-Host "stopped $($prop.Name) ($($prop.Value))"
    }
    Remove-Item $file -Force
}
foreach ($s in $Services) {
    # Anything still listening on the service ports (e.g. started by hand) is stopped as well.
    Get-NetTCPConnection -LocalPort $s.Port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}
# NATS is always stopped (unlike mongod, it isn't gated behind -IncludeMongo) - cheap to restart, and a
# leftover broker between runs is more confusing than a leftover database.
Get-NetTCPConnection -LocalPort 4222 -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
Get-Process nats-server -ErrorAction SilentlyContinue | Stop-Process -Force
if ($IncludeMongo) { Get-Process mongod -ErrorAction SilentlyContinue | Stop-Process -Force }
