<#
.SYNOPSIS
  Provisions the CAB/ECAB and purchase-order approval policies against a running workflow-approval-service (PowerShell counterpart of provision-change-management.sh).
.DESCRIPTION
  it-change-management reads thinklab.change-management.cab-policy-id/ecab-policy-id at JVM boot, so under docker compose this takes two phases: start the stack,
  run this script, then recreate only that container so it sees the ids:

    . scripts\stack\provision-change-management.ps1
    docker compose up -d it-change-management

  it-procurement needs no restart: the approval policy of an order is that of its approval band (procurement ADR-036), and the smokes make a band at 0 for their own
  tenant with the purchase-order policy written here.

  Dot-source it (or call it with & in the same session) so the two variables stay set in your session; run in a child process they are only printed.
  Writes .e2e\change-management-policies.json and .e2e\procurement-policy.json (the files change-management-smoke, procurement-smoke and promises-alerting-smoke read)
  and prints THINKLAB_CAB_POLICY_ID and THINKLAB_ECAB_POLICY_ID. Works in Windows PowerShell 5.1 and in PowerShell 7.
#>
param([string]$WorkflowApprovalUrl = 'http://localhost:8090')

$ErrorActionPreference = 'Stop'
$base = "$($WorkflowApprovalUrl.TrimEnd('/'))/workflow-approval/v1"
$platformDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outDir = Join-Path $platformDir '.e2e'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function New-Id { [guid]::NewGuid().ToString() }

$tenant = New-Id
$cabApprovers = 1..3 | ForEach-Object { New-Id }
$ecabApprovers = 1..2 | ForEach-Object { New-Id }
$poApprovers = 1..2 | ForEach-Object { New-Id }

function New-Policy([string]$Name, [int]$Required, [string[]]$Approvers) {
    $body = @{ name = $Name; requiredApprovals = $Required; eligibleApproverIds = @($Approvers) } | ConvertTo-Json -Compress
    (Invoke-RestMethod -Method Post -Uri "$base/policy/initiate" -Headers @{ 'X-Tenant-Id' = $tenant } -ContentType 'application/json' -Body $body).id
}

$cabId = New-Policy 'CAB' 2 $cabApprovers
$ecabId = New-Policy 'ECAB' 1 $ecabApprovers
# The approval policy of the procurement service (purchase orders): one approval of two eligible approvers, on the same tenant (policies belong to a tenant).
$poId = New-Policy 'PURCHASE-ORDER' 1 $poApprovers

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $outDir 'change-management-policies.json'),
    (@{ cabPolicyId = $cabId; cabApproverIds = @($cabApprovers); ecabPolicyId = $ecabId; ecabApproverIds = @($ecabApprovers) } | ConvertTo-Json -Compress), $utf8)
[IO.File]::WriteAllText((Join-Path $outDir 'procurement-policy.json'),
    (@{ tenantId = $tenant; policyId = $poId; approverIds = @($poApprovers) } | ConvertTo-Json -Compress), $utf8)

$env:THINKLAB_CAB_POLICY_ID = $cabId
$env:THINKLAB_ECAB_POLICY_ID = $ecabId

[Console]::Error.WriteLine("CAB policy [$cabId] ECAB policy [$ecabId] purchase-order policy [$poId]")
Write-Output "THINKLAB_CAB_POLICY_ID=$cabId"
Write-Output "THINKLAB_ECAB_POLICY_ID=$ecabId"
