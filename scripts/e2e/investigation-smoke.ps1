<#
.SYNOPSIS
  Live proof of the investigation procedure (gateway ADR-027): given the email of a KNOWN person, an administrator finds the
  pseudonym their sign-ins are recorded under and reads the ledger by it - and the lookup itself is on the ledger, with its reason.

.DESCRIPTION
  Needs the stack up with the gateway started with GATEWAY_INVESTIGATION_ENABLED=true and GATEWAY_AUDIT_ENABLED=true
  (start-local-stack.ps1 and docker-compose.yml do that). Creates its own organisation, then:
    (1) a sign-in attempt for an email is recorded on the ledger under a keyed pseudonym (the email itself is not);
    (2) the lookup answers that same pseudonym (stable, whatever the capitals) and how to read the ledger by it;
    (3) reading the ledger by that actor returns the sign-in; another person's pseudonym returns nothing;
    (4) the lookup is on the ledger with its target pseudonym and reason, and neither the email nor the password appears anywhere;
    (5) a short reason, a reason that carries an email, and a missing reason are refused (400).

    powershell -File .\investigation-smoke.ps1
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$LedgerUrl = 'http://localhost:8094'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 6 }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$executor = @{ 'X-Executor' = 'investigation-smoke' }
$taxId = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + '0000000000000').Substring(0, 14)
$org = Invoke-Api POST "$OrgUrl/party-reference-data-directory/v1/initiate" $executor @{ corporateName = 'Investigation Corp'; tradeName = 'INV'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@inv.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Equal 'organisation created' $org.Status 201
$orgId = $org.Body.id
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenant = @{ 'X-Tenant-Id' = $orgId }
$admin = @{ 'X-Tenant-Id' = $orgId; 'X-Executor' = [guid]::NewGuid().ToString() }
$reason = 'Ticket SEC-1234: unusual night access'

# 1. A sign-in attempt for a person we have a name for.
$suspect = "suspect.$([guid]::NewGuid().ToString('N').Substring(0, 8))@example.com"
$password = "Sm0ke-P@ss-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$signIn = Invoke-Api POST "$GatewayUrl/party-authentication/v1/session/initiate" @{} @{ organisationId = $orgId; email = $suspect; password = $password }
Assert-Equal 'a sign-in with unknown credentials is refused (4xx)' ($signIn.Status -ge 400 -and $signIn.Status -lt 500) $true
for ($i = 0; $i -lt 20; $i++) {
    $recorded = @((Invoke-Api GET "$ledger/retrieve?limit=50" $tenant).Body | Where-Object { $_.action -eq 'POST /party-authentication/v1/session/initiate' })
    if ($recorded.Count -gt 0) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the sign-in attempt was recorded under a pseudonym' ($recorded.Count -eq 1 -and $recorded[0].actor -match '^login:[0-9a-f]{32}$') $true

# 2. The lookup.
$lookup = Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = $suspect; reason = $reason }
Assert-Equal 'the lookup answers (200)' $lookup.Status 200
Assert-Equal 'it answers the pseudonym the sign-in was recorded under' $lookup.Body.actor $recorded[0].actor
Assert-Equal 'it says how to read the ledger by it' $lookup.Body.ledgerQuery "/compliance-audit-ledger/v1/retrieve?actor=$($lookup.Body.actor)"
Assert-Equal 'it says the lookup was recorded' $lookup.Body.recorded $true
$upper = Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = $suspect.ToUpper(); reason = $reason }
Assert-Equal 'the pseudonym is stable whatever the capitals' $upper.Body.actor $lookup.Body.actor

# 3. Reading the ledger by that actor.
$byActor = @((Invoke-Api GET "$ledger/retrieve?actor=$([uri]::EscapeDataString($lookup.Body.actor))&limit=50" $tenant).Body)
Assert-Equal 'the ledger read by that actor returns the sign-in' (@($byActor | Where-Object { $_.action -eq 'POST /party-authentication/v1/session/initiate' }).Count) 1
$other = Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = "nobody.$([guid]::NewGuid().ToString('N').Substring(0, 8))@example.com"; reason = $reason }
Assert-Equal 'another person has another pseudonym' ($other.Body.actor -ne $lookup.Body.actor) $true
Assert-Equal 'and nothing on the ledger' @((Invoke-Api GET "$ledger/retrieve?actor=$([uri]::EscapeDataString($other.Body.actor))&limit=50" $tenant).Body).Count 0

# 4. The lookup itself is on the ledger, with its reason, and no personal data anywhere.
$byAdmin = @((Invoke-Api GET "$ledger/retrieve?actor=$($admin.'X-Executor')&limit=50" $tenant).Body | Where-Object { $_.action -eq 'POST /gateway/v1/investigation/pseudonym' })
Assert-Equal 'every lookup is recorded against the administrator (three so far)' $byAdmin.Count 3
$mine = @($byAdmin | Where-Object { $_.detail -like "*target=$($lookup.Body.actor);*" })
Assert-Equal 'the record names the target pseudonym and the reason' ($mine.Count -ge 1 -and $mine[0].detail -like "*reason=$reason") $true
$dump = (Invoke-Api GET "$ledger/retrieve?limit=500" $tenant).Body | ConvertTo-Json -Depth 6
Assert-Equal 'the email appears nowhere on the ledger' $dump.ToLower().Contains($suspect.ToLower().Split('@')[0]) $false
Assert-Equal 'the password appears nowhere on the ledger' $dump.Contains($password) $false

# 5. What is refused.
Assert-Equal 'a short reason is refused (400)' (Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = $suspect; reason = 'because' }).Status 400
Assert-Equal 'a reason that carries an email is refused (400)' (Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = $suspect; reason = 'Because bob@example.com did it' }).Status 400
Assert-Equal 'a missing reason is refused (400)' (Invoke-Api POST "$GatewayUrl/gateway/v1/investigation/pseudonym" $admin @{ email = $suspect }).Status 400
Assert-Equal 'refused lookups are not recorded as lookups (still three)' (@((Invoke-Api GET "$ledger/retrieve?actor=$($admin.'X-Executor')&limit=50" $tenant).Body | Where-Object { $_.action -eq 'POST /gateway/v1/investigation/pseudonym' }).Count) 3

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Investigation smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
