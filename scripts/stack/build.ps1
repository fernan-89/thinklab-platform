<#
.SYNOPSIS
  Runs `gradlew installDist` in every sibling service repository; docker-compose.yml packages the result.
.DESCRIPTION
  thinklab-service-kit comes from GitHub Packages: set GITHUB_ACTOR and GITHUB_TOKEN (a token with
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
    'micronaut-platform-gateway-service',
    'micronaut-notification-dispatch-service'
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
