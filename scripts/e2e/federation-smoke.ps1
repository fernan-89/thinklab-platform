<#
.SYNOPSIS
  Live proof of Journey 13b (SSO): a person signs in through an OpenID Connect provider and ends up with the SAME kind of session a
  password login gives - with the refresh token in an HttpOnly cookie that page scripts can never read.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts identity-federation on 8097, routes it through the gateway and sets
  GATEWAY_SESSION_COOKIE_SECURE=false and THINKLAB_MOCK_OIDC_SECRET). The script starts the OIDC provider double
  (mock-oidc-provider.mjs, Node built-ins only) when nothing listens on its port, and plays the BROWSER itself (no automatic
  redirects), so it can read every Location and Set-Cookie. It drives, through the GATEWAY:
    (1) an organisation registers its provider (the client secret only NAMED), enables it, and sign-in starts with a 302 to the provider
        carrying PKCE S256, a state and a nonce;
    (2) a person nobody linked is refused (403, redirected to the login page with the error code only, no cookie);
    (3) after an administrator links the provider's subject to a user, the sign-in ends with a 302 to the web app and an HttpOnly,
        SameSite=Strict cookie, and the callback body carries no token; replaying the same code and state is refused;
    (4) the cookie buys an access token for THAT user and tenant (and the body never contains the refresh token), the cookie rotates,
        a replay of the old cookie is refused AND revokes the session (theft detection), and the web app header is required;
    (5) logout revokes the session and clears the cookie;
    (6) with automatic provisioning on, a first-time identity with a verified email gets a VIEWER; an unverified email does not;
    (7) a disabled provider refuses sign-in, and the secret never appears in any answer.

    powershell -File .\federation-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$IdpIssuer = 'http://localhost:9000',
    [string]$IdpUrl = '',
    [string]$NodeExe = (Join-Path $PSScriptRoot '..\..\..\tools\node\node.exe')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Web
if (-not $IdpUrl) { $IdpUrl = $IdpIssuer }
$results = New-Object System.Collections.ArrayList

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$http = New-Object System.Net.Http.HttpClient($handler)

function Send([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null) {
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)
    foreach ($name in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name]) }
    if ($null -ne $Body) { $request.Content = New-Object System.Net.Http.StringContent(($Body | ConvertTo-Json -Depth 5), [Text.Encoding]::UTF8, 'application/json') }
    $response = $http.SendAsync($request).GetAwaiter().GetResult()
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $parsed = $null
    if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null } }
    $location = $null
    if ($response.Headers.Contains('Location')) { $location = @($response.Headers.GetValues('Location'))[0] }
    $setCookie = $null
    if ($response.Headers.Contains('Set-Cookie')) { $setCookie = (@($response.Headers.GetValues('Set-Cookie')) -join ' || ') }
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Body = $parsed; Raw = $text; Location = $location; SetCookie = $setCookie }
}

function Assert-Status([string]$Name, $Response, [int]$Expected) {
    $ok = ($Response.Status -eq $Expected)
    if (-not $ok) { Write-Output ("  {0} -> expected {1}, got {2}: {3}" -f $Name, $Expected, $Response.Status, $Response.Raw) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Response.Status; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Assert-Equal([string]$Name, $Actual, $Expected) {
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Cookie-Value($SetCookie) { if ($SetCookie -match 'thinklab_rt=([^;]*)') { return $Matches[1] } return $null }

function Jwt-Claims([string]$Token) {
    $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $part = $part + ('=' * ((4 - $part.Length % 4) % 4))
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
}

# 0. The OIDC provider double (started here when nothing is listening; stopped at the end).
$idpProcess = $null
$idpPort = ([Uri]$IdpIssuer).Port
if (-not (Get-NetTCPConnection -LocalPort $idpPort -State Listen -ErrorAction SilentlyContinue)) {
    $env:MOCK_OIDC_PORT = "$idpPort"
    $env:MOCK_OIDC_ISSUER = $IdpIssuer
    $env:MOCK_OIDC_CLIENT_SECRET = 'mock-client-secret'
    $idpProcess = Start-Process -FilePath $NodeExe -ArgumentList (Join-Path $PSScriptRoot 'mock-oidc-provider.mjs') -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) { if ((Send GET "$IdpUrl/.well-known/openid-configuration").Status -eq 200) { break }; Start-Sleep -Milliseconds 300 }
}
try {
    $exec = @{ 'X-Executor' = 'federation-smoke' }
    function Set-Person($Person) { [void](Send POST "$IdpUrl/__mock/identity" @{} $Person) }
    function Sign-In([string]$Org) {
        $init = Send GET "$GatewayUrl/identity-federation/v1/login/initiate?organisationId=$Org"
        if ($init.Status -ne 302) { return [pscustomobject]@{ Init = $init; Callback = $null; Code = $null; State = $null } }
        $authorize = Send GET ($init.Location -replace '^https?://[^/]+', $IdpUrl)
        $back = [Uri]$authorize.Location
        $query = [System.Web.HttpUtility]::ParseQueryString($back.Query)
        $callback = Send GET "$GatewayUrl/identity-federation/v1/login/callback?code=$($query['code'])&state=$($query['state'])"
        return [pscustomobject]@{ Init = $init; Callback = $callback; Code = $query['code']; State = $query['state'] }
    }

    # 1. An organisation with a user, and its provider.
    $taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
    $org = Send POST "$GatewayUrl/party-reference-data-directory/v1/initiate" $exec @{ corporateName = 'Federation Corp'; tradeName = 'FED'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@fed.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
    Assert-Status 'organisation created' $org 201
    $orgId = $org.Body.id
    $tenant = $exec + @{ 'X-Tenant-Id' = $orgId }
    $email = "fed.smoke.$([guid]::NewGuid().ToString('N').Substring(0,8))@example.com"
    $user = Send POST "$GatewayUrl/party-authentication/v1/initiate" $tenant @{ fullName = 'Fed Smoke'; email = $email; role = 'OPERATOR' }
    Assert-Status 'user created' $user 201
    $userId = $user.Body.id
    Assert-Status 'user activated' (Send PUT "$GatewayUrl/party-authentication/v1/$userId/control/activate" $tenant) 204

    $provider = Send POST "$GatewayUrl/identity-federation/v1/initiate" $tenant @{ issuer = $IdpIssuer; clientId = 'thinklab-mock'; clientSecretRef = 'THINKLAB_MOCK_OIDC_SECRET'; autoProvision = $false }
    Assert-Status 'provider registered through the gateway' $provider 201
    $providerId = $provider.Body.id
    Assert-Equal 'it starts DISABLED' $provider.Body.status 'DISABLED'
    Assert-Equal 'the answer names the secret variable and never holds the secret' (($provider.Raw -notmatch 'mock-client-secret') -and $provider.Body.clientSecretRef -eq 'THINKLAB_MOCK_OIDC_SECRET') $true
    Assert-Status 'a DISABLED provider refuses sign-in (409)' (Send GET "$GatewayUrl/identity-federation/v1/login/initiate?organisationId=$orgId") 409
    Assert-Status 'provider enabled' (Send PUT "$GatewayUrl/identity-federation/v1/$providerId/control/enable" $tenant) 204

    # 2. Sign-in starts with a redirect to the provider, carrying PKCE, a state and a nonce.
    Set-Person @{ sub = 'smoke-subject-1'; email = $email; email_verified = $true; name = 'Fed Smoke' }
    $first = Sign-In $orgId
    Assert-Status 'login/initiate answers a redirect to the provider' $first.Init 302
    Assert-Equal 'it points at the provider authorize endpoint' $first.Init.Location.StartsWith("$IdpIssuer/authorize?") $true
    Assert-Equal 'with the code flow, PKCE S256, a state and a nonce' (($first.Init.Location -match 'response_type=code') -and ($first.Init.Location -match 'code_challenge_method=S256') -and ($first.Init.Location -match 'state=') -and ($first.Init.Location -match 'nonce=')) $true

    # 3. A person nobody linked is refused: redirected to the login page with the error code only, and no cookie.
    Assert-Status 'an unlinked identity is sent back to the login page' $first.Callback 302
    Assert-Equal 'with the error code only' $first.Callback.Location '/login?sso_error=ERR-FED-00403'
    Assert-Equal 'and no cookie' $first.Callback.SetCookie $null

    # 4. An administrator links the provider's subject to the user; the sign-in now ends with a cookie.
    $link = Send POST "$GatewayUrl/identity-federation/v1/link/initiate" $tenant @{ userId = $userId; subject = 'smoke-subject-1' }
    Assert-Status 'identity linked to the user' $link 201
    $linked = Sign-In $orgId
    Assert-Status 'a linked identity is sent on to the web app' $linked.Callback 302
    Assert-Equal 'to the sign-in completion page' $linked.Callback.Location '/sso/complete'
    Assert-Equal 'the refresh token is in an HttpOnly cookie' ($linked.Callback.SetCookie -match 'thinklab_rt=[^;]+' -and $linked.Callback.SetCookie -match '(?i)HttpOnly') $true
    Assert-Equal 'which is SameSite=Strict' ($linked.Callback.SetCookie -match '(?i)SameSite=Strict') $true
    Assert-Equal 'and scoped to the gateway session endpoints' ($linked.Callback.SetCookie -match '(?i)Path=/api/gateway/v1/session') $true
    Assert-Equal 'the redirect carries no token in the URL or the body' (($linked.Callback.Location -notmatch 'token') -and [string]::IsNullOrEmpty($linked.Callback.Raw)) $true
    $cookie1 = Cookie-Value $linked.Callback.SetCookie

    $replayed = Send GET "$GatewayUrl/identity-federation/v1/login/callback?code=$($linked.Code)&state=$($linked.State)"
    Assert-Equal 'replaying the same code and state is refused (single-use state)' $replayed.Location '/login?sso_error=ERR-FED-00400'

    # 5. The cookie buys an access token for that user and tenant; the refresh token never reaches the body; the cookie rotates.
    $webApp = @{ 'X-Requested-With' = 'thinklab-web' }
    Assert-Status 'refresh without the web app header is refused (403)' (Send POST "$GatewayUrl/gateway/v1/session/refresh" @{ Cookie = "thinklab_rt=$cookie1" }) 403
    Assert-Status 'refresh without a cookie is refused (401)' (Send POST "$GatewayUrl/gateway/v1/session/refresh" $webApp) 401
    $refreshed = Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$cookie1" })
    Assert-Status 'refresh exchanges the cookie for an access token' $refreshed 200
    $claims = Jwt-Claims $refreshed.Body.accessToken
    Assert-Equal 'the access token is for the linked user' $claims.sub $userId
    Assert-Equal 'in the organisation' $claims.tid $orgId
    Assert-Equal 'with the role of the platform user, not of the provider' $claims.role 'OPERATOR'
    Assert-Equal 'the answer never contains the refresh token' ($refreshed.Raw -notmatch 'refresh') $true
    $cookie2 = Cookie-Value $refreshed.SetCookie
    Assert-Equal 'the cookie rotated' (($cookie2 -ne $null) -and ($cookie2 -ne $cookie1)) $true
    $second = Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$cookie2" })
    Assert-Status 'the rotated cookie works' $second 200
    $cookie3 = Cookie-Value $second.SetCookie
    Assert-Status 'a replay of the OLD cookie is refused (401)' (Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$cookie1" })) 401
    Assert-Status 'and the replay revoked the whole session (theft detection): even the newest cookie is refused (401)' (Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$cookie3" })) 401

    # 6. Logout revokes the session and clears the cookie.
    $again = Sign-In $orgId
    $cookie4 = Cookie-Value $again.Callback.SetCookie
    $logout = Send POST "$GatewayUrl/gateway/v1/session/logout" ($webApp + @{ Cookie = "thinklab_rt=$cookie4" })
    Assert-Status 'logout answers 204' $logout 204
    Assert-Equal 'and clears the cookie' ($logout.SetCookie -match 'thinklab_rt=;' -and $logout.SetCookie -match 'Max-Age=0') $true
    Assert-Status 'the logged-out cookie no longer refreshes (401)' (Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$cookie4" })) 401

    # 7. Automatic provisioning (off by default): a first-time identity with a verified email gets a VIEWER; an unverified one does not.
    Assert-Status 'provider disabled to change its settings' (Send PUT "$GatewayUrl/identity-federation/v1/$providerId/control/disable" $tenant) 204
    Assert-Status 'disabled again, it refuses sign-in (409)' (Send GET "$GatewayUrl/identity-federation/v1/login/initiate?organisationId=$orgId") 409
    Assert-Status 'settings updated: automatic provisioning on' (Send PUT "$GatewayUrl/identity-federation/v1/$providerId/update" $tenant @{ issuer = $IdpIssuer; clientId = 'thinklab-mock'; clientSecretRef = 'THINKLAB_MOCK_OIDC_SECRET'; autoProvision = $true }) 204
    Assert-Status 'provider enabled again' (Send PUT "$GatewayUrl/identity-federation/v1/$providerId/control/enable" $tenant) 204
    $newcomer = "newcomer.$([guid]::NewGuid().ToString('N').Substring(0,8))@example.com"
    Set-Person @{ sub = 'smoke-subject-new'; email = $newcomer; email_verified = $true; name = 'New Comer' }
    $provisioned = Sign-In $orgId
    Assert-Equal 'a first-time identity with a verified email is signed in' $provisioned.Callback.Location '/sso/complete'
    $newToken = Cookie-Value $provisioned.Callback.SetCookie
    $newAccess = (Send POST "$GatewayUrl/gateway/v1/session/refresh" ($webApp + @{ Cookie = "thinklab_rt=$newToken" })).Body.accessToken
    Assert-Equal 'as a VIEWER, the least privileged role' (Jwt-Claims $newAccess).role 'VIEWER'
    Assert-Equal 'a link was created for it' @((Send GET "$GatewayUrl/identity-federation/v1/link/retrieve?status=ACTIVE" $tenant).Body).Count 2
    Set-Person @{ sub = 'smoke-subject-unverified'; email = "unverified.$([guid]::NewGuid().ToString('N').Substring(0,8))@example.com"; email_verified = $false; name = 'Unverified' }
    $unverified = Sign-In $orgId
    Assert-Equal 'an UNVERIFIED email is never provisioned' $unverified.Callback.Location '/login?sso_error=ERR-FED-00403'

    # 8. A revoked link ends the sign-in for that person.
    $linkId = $link.Body.id
    Assert-Status 'the first link revoked' (Send PUT "$GatewayUrl/identity-federation/v1/link/$linkId/control/revoke" $tenant) 204
    Set-Person @{ sub = 'smoke-subject-1'; email = $email; email_verified = $false; name = 'Fed Smoke' }
    Assert-Equal 'a revoked link no longer signs the person in' (Sign-In $orgId).Callback.Location '/login?sso_error=ERR-FED-00403'

    # 9. The secret never appears in what the platform answers.
    $everything = (Send GET "$GatewayUrl/identity-federation/v1/retrieve" $tenant).Raw + (Send GET "$GatewayUrl/identity-federation/v1/$providerId/audit-log/retrieve" $tenant).Raw
    Assert-Equal 'the client secret appears in no answer' ($everything -notmatch 'mock-client-secret') $true
} finally {
    if ($idpProcess) { Stop-Process -Id $idpProcess.Id -Force -ErrorAction SilentlyContinue }
    $http.Dispose()
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Federation smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
