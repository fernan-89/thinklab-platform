# Shared definitions for the local (no-Docker) ThinkLab stack. Dot-source this file.
$script:Workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:Tools     = Join-Path $script:Workspace 'tools'
$script:RunDir    = Join-Path $script:Workspace 'thinklab-platform\.e2e'

# Order matters for the E2E run: the Party Reference Data Directory produces the organisationId
# that every other suite consumes as its tenant.
$script:Services = @(
    [pscustomobject]@{ Name = 'micronaut-hash-token-registry-service';            Port = 8080; Db = 'thinklab_hash_db' },
    [pscustomobject]@{ Name = 'micronaut-party-reference-data-directory-service'; Port = 8081; Db = 'thinklab_company_db' },
    [pscustomobject]@{ Name = 'micronaut-party-authentication-service';           Port = 8082; Db = 'thinklab_party_authentication_db' },
    [pscustomobject]@{ Name = 'micronaut-it-asset-registry-service';              Port = 8083; Db = 'thinklab_asset_db' },
    [pscustomobject]@{ Name = 'micronaut-it-operation-window-service';            Port = 8084; Db = 'thinklab_operation_db' },
    # No MongoDB of its own (stateless proxy); listed last so its own readiness (which depends on
    # party-authentication's liveness via warmup.endpoints) has something to actually wait on.
    [pscustomobject]@{ Name = 'micronaut-platform-gateway-service';                Port = 8088; Db = $null },
    # Consumes party-authentication's user.initiated event (thinklab-service-kit ADR-003), so it comes
    # after it; also has nothing to wait on before NATS itself is up.
    [pscustomobject]@{ Name = 'micronaut-notification-dispatch-service';           Port = 8089; Db = 'thinklab_notification_db' }
)

function Get-Java21 {
    $candidates = Get-ChildItem "$env:USERPROFILE\.jdks" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '21' } | Sort-Object Name -Descending
    foreach ($c in $candidates) { $j = Join-Path $c.FullName 'bin\java.exe'; if (Test-Path $j) { return $j } }
    if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) { return "$env:JAVA_HOME\bin\java.exe" }
    throw 'No JDK 21 found (looked in ~/.jdks and JAVA_HOME).'
}

function Wait-Http($url, $timeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { return $true } } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}
