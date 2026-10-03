<#
.SYNOPSIS
  Live proof of plan-based feature gating (gateway ADR-026): a request for a Service Domain whose feature the tenant's plan does not
  include is turned away with 403 at the gateway, and a plan change or a suspension is felt within the cache time.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1). The ordinary gateway (8088) has gating OFF, so every other smoke keeps working; this
  script starts a SECOND gateway on 8188 from the same build with gating ON and a 1 second cache, and stops it at the end. Through it:
    (1) a tenant on a plan WITHOUT 'audit' and 'sso' is refused (403 ERR-GTW-00403) on the ledger and on identity federation, but not
        on discovery (included) nor on the asset registry (not gated at all);
    (2) the sign-in routes carry no tenant, so a plan never blocks them;
    (3) moving the tenant to a plan that includes 'audit' opens the ledger within the cache time, and the ungated gateway never refused;
    (4) a SUSPENDED subscription is refused on every gated domain while ungated domains still answer;
    (5) a tenant without a subscription gets whatever billing says (default plan, or allowed when unmanaged).

    powershell -File .\plan-gating-smoke.ps1
#>
param(
    [string]$GatedUrl = 'http://localhost:8188',
    [string]$PlainUrl = 'http://localhost:8088',
    [switch]$UseRunningGatedGateway
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
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

# The gated gateway: the same build as the ordinary one, another port, gating on, a short cache so a plan change shows quickly.
$gatedProcess = $null
if (-not $UseRunningGatedGateway) {
    $java = Get-Java21
    $name = 'micronaut-platform-gateway-service'
    $workspace = Split-Path (Split-Path (Split-Path $PSScriptRoot))
    $lib = (Join-Path $workspace "$name\build\install\$name\lib") + '\*'
    $env:MICRONAUT_SERVER_PORT = '8188'
    $env:GATEWAY_ENTITLEMENTS_ENABLED = 'true'
    $env:GATEWAY_ENTITLEMENTS_CACHE_TTL = '1s'
    $env:GATEWAY_AUDIT_ENABLED = 'false'
    $log = Join-Path ([IO.Path]::GetTempPath()) 'plan-gating-gateway'
    $gatedProcess = Start-Process $java -ArgumentList '-cp', "`"$lib`"", 'com.thinklab.Application' `
        -RedirectStandardOutput "$log.log" -RedirectStandardError "$log.err" -WindowStyle Hidden -PassThru
    Remove-Item Env:\GATEWAY_ENTITLEMENTS_ENABLED, Env:\GATEWAY_ENTITLEMENTS_CACHE_TTL, Env:\MICRONAUT_SERVER_PORT -ErrorAction SilentlyContinue
    if (-not (Wait-Http "$GatedUrl/health/liveness" 90)) { Stop-Process -Id $gatedProcess.Id -Force; throw "the gated gateway did not start; see $log.err" }
}

try {
    $executor = @{ 'X-Executor' = 'plan-gating-smoke' }
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $basicCode = "PGB$stamp"
    $fullCode = "PGF$stamp"
    $tenantId = [guid]::NewGuid().ToString()
    $tenant = $executor + @{ 'X-Tenant-Id' = $tenantId }
    $billing = "$GatedUrl/subscription-billing/v1"
    $ledgerPath = '/compliance-audit-ledger/v1/retrieve?limit=1'
    $federationPath = '/identity-federation/v1/retrieve'
    $discoveryPath = '/it-discovery/v1/retrieve'
    $assetPath = '/it-asset-registry/v1/retrieve'

    function Status([string]$Path, [hashtable]$Headers = $tenant) { (Invoke-Api GET "$GatedUrl$Path" $Headers) }

    # Two plans: one that leaves audit and sso out, one that includes them.
    $basic = Invoke-Api POST "$billing/plan/initiate" $executor @{ code = $basicCode; name = 'Basic'; entitlements = @{ discovery = 1; audit = 0; sso = 0 } }
    Assert-Equal 'basic plan drafted' $basic.Status 201
    Assert-Equal 'basic plan activated' (Invoke-Api PUT "$billing/plan/$($basic.Body.id)/control/activate" $executor).Status 204
    $full = Invoke-Api POST "$billing/plan/initiate" $executor @{ code = $fullCode; name = 'Full'; entitlements = @{ discovery = 1; audit = 1; sso = 1 } }
    Assert-Equal 'full plan drafted' $full.Status 201
    Assert-Equal 'full plan activated' (Invoke-Api PUT "$billing/plan/$($full.Body.id)/control/activate" $executor).Status 204

    # Without a subscription the default plan decides, or nothing does (UNMANAGED, allowed): the gateway must agree with billing either way.
    $verdict = (Invoke-Api GET "$billing/entitlement/evaluate?feature=audit" $tenant).Body
    $noSubscription = Status $ledgerPath
    Assert-Equal 'without a subscription the gateway agrees with billing (default plan, or fail-open when unmanaged)' ($noSubscription.Status -eq 403) (-not $verdict.allowed)

    $sub = Invoke-Api POST "$billing/initiate" $tenant @{ planCode = $basicCode }
    Assert-Equal 'subscription started on the basic plan' $sub.Status 201
    $subId = $sub.Body.id
    Assert-Equal 'subscription activated' (Invoke-Api PUT "$billing/$subId/control/activate" $tenant).Status 204
    Start-Sleep -Seconds 2   # let a cached "no subscription" answer expire

    # 1. The basic plan: ledger and federation refused, discovery and the asset registry open.
    $ledger = Status $ledgerPath
    Assert-Equal 'the ledger is refused: 403' $ledger.Status 403
    Assert-Equal 'with the gateway error code' $ledger.Body.error_code 'ERR-GTW-00403'
    Assert-Equal 'saying which feature the plan lacks' $ledger.Body.detail "Your plan does not include 'audit'."
    Assert-Equal 'identity federation is refused: 403' (Status $federationPath).Status 403
    Assert-Equal 'discovery (included in the plan) is not refused by the plan' ((Status $discoveryPath).Status -ne 403) $true
    Assert-Equal 'the asset registry (not gated) is not refused by the plan' ((Status $assetPath).Status -ne 403) $true

    # 2. Sign-in routes carry no tenant, so a plan never blocks them.
    $login = Invoke-Api GET "$GatedUrl/identity-federation/v1/login/initiate?organisationId=$tenantId" @{}
    Assert-Equal 'sign-in is not blocked by a plan (no tenant on it)' ($login.Status -ne 403 -or $login.Body.error_code -ne 'ERR-GTW-00403') $true

    # The ordinary gateway has gating off: the same call is never refused by a plan.
    $plain = Invoke-Api GET "$PlainUrl$ledgerPath" $tenant
    Assert-Equal 'the ordinary gateway (gating off) does not refuse the ledger' ($plain.Status -ne 403) $true

    # 3. A plan that includes audit: opens within the cache time.
    Assert-Equal 'move the subscription to the full plan' (Invoke-Api PUT "$billing/$subId/plan/update" $tenant @{ planCode = $fullCode }).Status 204
    Start-Sleep -Seconds 2
    Assert-Equal 'the ledger now opens (plan change felt within the cache time)' ((Status $ledgerPath).Status -ne 403) $true
    Assert-Equal 'federation now opens too' ((Status $federationPath).Status -ne 403) $true

    # 4. Suspended: every gated domain is refused, ungated ones still answer.
    Assert-Equal 'suspend the subscription' (Invoke-Api PUT "$billing/$subId/control/suspend" $tenant).Status 204
    Start-Sleep -Seconds 2
    Assert-Equal 'suspended: the ledger is refused' (Status $ledgerPath).Status 403
    Assert-Equal 'suspended: discovery is refused too' (Status $discoveryPath).Status 403
    Assert-Equal 'suspended: the asset registry (not gated) still answers' ((Status $assetPath).Status -ne 403) $true
    Assert-Equal 're-activate the subscription' (Invoke-Api PUT "$billing/$subId/control/activate" $tenant).Status 204
    Start-Sleep -Seconds 2
    Assert-Equal 're-activated: the ledger opens again' ((Status $ledgerPath).Status -ne 403) $true

    # Tidy: cancel so the tenant leaves nothing active behind.
    Assert-Equal 'cancel the subscription' (Invoke-Api PUT "$billing/$subId/control/cancel" $tenant).Status 204
} finally {
    if ($gatedProcess) { Stop-Process -Id $gatedProcess.Id -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Plan gating smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
