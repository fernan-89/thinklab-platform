<#
.SYNOPSIS
  Runs every service's Postman suite (newman) against the live local stack, in dependency order,
  threading the organisationId produced by the Party Reference Data Directory into the other suites.
.EXAMPLE
  powershell -File .\run-e2e.ps1            # stack must already be up (start-local-stack.ps1)
#>
param([string]$OnlyService = '')

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Continue'
$node   = Join-Path $Tools 'node\node.exe'
$newman = Join-Path $Tools 'newman\node_modules\newman\bin\newman.js'
$report = Join-Path $RunDir 'reports'
New-Item -ItemType Directory -Force $report | Out-Null
$organisationId = ''
$summary = @()

foreach ($s in $Services) {
    if ($OnlyService -and $s.Name -ne $OnlyService) { continue }
    $pm  = Join-Path $Workspace "$($s.Name)\docs\postman"
    $col = Get-ChildItem $pm -Filter '*.postman_collection.json'  | Select-Object -First 1
    $envFile = Get-ChildItem $pm -Filter '*.postman_environment.json' | Select-Object -First 1
    if (-not $col -or -not $envFile) { Write-Warning "$($s.Name): no Postman suite found"; continue }

    $exported = Join-Path $report "$($s.Name).env.json"
    $args = @($newman, 'run', $col.FullName, '-e', $envFile.FullName, '--export-environment', $exported,
              '--reporters', 'cli,junit', '--reporter-junit-export', (Join-Path $report "$($s.Name).xml"),
              '--env-var', "base_url=http://localhost:$($s.Port)", '--timeout-request', '20000', '--color', 'off')
    if ($organisationId) { $args += @('--env-var', "organisationId=$organisationId") }

    Write-Host "`n=== $($s.Name) ===" -ForegroundColor Cyan
    & $node @args | Tee-Object -FilePath (Join-Path $report "$($s.Name).txt") | Select-Object -Last 22
    $code = $LASTEXITCODE
    $summary += [pscustomobject]@{ Service = $s.Name; ExitCode = $code }

    # The company suite creates the Organisation (tenant) the other suites need.
    if ($s.Name -like '*party-reference-data-directory*' -and (Test-Path $exported)) {
        $vars = (Get-Content $exported -Raw | ConvertFrom-Json).values
        $organisationId = ($vars | Where-Object key -eq 'organisationId' | Select-Object -First 1).value
        Write-Host "organisationId for downstream suites: $organisationId"
    }
}

Write-Host "`n==== E2E summary ====" -ForegroundColor Cyan
$summary | Format-Table -AutoSize | Out-String | Write-Host
if (@($summary | Where-Object ExitCode -ne 0).Count -gt 0) { exit 1 }
