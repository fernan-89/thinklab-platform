<#
.SYNOPSIS
  Provisions the purchase-order approval policy against a running workflow-approval-service (PowerShell counterpart of provision-change-management.sh).
.DESCRIPTION
  Since ADR-039 of it-change-management the CAB and ECAB belong to each tenant, so this no longer provisions them: the smokes that route changes make their own and set them
  with approval-settings/update, and there is no shared pair to put in the environment nor a second boot of change-management.

  it-procurement needs no restart: the approval policy of an order is that of its approval band (procurement ADR-036), and the smokes make a band at 0 for their own
  tenant with the purchase-order policy written here.

  Writes .e2e\procurement-policy.json (the file procurement-smoke and promises-alerting-smoke read). Works in Windows PowerShell 5.1 and in PowerShell 7.
#>
param([string]$WorkflowApprovalUrl = 'http://localhost:8090')

$ErrorActionPreference = 'Stop'
$base = "$($WorkflowApprovalUrl.TrimEnd('/'))/workflow-approval/v1"
$platformDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $platformDir '.e2e'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function New-Id { [guid]::NewGuid().ToString() }

$tenant = New-Id
$poApprovers = 1..2 | ForEach-Object { New-Id }

function New-Policy([string]$Name, [int]$Required, [string[]]$Approvers) {
    $body = @{ name = $Name; requiredApprovals = $Required; eligibleApproverIds = @($Approvers) } | ConvertTo-Json -Compress
    (Invoke-RestMethod -Method Post -Uri "$base/policy/initiate" -Headers @{ 'X-Tenant-Id' = $tenant } -ContentType 'application/json' -Body $body).id
}

# The approval policy of the procurement service (purchase orders): one approval of two eligible approvers, on the same tenant (policies belong to a tenant).
$poId = New-Policy 'PURCHASE-ORDER' 1 $poApprovers

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $outDir 'procurement-policy.json'),
    (@{ tenantId = $tenant; policyId = $poId; approverIds = @($poApprovers) } | ConvertTo-Json -Compress), $utf8)

[Console]::Error.WriteLine("purchase-order policy [$poId]")
