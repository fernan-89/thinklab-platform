<#
.SYNOPSIS
  Runs `gradlew installDist` in every sibling service repository; docker-compose.yml packages the result.
.DESCRIPTION
  micronaut-thinklab-service-kit comes from GitHub Packages: set GITHUB_ACTOR and GITHUB_TOKEN (a token with
  read:packages), or have the kit in your local Maven repository (`gradlew publishToMavenLocal` in it).
#>
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$repos = @(
    'micronaut-hash-token-registry-service',
    'micronaut-party-reference-data-directory-service',
    'micronaut-party-authentication-service',
    'micronaut-it-asset-registry-service',
    'micronaut-it-operation-window-service',
    'micronaut-it-hardware-maintenance-service',
    'micronaut-site-reference-data-directory-service',
    'micronaut-platform-gateway-service',
    'micronaut-notification-dispatch-service',
    'micronaut-workflow-approval-service',
    'micronaut-it-change-management-service',
    'micronaut-it-discovery-service',
    'micronaut-it-topology-graph-service',
    'micronaut-compliance-audit-ledger-service',
    'micronaut-subscription-billing-service',
    'micronaut-consumable-inventory-service',
    'micronaut-identity-federation-service',
    'micronaut-it-incident-management-service',
    'micronaut-it-service-request-service',
    'micronaut-it-problem-management-service',
    'micronaut-it-knowledge-base-service',
    'micronaut-it-external-ticketing-service',
    'micronaut-it-health-monitoring-service',
    'micronaut-it-alerting-service',
    'micronaut-it-backup-registry-service',
    'micronaut-ci-type-catalog-service'
)
foreach ($repo in $repos) {
    $dir = Join-Path $workspace $repo
    if (-not (Test-Path $dir)) { throw "missing $dir (clone the service repositories next to thinklab-platform)" }
    Write-Host "==> $repo"
    Push-Location $dir
    try {
        & .\gradlew.bat installDist --console=plain -q
        if ($LASTEXITCODE -ne 0) { throw "installDist failed in $repo" }
    } finally { Pop-Location }
}
