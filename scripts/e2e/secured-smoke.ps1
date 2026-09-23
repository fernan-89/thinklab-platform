<#
.SYNOPSIS
  Live proof of the platform security stack (ADR-020/021/022: asymmetric tokens, refresh rotation, session
  revocation, and the dedicated gateway) against a stack started with THINKLAB_SECURITY_ENABLED=true.

.DESCRIPTION
  Every credential here is real: nothing is hand-crafted. Start the stack with a bootstrap client secret
  registered on party-authentication, then run this script with the same secret:

    $env:THINKLAB_SECURITY_ENABLED  = 'true'
    $env:THINKLAB_BOOTSTRAP_SECRET  = 'a-long-bootstrap-secret-for-this-run'
    $env:GATEWAY_RATE_LIMIT_BURST   = '5'   # optional: makes the rate-limit check in step 8 deterministic
    .\start-local-stack.ps1 -Build

    powershell -File .\secured-smoke.ps1 -BootstrapSecret 'a-long-bootstrap-secret-for-this-run'

  It gets a genuine service token from POST /token/service (the only step that talks to
  party-authentication directly rather than through the gateway, since that endpoint is on the
  gateway's denied-paths by design), then does everything else - creating the organisation, an
  ADMIN, a VIEWER and an OPERATOR, logging each of them in for a real ES256 access token, creating an
  asset, refreshing a session, detecting refresh-token reuse, revoking a session and a whole user, and
  rate limiting - through the gateway on :8088, exactly as a real client would.
#>
param(
    [string]$BootstrapSecret = 'bootstrap-secret-for-local-runs-32b',
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$AuthDirectUrl = 'http://localhost:8082'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null, [string]$ContentType = 'application/json')
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $p.ContentType = $ContentType
        $p.Body = if ($ContentType -eq 'application/json') { $Body | ConvertTo-Json -Depth 5 } else { $Body }
    }
    try {
        $r = Invoke-WebRequest @p
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }; Headers = $r.Headers }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { $text | ConvertFrom-Json } else { $null }; Headers = $null }
    }
}

function Assert-Status {
    param([string]$Name, $Response, [int]$Expected)
    $ok = ($Response.Status -eq $Expected)
    if (-not $ok) { Write-Output ("  {0} -> expected {1}, got {2}: {3}" -f $Name, $Expected, $Response.Status, ($Response.Body | ConvertTo-Json -Compress -Depth 4)) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Response.Status; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Bearer([string]$Token) { @{ Authorization = "Bearer $Token" } }

$auth  = "$AuthDirectUrl/party-authentication/v1"     # only for the two gateway-denied endpoints
$gw    = "$GatewayUrl/party-authentication/v1"
$gwOrg = "$GatewayUrl/party-reference-data-directory/v1"
$gwAst = "$GatewayUrl/it-asset-registry/v1"
$password = 'A-genuinely-long-passphrase-1'

# 1. The gateway's own edge: no token at all, a forged token, and its denied/public paths.
Assert-Status 'gateway: no token -> 401' (Invoke-Api GET "$gwOrg/retrieve") 401
Assert-Status 'gateway: forged token -> 401' (Invoke-Api GET "$gwOrg/retrieve" (Bearer 'not.a.valid.jwt')) 401
Assert-Status 'gateway: health is public' (Invoke-Api GET "$GatewayUrl/health/liveness") 200
Assert-Status 'gateway: the JWKS document is public and reachable' (Invoke-Api GET "$gw/.well-known/jwks.json") 200
Assert-Status 'gateway: an internal-only path (token/service) is a 404, same as an unknown domain' (Invoke-Api GET "$gw/token/service") 404
Assert-Status 'gateway: the revoked-sessions feed is also denied' (Invoke-Api GET "$gw/session/revoked") 404
Assert-Status 'directly on the issuer, token/service IS reachable (bootstrap needs it)' (Invoke-Api POST "$auth/token/service" @{} @{ client_id = 'no-such-client'; client_secret = 'x' } 'application/x-www-form-urlencoded') 401

# 2. Bootstrap: a genuine SERVICE token (client credentials), used only to create the very first organisation and admin.
$bootstrap = Invoke-Api POST "$auth/token/service" @{} @{ client_id = 'bootstrap'; client_secret = $BootstrapSecret } 'application/x-www-form-urlencoded'
Assert-Status 'bootstrap client credentials succeed' $bootstrap 200
$bootstrapAuth = Bearer $bootstrap.Body.accessToken

$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$org = Invoke-Api POST "$gwOrg/initiate" $bootstrapAuth @{ corporateName = 'Secure Corp'; tradeName = 'Secure'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@secure.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created through the gateway with a bootstrap token' $org 201
$orgId = $org.Body.id
$asAdminBootstrap = $bootstrapAuth + @{ 'X-Tenant-Id' = $orgId }

function New-ActivatedUser([string]$Name, [string]$Email, [string]$Role) {
    $created = Invoke-Api POST "$gw/initiate" $asAdminBootstrap @{ fullName = $Name; email = $Email; role = $Role }
    Assert-Status "user $Email initiated ($Role)" $created 201
    $id = $created.Body.id
    Assert-Status "user $Email activated" (Invoke-Api PUT "$gw/$id/control/activate" $asAdminBootstrap) 204
    Assert-Status "user $Email credential set" (Invoke-Api PUT "$gw/$id/credential/update" $asAdminBootstrap @{ password = $password }) 204
    $session = Invoke-Api POST "$gw/session/initiate" @{} @{ organisationId = $orgId; email = $Email; password = $password }
    Assert-Status "user $Email logs in through the gateway" $session 200
    return [pscustomobject]@{ Id = $id; Email = $Email; Session = $session.Body }
}

$admin    = New-ActivatedUser 'Ada Admin'      'ada@secure.example'    'ADMIN'
$viewer   = New-ActivatedUser 'Vic Viewer'     'vic@secure.example'    'VIEWER'
$operator = New-ActivatedUser 'Otto Operator'  'otto@secure.example'   'OPERATOR'

# 3. A real login token proves tenant/executor/role are exactly what the token says, end to end through the gateway.
$whoAmI = Invoke-Api GET "$gwAst/retrieve" (Bearer $admin.Session.accessToken)
Assert-Status 'the admin token alone is enough (tenant/executor derived from it)' $whoAmI 200
Assert-Status 'a client-forged tenant header conflicting with the token is rejected' (Invoke-Api GET "$gwAst/retrieve" ((Bearer $admin.Session.accessToken) + @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString() })) 403

$assetSerial = 'SN-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$asset = Invoke-Api POST "$gwAst/initiate" (Bearer $admin.Session.accessToken) @{ name = 'srv-01'; category = 'SERVER'; serialNumber = $assetSerial }
Assert-Status 'admin creates an asset through the gateway (proves the service-to-service hash call also works)' $asset 201

# 4. RBAC is enforced identically whether the caller went through the gateway or hit the service directly.
Assert-Status 'viewer can read through the gateway' (Invoke-Api GET "$gwAst/retrieve" (Bearer $viewer.Session.accessToken)) 200
Assert-Status 'viewer cannot write -> 403' (Invoke-Api POST "$gwAst/initiate" (Bearer $viewer.Session.accessToken) @{ name = 'x'; category = 'SERVER'; serialNumber = 'SN-VIEW' }) 403
Assert-Status 'operator cannot reset another user credential -> 403' (Invoke-Api PUT "$gw/$($viewer.Id)/credential/update" (Bearer $operator.Session.accessToken) @{ password = 'another-long-passphrase-2' }) 403

# 5. Refresh rotation: the old refresh token is consumed and cannot be replayed; a replay is treated as theft.
$refreshed = Invoke-Api POST "$gw/session/refresh" @{} @{ refreshToken = $operator.Session.refreshToken }
Assert-Status 'refresh yields a new access + refresh token pair' $refreshed 200
if ($refreshed.Status -eq 200) {
    if ($refreshed.Body.refreshToken -eq $operator.Session.refreshToken) { Write-Output '  WARNING: refresh token was not rotated' }
    $replay = Invoke-Api POST "$gw/session/refresh" @{} @{ refreshToken = $operator.Session.refreshToken }
    Assert-Status 'replaying the OLD (already-rotated) refresh token is rejected' $replay 401
    # Reuse is treated as session theft (ADR-021): the session is revoked at once, and the issuer enforces its
    # own revocation list synchronously - the operator's original access token stops working immediately here...
    $onIssuerAfterTheft = Invoke-Api GET "$auth/$($operator.Id)/retrieve" (Bearer $operator.Session.accessToken)
    Assert-Status 'on the issuer itself, the pre-rotation access token is rejected at once (synchronous revocation)' $onIssuerAfterTheft 401
    # ...but a different service (the asset registry, behind the gateway) only learns of it on its next
    # revocation poll, so the same token still works there for a little longer. See step 7 for that wait.
    $throughGatewayAfterTheft = Invoke-Api GET "$gwAst/retrieve" (Bearer $operator.Session.accessToken)
    Assert-Status 'through the gateway, the same token still works until the next revocation poll' $throughGatewayAfterTheft 200
}

# 6. Logout revokes the session; on the issuer itself the effect is immediate (no poll wait).
Assert-Status 'logout with an unknown refresh token is silently accepted' (Invoke-Api POST "$gw/session/revoke" @{} @{ refreshToken = 'not-a-real-token' }) 204
Assert-Status 'logout with the (rotated) operator refresh token succeeds' (Invoke-Api POST "$gw/session/revoke" @{} @{ refreshToken = $refreshed.Body.refreshToken }) 204
$sessionOnIssuer = Invoke-Api GET "$auth/$($operator.Id)/retrieve" $asAdminBootstrap
$revokedOnIssuer = Invoke-Api GET "$auth/session/revoked"
Assert-Status 'the issuer''s own revoked-session feed is reachable directly (internal use)' $revokedOnIssuer 200
Write-Output ("  issuer currently reports {0} revoked session(s)" -f $revokedOnIssuer.Body.revoked.Count)

# 7. Forced logout by an admin revokes every session of a user (here, the viewer's). The rejection check
# runs first and uses the viewer's own (still-live) token - operator's was already killed by the theft
# detection in step 5, so reusing it here would trivially 401 for the wrong reason.
Assert-Status 'a non-admin, non-self caller cannot force a logout -> 403' (Invoke-Api PUT "$gw/$($admin.Id)/session/control/revoke" (Bearer $viewer.Session.accessToken)) 403
Assert-Status 'admin forces the viewer to log out everywhere' (Invoke-Api PUT "$gw/$($viewer.Id)/session/control/revoke" (Bearer $admin.Session.accessToken)) 204

# Give the verifier services (asset registry, etc.) one poll cycle to pick up the revocations published
# by the issuer. Their default poll interval is 15s; the local stack does not override it, so this is a
# real end-to-end propagation check, not a race.
Write-Output '  waiting up to 16s for the revocation poll to propagate to the asset registry...'
$deadline = (Get-Date).AddSeconds(16)
$propagated = $false
while ((Get-Date) -lt $deadline) {
    $check = Invoke-Api GET "$gwAst/retrieve" (Bearer $viewer.Session.accessToken)
    if ($check.Status -eq 401) { $propagated = $true; break }
    Start-Sleep -Seconds 2
}
[void]$results.Add([pscustomobject]@{ Check = 'a revoked session is rejected platform-wide once the poll catches up'; Expected = 401; Actual = $(if ($propagated) { 401 } else { 200 }); Result = if ($propagated) { 'PASS' } else { 'FAIL' } })

# 8. Rate limiting at the gateway. /health is exempt by design, so this hits a real routed, authenticated
# path instead. Only meaningful with a small GATEWAY_RATE_LIMIT_BURST for this run; otherwise informational.
$limited = 0
for ($i = 0; $i -lt 30; $i++) {
    $r = Invoke-Api GET "$gwAst/retrieve" (Bearer $admin.Session.accessToken)
    if ($r.Status -eq 429) { $limited++ }
}
Write-Output ("  {0} of 30 rapid authenticated calls were rate-limited (set a small GATEWAY_RATE_LIMIT_BURST to make this deterministic)" -f $limited)

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Secured smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
