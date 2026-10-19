<#
.SYNOPSIS
  Live proof of the starter pack of alert rules (scripts/stack/seed-starter-pack.ps1) through the platform gateway (PowerShell port of starter-pack-smoke.sh).

.DESCRIPTION
  An edition gets its rules (Homelab 2, Team 4, Enterprise 6), each watching every policy of its source and taking the class of that source; running it
  again creates nothing; moving up an edition adds only what is missing; a rule a person paused stays paused; another tenant has none of it; an unknown
  edition or a missing argument is refused (the PowerShell script refuses them when it binds its parameters, so the exit code is 1, not the 2 of the bash one).

    pwsh -File .\starter-pack-smoke.ps1
#>
param([string]$GatewayUrl = 'http://localhost:8088')

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList
$pack = Join-Path $PSScriptRoot '..\stack\seed-starter-pack.ps1'

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 6 } }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Text = $r.Content; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Text = $text; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$alr = "$GatewayUrl/it-alerting/v1"
$tenantId = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'smoke' }
function Rules { @((Invoke-Api GET "$alr/rule/retrieve" $staff).Body) }
function Sources { (@(Rules) | ForEach-Object { if ($_.source) { $_.source } else { 'HEALTH_CHECK' } } | Sort-Object) -join ',' }
# Runs the pack in its own process, so its exit code and its last line are what a caller sees.
function Pack([string]$Edition, [string]$Tenant = $tenantId) {
    $env:GATEWAY_URL = $GatewayUrl
    $out = & pwsh -NoProfile -NonInteractive -File $pack -Edition $Edition -OrganisationId $Tenant -RequesterId $requester 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Last = (@($out | ForEach-Object { "$_" } | Where-Object { $_ -match ': \d+ created, ' }) | Select-Object -Last 1) }
}

# 1. Homelab.
$run = Pack 'HOMELAB'
Assert-Equal 'Homelab creates two rules (exit 0)' "$($run.Code)/$($run.Last)" '0/HOMELAB: 2 created, 0 already there, 0 failed'
Assert-Equal 'they watch health checks and capacity policies' (Sources) 'CAPACITY,HEALTH_CHECK'
$rules = Rules
Assert-Equal 'every rule is ACTIVE, covers every policy of its source and is filed for the requester' `
    ("{0}/{1}/{2}" -f (@($rules | Where-Object { $_.status -ne 'ACTIVE' }).Count -eq 0), (@($rules | Where-Object { $_.checkId }).Count -eq 0), (@($rules | Where-Object { $_.requesterId -ne $requester }).Count -eq 0)) 'True/True/True'
Assert-Equal 'each takes the class of its source' ((@($rules.alertClass) | Sort-Object) -join ',') 'AVAILABILITY,CAPACITY'
Assert-Equal 'no rule names a webhook' (@($rules | Where-Object { $_.notifyTarget -or $_.escalateTarget }).Count -eq 0) $true

# 2. A person pauses the health-check rule; moving up to Team adds the two missing rules and leaves it paused.
$health = (@($rules | Where-Object { -not $_.source -or $_.source -eq 'HEALTH_CHECK' }) | Select-Object -First 1).id
Assert-Equal 'a person can pause a rule (204)' (Invoke-Api PUT "$alr/rule/$health/control/pause" $staff).Status 204
$run = Pack 'TEAM'
Assert-Equal 'Team keeps the two and adds two' "$($run.Code)/$($run.Last)" '0/TEAM: 2 created, 2 already there, 0 failed'
Assert-Equal 'now backups and patches are watched too' (Sources) 'BACKUP,CAPACITY,HEALTH_CHECK,PATCH'
Assert-Equal 'the rule that was paused is still paused' (Invoke-Api GET "$alr/rule/$health/retrieve" $staff).Body.status 'PAUSED'

# 3. Again: nothing to create.
$run = Pack 'TEAM'
Assert-Equal 'running Team again creates nothing' "$($run.Code)/$($run.Last)" '0/TEAM: 0 created, 4 already there, 0 failed'
Assert-Equal 'still four rules' (Rules).Count 4

# 4. Enterprise.
$run = Pack 'ENTERPRISE'
Assert-Equal 'Enterprise adds the vendor and licence rules' "$($run.Code)/$($run.Last)" '0/ENTERPRISE: 2 created, 4 already there, 0 failed'
Assert-Equal 'six rules, all six sources' (Sources) 'BACKUP,CAPACITY,HEALTH_CHECK,LICENSE,PATCH,VENDOR'
Assert-Equal 'the contract rules are CONTRACT' ((@(Rules | Where-Object { $_.source -in 'VENDOR', 'LICENSE' } | ForEach-Object { $_.alertClass })) -join ',') 'CONTRACT,CONTRACT'

# 5. The tenant, and a wrong call.
Assert-Equal 'another tenant has none of it' @((Invoke-Api GET "$alr/rule/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = 'smoke' }).Body).Count 0
$env:GATEWAY_URL = $GatewayUrl
& pwsh -NoProfile -NonInteractive -File $pack -Edition 'NOPE' -OrganisationId $tenantId -RequesterId $requester *> $null
Assert-Equal 'an unknown edition is refused' ($LASTEXITCODE -ne 0) $true
& pwsh -NoProfile -NonInteractive -File $pack -Edition 'HOMELAB' *> $null
Assert-Equal 'a missing argument is refused' ($LASTEXITCODE -ne 0) $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Starter pack smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
