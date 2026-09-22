<#
.SYNOPSIS
  Live proof of the platform security (Journey 3) against a stack started with THINKLAB_SECURITY_ENABLED=true.

.DESCRIPTION
  Start the stack first with the same secret:
    $env:THINKLAB_SECURITY_ENABLED='true'; $env:THINKLAB_JWT_SECRET='<32+ bytes>'
    .\start-local-stack.ps1
  then run this script with the same secret. It mints a bootstrap SERVICE token (out of band, as an operator would),
  creates an organisation and an ADMIN user, sets a password, logs in and exercises RBAC and tenant isolation.
#>
param([string]$Secret = 'e2e-secret-e2e-secret-e2e-secret-32b')

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function ConvertTo-Base64Url([byte[]]$bytes) { [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function New-Token([string]$Subject, [string]$Tenant, [string]$Role, [int]$TtlSeconds = 600) {
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"HS256"}'))
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $claims = '{"sub":"' + $Subject + '","iss":"thinklab","iat":' + $now + ',"exp":' + ($now + $TtlSeconds) + ',"tid":"' + $Tenant + '","role":"' + $Role + '"}'
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($claims))
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, [Text.Encoding]::UTF8.GetBytes($Secret))
    $sig = ConvertTo-Base64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$header.$payload")))
    "$header.$payload.$sig"
}

function Invoke-Api([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null) {
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true; ContentType = 'application/json' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5) }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null } }
    } catch {
        $resp = $_.Exception.Response
        $text = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $text = $_.ErrorDetails.Message }
        elseif ($resp) { $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { $text | ConvertFrom-Json } else { $null } }
    }
}

function Assert-Status([string]$Name, $Response, [int]$Expected) {
    $ok = ($Response.Status -eq $Expected)
    if (-not $ok -and $Response.Body) { Write-Output ('  ' + $Name + ' -> ' + ($Response.Body | ConvertTo-Json -Compress -Depth 4)) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Response.Status; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$auth = 'http://localhost:8082/party-authentication/v1'
$org = 'http://localhost:8081/party-reference-data-directory/v1'
$asset = 'http://localhost:8083/it-asset-registry/v1'
$bootstrap = @{ Authorization = 'Bearer ' + (New-Token 'bootstrap-operator' 'platform' 'SERVICE') }

# 1. Unauthenticated access is rejected everywhere, but health stays public.
Assert-Status 'no token -> 401 (organisations)' (Invoke-Api GET "$org/retrieve") 401
Assert-Status 'forged token -> 401' (Invoke-Api GET "$org/retrieve" @{ Authorization = 'Bearer abc.def.ghi' }) 401
Assert-Status 'health is public' (Invoke-Api GET 'http://localhost:8082/health/liveness') 200

# 2. Bootstrap: organisation, ADMIN user, activation, password.
$created = Invoke-Api POST "$org/initiate" ($bootstrap + @{ 'X-Executor' = 'bootstrap' }) @{ corporateName = 'Secure Corp'; tradeName = 'Secure'; billing = @{ billingEmail = 'b@secure.example'; currency = 'USD'; taxRegime = 'SIMPLES' }; taxIdentifier = ((Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()) }
Assert-Status 'bootstrap organisation created' $created 201
$orgId = $created.Body.id
$tenantHeaders = $bootstrap + @{ 'X-Tenant-Id' = $orgId; 'X-Executor' = 'bootstrap' }
$user = Invoke-Api POST "$auth/initiate" $tenantHeaders @{ fullName = 'Ada Admin'; email = 'ada@secure.example'; role = 'ADMIN' }
Assert-Status 'ADMIN user initiated' $user 201
$userId = $user.Body.id
Assert-Status 'user activated' (Invoke-Api PUT "$auth/$userId/control/activate" $tenantHeaders) 204
Assert-Status 'credential set (service token)' (Invoke-Api PUT "$auth/$userId/credential/update" $tenantHeaders @{ password = 'A-very-long-passphrase-1' }) 204
Assert-Status 'short password rejected' (Invoke-Api PUT "$auth/$userId/credential/update" $tenantHeaders @{ password = 'short' }) 400

# 3. Login: generic failure, then success.
Assert-Status 'wrong password -> 401' (Invoke-Api POST "$auth/session/initiate" @{} @{ organisationId = $orgId; email = 'ada@secure.example'; password = 'not-the-password-1' }) 401
Assert-Status 'unknown user -> 401' (Invoke-Api POST "$auth/session/initiate" @{} @{ organisationId = $orgId; email = 'nobody@secure.example'; password = 'A-very-long-passphrase-1' }) 401
$session = Invoke-Api POST "$auth/session/initiate" @{} @{ organisationId = $orgId; email = 'ada@secure.example'; password = 'A-very-long-passphrase-1' }
Assert-Status 'login succeeds' $session 200
$admin = @{ Authorization = 'Bearer ' + $session.Body.accessToken }

# 4. The admin token drives the other services; tenant and executor come from the token.
Assert-Status 'admin can list assets (no headers needed)' (Invoke-Api GET "$asset/retrieve" $admin) 200
Assert-Status 'a conflicting tenant header -> 403' (Invoke-Api GET "$asset/retrieve" ($admin + @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString() })) 403
$assetCreated = Invoke-Api POST "$asset/initiate" $admin @{ name = 'srv-01'; category = 'SERVER'; serialNumber = ('SN-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
Assert-Status 'admin creates an asset (service-to-service hash call works)' $assetCreated 201

# 5. RBAC: a VIEWER token can read but not write; an OPERATOR cannot delete-class methods.
$viewer = @{ Authorization = 'Bearer ' + (New-Token 'viewer-1' $orgId 'VIEWER') }
Assert-Status 'viewer can read' (Invoke-Api GET "$asset/retrieve" $viewer) 200
Assert-Status 'viewer cannot write -> 403' (Invoke-Api POST "$asset/initiate" $viewer @{ name = 'x'; category = 'SERVER'; serialNumber = 'SN-VIEW' }) 403

# 6. Password changes are restricted to admins and the user themselves.
$operator = @{ Authorization = 'Bearer ' + (New-Token 'operator-1' $orgId 'OPERATOR') }
Assert-Status 'operator cannot reset another user password -> 403' (Invoke-Api PUT "$auth/$userId/credential/update" $operator @{ password = 'Another-long-passphrase-2' }) 403

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Secured smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
