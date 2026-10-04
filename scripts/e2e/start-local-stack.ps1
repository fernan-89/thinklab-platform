<#
.SYNOPSIS
  Starts MongoDB, NATS JetStream (both portable) and every ThinkLab service locally, without Docker.
.DESCRIPTION
  Expects `gradlew installDist` to have been run in every service (use -Build to do it here) and the
  portable MongoDB under <workspace>\tools\mongodb and NATS under <workspace>\tools\nats. Logs and PIDs
  go to thinklab-platform\.e2e.
#>
param([switch]$Build)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $RunDir, "$Tools\data\db", "$Tools\data\nats" | Out-Null
$java = Get-Java21
$pids = @{}

if (-not (Get-Process mongod -ErrorAction SilentlyContinue)) {
    Write-Host 'Starting MongoDB...'
    # --replSet, even with a single node, is what unlocks multi-document ACID transactions (kit
    # ADR-003's outbox is otherwise "best effort"). A single-node set does not auto-elect a PRIMARY on
    # its own (confirmed live: mongod 8.0 sits in "no primary" indefinitely) - rs.initiate() below is
    # required exactly once per dbpath.
    $m = Start-Process "$Tools\mongodb\bin\mongod.exe" -ArgumentList '--replSet', $MongoReplSetName, '--dbpath', "$Tools\data\db", '--port', '27017', '--bind_ip', '127.0.0.1' `
        -RedirectStandardOutput "$RunDir\mongod.out" -RedirectStandardError "$RunDir\mongod.err" -WindowStyle Hidden -PassThru
    $pids['mongod'] = $m.Id
    Start-Sleep -Seconds 4
}

# Idempotent: a dbpath already initiated (any run after the first) has its replica set config persisted
# in the local database, so rs.status() succeeds and initiate is skipped rather than failing with
# AlreadyInitialized.
Write-Host 'Ensuring MongoDB replica set is initiated...'
$rsInitScript = @'
try {
  rs.status();
  print('rs-already-initiated');
} catch (e) {
  rs.initiate();
  print('rs-initiated');
}
'@
& "$Tools\mongosh\bin\mongosh.exe" --port 27017 --quiet --eval $rsInitScript | Write-Host

$rsReady = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    $isPrimary = & "$Tools\mongosh\bin\mongosh.exe" --port 27017 --quiet --eval 'print(db.hello().isWritablePrimary)' 2>$null
    if ($isPrimary -match 'true') { $rsReady = $true; break }
    Start-Sleep -Seconds 1
}
if (-not $rsReady) { throw 'MongoDB replica set did not reach PRIMARY within 30s.' }
Write-Host 'MongoDB replica set is PRIMARY.'

# Started unconditionally, like mongod: cheap, and harmless when no service has THINKLAB_EVENTS_ENABLED
# set (the kit's NATS beans stay dormant behind @Requires). See events-smoke.ps1 for a run that uses it.
if (-not (Get-Process nats-server -ErrorAction SilentlyContinue)) {
    Write-Host 'Starting NATS JetStream...'
    $n = Start-Process "$Tools\nats\nats-server.exe" -ArgumentList '-js', '-p', '4222', '-sd', "$Tools\data\nats" `
        -RedirectStandardOutput "$RunDir\nats.out" -RedirectStandardError "$RunDir\nats.err" -WindowStyle Hidden -PassThru
    $pids['nats-server'] = $n.Id
    Start-Sleep -Seconds 2
}

# Captured once, before the loop starts overwriting $env:THINKLAB_EVENTS_ENABLED per service.
$callerEventsEnabled = $env:THINKLAB_EVENTS_ENABLED
$callerEventsNatsUrl = $env:THINKLAB_EVENTS_NATS_URL
# The gateway records every mutating request on the compliance ledger (only it reads this; opt-in, fail-open).
$env:GATEWAY_AUDIT_ENABLED = 'true'
# The investigation pseudonym lookup (gateway ADR-027), switched on so the investigation smoke can run.
$env:GATEWAY_INVESTIGATION_ENABLED = 'true'
# Development-only key (ledger ADR-033): pseudonyms in a local run are not meant to be protected, only to exercise the code path.
$env:GATEWAY_AUDIT_PSEUDONYM_KEY = 'local-dev-only-pseudonym-key'
# Chain-head anchoring (ledger ADR-034): development-only key and directory; only the ledger reads these.
$env:LEDGER_ANCHOR_ENABLED = 'true'
$env:LEDGER_ANCHOR_KEY = 'local-dev-only-anchor-key'
$env:LEDGER_ANCHOR_DIRECTORY = (Join-Path $RunDir 'anchors')
# Federated sign-in (identity-federation, gateway ADR-025): the refresh cookie must work over plain http locally, and the federation
# service resolves the client secret named by a provider from the environment. THINKLAB_MOCK_OIDC_SECRET is the secret of the OIDC
# provider double the federation smoke starts (scripts/e2e/mock-oidc-provider.mjs) - a development value, not a real secret.
$env:GATEWAY_SESSION_COOKIE_SECURE = 'false'
$env:THINKLAB_MOCK_OIDC_SECRET = 'mock-client-secret'

foreach ($s in $Services) {
    $dir = Join-Path $Workspace $s.Name
    if ($Build) {
        Push-Location $dir
        & .\gradlew.bat installDist --console=plain -q
        $buildExitCode = $LASTEXITCODE
        Pop-Location
        # Found live: a silent installDist failure (no exit-code check here previously) left the java
        # Start-Process below launching against an empty build\install\...\lib\ folder, crashing instantly
        # with "Could not find or load main class" - the one failed service never showed up as a build
        # error, only as a mysteriously-dead port once the readiness loop timed out on it.
        if ($buildExitCode -ne 0) { throw "installDist failed for $($s.Name) (exit $buildExitCode)." }
    }
    $lib = Join-Path $dir "build\install\$($s.Name)\lib\*"
    $env:MICRONAUT_SERVER_PORT = "$($s.Port)"
    if ($s.Db) { $env:MONGODB_URI = "mongodb://localhost:27017/$($s.Db)?replicaSet=$MongoReplSetName" } else { Remove-Item Env:\MONGODB_URI -ErrorAction SilentlyContinue }
    $env:HASH_SERVICE_URL      = 'http://localhost:8080'
    # Security (THINKLAB_SECURITY_ENABLED / THINKLAB_JWT_PRIVATE_KEY / THINKLAB_BOOTSTRAP_SECRET / THINKLAB_CLIENT_SECRET)
    # is left to the caller: every service works with it unset (party-authentication then signs with an
    # ephemeral key, valid only for this run). See secured-smoke.ps1 for a secured run.
    # Events, unlike security, must NOT reach every service: only the services with io.nats:jnats on
    # their runtime classpath (kit ADR-003) - see $Services' Events flag in Common.ps1. Forcing it off
    # elsewhere, even if the caller set it, is what keeps a plain -Build run (and a mixed one, like
    # events-smoke.ps1) from crashing the other services' OutboxRelay on a missing EventPublisher bean.
    if ($s.Events -and $callerEventsEnabled) {
        $env:THINKLAB_EVENTS_ENABLED = $callerEventsEnabled
        if ($callerEventsNatsUrl) { $env:THINKLAB_EVENTS_NATS_URL = $callerEventsNatsUrl } else { Remove-Item Env:\THINKLAB_EVENTS_NATS_URL -ErrorAction SilentlyContinue }
    } else {
        $env:THINKLAB_EVENTS_ENABLED = 'false'
        Remove-Item Env:\THINKLAB_EVENTS_NATS_URL -ErrorAction SilentlyContinue
    }
    # it-change-management (GMUD) needs a real CAB/ECAB ApprovalPolicy id at JVM startup
    # (thinklab.change-management.cab-policy-id/ecab-policy-id, ADR-031 of that service) - there is no
    # runtime API to change it after the process is up. workflow-approval-service is already running by
    # this point in $Services (listed right before GMUD), so provision both policies against it here,
    # once, and thread the ids in as env vars for GMUD's own Start-Process below. The policy's own
    # organisationId is arbitrary - workflow-approval-service resolves a policy by id alone, never
    # scoped by tenant (see InitiateApprovalRequestUseCase), so any fixed placeholder tenant works.
    if ($s.Name -eq 'micronaut-it-change-management-service') {
        # workflow-approval-service was only just Start-Process'd in the previous loop iteration -
        # its JVM boot is not synchronous with that call returning, so calling its API immediately
        # races it (found live: Invoke-RestMethod hit connection-refused, and since this script runs
        # under $ErrorActionPreference = 'Stop' that aborted the whole run before GMUD's own
        # Start-Process below was ever reached, even though every other service still started fine).
        if (-not (Wait-Http 'http://localhost:8090/health/readiness' 120)) {
            throw 'workflow-approval-service did not become ready in time; cannot provision CAB/ECAB policies for GMUD.'
        }
        Write-Host 'Provisioning CAB/ECAB ApprovalPolicy records on workflow-approval-service...'
        $policyTenant = [guid]::NewGuid().ToString()
        $cabApprovers = @([guid]::NewGuid().ToString(), [guid]::NewGuid().ToString(), [guid]::NewGuid().ToString())
        $ecabApprovers = @([guid]::NewGuid().ToString(), [guid]::NewGuid().ToString())
        $cabPolicy = Invoke-RestMethod -Method Post -Uri 'http://localhost:8090/workflow-approval/v1/policy/initiate' `
            -Headers @{ 'X-Tenant-Id' = $policyTenant } -ContentType 'application/json' `
            -Body (@{ name = 'CAB'; requiredApprovals = 2; eligibleApproverIds = $cabApprovers } | ConvertTo-Json)
        $ecabPolicy = Invoke-RestMethod -Method Post -Uri 'http://localhost:8090/workflow-approval/v1/policy/initiate' `
            -Headers @{ 'X-Tenant-Id' = $policyTenant } -ContentType 'application/json' `
            -Body (@{ name = 'ECAB'; requiredApprovals = 1; eligibleApproverIds = $ecabApprovers } | ConvertTo-Json)
        $env:THINKLAB_CAB_POLICY_ID = $cabPolicy.id
        $env:THINKLAB_ECAB_POLICY_ID = $ecabPolicy.id
        # Handed to change-management-smoke.ps1 via the run directory, since env vars set in this
        # process are not visible to a script invoked afterwards in a new PowerShell session.
        [pscustomobject]@{
            cabPolicyId = $cabPolicy.id; cabApproverIds = $cabApprovers
            ecabPolicyId = $ecabPolicy.id; ecabApproverIds = $ecabApprovers
        } | ConvertTo-Json | Set-Content "$RunDir\change-management-policies.json"
        Write-Host "  CAB policy [$($cabPolicy.id)] ECAB policy [$($ecabPolicy.id)]"
    }
    Write-Host "Starting $($s.Name) on :$($s.Port)..."
    $p = Start-Process $java -ArgumentList '-cp', "`"$lib`"", 'com.thinklab.Application' `
        -RedirectStandardOutput "$RunDir\$($s.Name).log" -RedirectStandardError "$RunDir\$($s.Name).err" -WindowStyle Hidden -PassThru
    $pids[$s.Name] = $p.Id
}
$pids | ConvertTo-Json | Set-Content "$RunDir\pids.json"

$failed = @()
foreach ($s in $Services) {
    $ok = Wait-Http "http://localhost:$($s.Port)/health/readiness" 150
    Write-Host ("{0,-55} {1}" -f $s.Name, $(if ($ok) { 'READY' } else { 'NOT READY' }))
    if (-not $ok) { $failed += $s.Name }
}
if ($failed) { Write-Host "Services not ready: $($failed -join ', '). See $RunDir\*.log / *.err" -ForegroundColor Red; exit 1 }
Write-Host 'Stack is up.' -ForegroundColor Green
