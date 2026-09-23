<#
.SYNOPSIS
  Starts MongoDB (portable) and the five ThinkLab services locally, without Docker.
.DESCRIPTION
  Expects `gradlew installDist` to have been run in every service (use -Build to do it here) and the
  portable MongoDB under <workspace>\tools\mongodb. Logs and PIDs go to thinklab-platform\.e2e.
#>
param([switch]$Build)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $RunDir, "$Tools\data\db" | Out-Null
$java = Get-Java21
$pids = @{}

if (-not (Get-Process mongod -ErrorAction SilentlyContinue)) {
    Write-Host 'Starting MongoDB...'
    $m = Start-Process "$Tools\mongodb\bin\mongod.exe" -ArgumentList '--dbpath', "$Tools\data\db", '--port', '27017', '--bind_ip', '127.0.0.1' `
        -RedirectStandardOutput "$RunDir\mongod.out" -RedirectStandardError "$RunDir\mongod.err" -WindowStyle Hidden -PassThru
    $pids['mongod'] = $m.Id
    Start-Sleep -Seconds 4
}

foreach ($s in $Services) {
    $dir = Join-Path $Workspace $s.Name
    if ($Build) { Push-Location $dir; & .\gradlew.bat installDist --console=plain -q; Pop-Location }
    $lib = Join-Path $dir "build\install\$($s.Name)\lib\*"
    $env:MICRONAUT_SERVER_PORT = "$($s.Port)"
    if ($s.Db) { $env:MONGODB_URI = "mongodb://localhost:27017/$($s.Db)" } else { Remove-Item Env:\MONGODB_URI -ErrorAction SilentlyContinue }
    $env:HASH_SERVICE_URL      = 'http://localhost:8080'
    # Security (THINKLAB_SECURITY_ENABLED / THINKLAB_JWT_PRIVATE_KEY / THINKLAB_BOOTSTRAP_SECRET / THINKLAB_CLIENT_SECRET)
    # is left to the caller: every service works with it unset (party-authentication then signs with an
    # ephemeral key, valid only for this run). See secured-smoke.ps1 for a secured run.
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
