<#
.SYNOPSIS
  The Homelab edition: see edition.ps1, which holds the editions. `homelab.ps1 up|down|footprint|services` is `edition.ps1 homelab ...`.
#>
param([Parameter(Mandatory)][ValidateSet('up', 'down', 'footprint', 'services')][string]$Command)
& (Join-Path $PSScriptRoot 'edition.ps1') -Edition homelab -Command $Command
exit $LASTEXITCODE
