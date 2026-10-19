<#
.SYNOPSIS
  The editions of the local stack (PowerShell port of edition.sh): the services each one starts, with a heap that suits it, and a check of what that
  costs in memory.
.DESCRIPTION
    .\edition.ps1 homelab|team|enterprise up          starts only that edition (the images must be built: build.ps1)
    .\edition.ps1 <edition> down                      stops them
    .\edition.ps1 <edition> footprint                 memory of the running containers of this project; exits 1 over the budget
    .\edition.ps1 <edition> services                  the services of the set, one per line

  Each edition contains the one before it. Environment: THINKLAB_JAVA_OPTS, THINKLAB_GATEWAY_JAVA_OPTS, THINKLAB_FOOTPRINT_BUDGET_MIB (default per edition:
  2560, 6144 and 9216 MiB), COMPOSE_FILE / COMPOSE_PROJECT_NAME. See edition.sh for what each edition holds and how the numbers were measured.
#>
param(
    [Parameter(Mandatory)][ValidateSet('homelab', 'team', 'enterprise')][string]$Edition,
    [Parameter(Mandatory)][ValidateSet('up', 'down', 'footprint', 'services')][string]$Command
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')

$homelab = @('mongo', 'nats', 'hash-token-registry', 'party-reference-data-directory', 'party-authentication', 'it-asset-registry', 'it-discovery', 'it-health-monitoring',
             'it-capacity-registry', 'it-incident-management', 'it-alerting', 'gateway')
$team = $homelab + @('site-reference-data-directory', 'it-operation-window', 'it-hardware-maintenance', 'workflow-approval', 'it-change-management', 'it-service-request',
                     'it-problem-management', 'it-knowledge-base', 'it-topology-graph', 'ci-type-catalog', 'notification-dispatch', 'it-backup-registry', 'it-patch-registry',
                     'it-dr-registry', 'it-vendor-registry', 'it-license-registry')
$enterprise = $team + @('compliance-audit-ledger', 'anchor-store', 'subscription-billing', 'consumable-inventory', 'identity-federation', 'it-external-ticketing', 'it-ipam', 'it-cloud-cost', 'it-cloud-inventory')

switch ($Edition) {
    'homelab' { $services = $homelab; $heap = '-Xmx160m'; $budgetDefault = 2560 }
    'team' { $services = $team; $heap = '-Xmx192m'; $budgetDefault = 6144 }
    'enterprise' { $services = $enterprise; $heap = '-Xmx256m'; $budgetDefault = 9216 }
}
if (-not $env:THINKLAB_JAVA_OPTS) { $env:THINKLAB_JAVA_OPTS = "$heap -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1" }
if (-not $env:THINKLAB_GATEWAY_JAVA_OPTS) { $env:THINKLAB_GATEWAY_JAVA_OPTS = '-Xmx256m -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1' }
$budget = if ($env:THINKLAB_FOOTPRINT_BUDGET_MIB) { [double]$env:THINKLAB_FOOTPRINT_BUDGET_MIB } else { [double]$budgetDefault }

switch ($Command) {
    'up' { docker compose up -d --no-build @services; exit $LASTEXITCODE }
    'down' { docker compose stop @services; exit $LASTEXITCODE }
    'services' { $services; exit 0 }
    'footprint' {
        $ids = @(docker compose ps -q @services | Where-Object { $_ })
        if ($ids.Count -eq 0) { [Console]::Error.WriteLine("no $Edition container is running (edition.ps1 $Edition up)"); exit 2 }
        $rows = foreach ($line in (docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' @ids)) {
            $parts = $line -split ' '
            $used = $parts[1]
            $n = [double]([regex]::Match($used, '^[0-9.]+').Value)
            $mib = if ($used -like '*GiB') { $n * 1024 } elseif ($used -like '*KiB') { $n / 1024 } else { $n }
            [pscustomobject]@{ Mib = $mib; Name = $parts[0] }
        }
        $total = 0.0
        foreach ($row in ($rows | Sort-Object Mib -Descending)) { Write-Output ('{0,8:N1} MiB  {1}' -f $row.Mib, $row.Name); $total += $row.Mib }
        Write-Output ('{0,8:N1} MiB  total in {1} containers (budget {2:N0} MiB)' -f $total, @($rows).Count, $budget)
        exit $(if ($total -le $budget) { 0 } else { 1 })
    }
}
