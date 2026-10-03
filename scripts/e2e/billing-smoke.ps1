<#
.SYNOPSIS
  Live proof of Journey 9: plans, subscriptions and the entitlement lookup, through the platform gateway, with the gateway
  recording every subscription mutation on the compliance ledger.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts subscription-billing on 8095, routes it through the gateway, and turns the
  gateway's ledger recording on). Uses its own plan codes and its own tenant id (billing takes any UUID), then drives, through
  the GATEWAY:
    (1) a plan is drafted, edited and activated, and an organisation that has no subscription is decided by the default plan or,
        with none configured, left UNMANAGED (allowed - fail-open);
    (2) a subscription starts TRIALING and the entitlement now comes from its plan: a limit, an unlimited feature, a feature
        left out, a plan change, PAST_DUE as a grace period and SUSPENDED as nothing allowed;
    (3) a second subscription for the same organisation is refused (409), another tenant cannot read or cancel the first (404),
        and a RETIRED plan is no longer on sale;
    (4) every subscription mutation - and the refused one - is on the ledger with a masked path, the actor and its status,
        reads are not, and the chain verifies.

    powershell -File .\billing-smoke.ps1
#>
param(
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
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { $text | ConvertFrom-Json } else { $null } }
    }
}

function Assert-Status {
    param([string]$Name, $Response, [int]$Expected)
    $ok = ($Response.Status -eq $Expected)
    if (-not $ok) { Write-Output ("  {0} -> expected {1}, got {2}: {3}" -f $Name, $Expected, $Response.Status, ($Response.Body | ConvertTo-Json -Compress -Depth 4)) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Response.Status; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$executor = @{ 'X-Executor' = 'billing-smoke' }
$tenantId = [guid]::NewGuid().ToString()
$tenant = $executor + @{ 'X-Tenant-Id' = $tenantId }
$billing = "$GatewayUrl/subscription-billing/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$teamCode = "SMT$stamp"
$proCode = "SMP$stamp"

function Evaluate([string]$Feature) { (Invoke-Api GET "$billing/entitlement/evaluate?feature=$Feature" $tenant).Body }

# 1. A plan: drafted, edited, activated. Plans are platform-wide, so there is no tenant on these calls.
$plan = Invoke-Api POST "$billing/plan/initiate" $executor @{ code = $teamCode; name = 'Team'; entitlements = @{ assets = 500; sites = -1; sso = 0 } }
Assert-Status 'plan drafted through the gateway' $plan 201
$planId = $plan.Body.id
Assert-Equal 'a new plan is DRAFT' $plan.Body.status 'DRAFT'
Assert-Status 'a DRAFT plan can be edited' (Invoke-Api PUT "$billing/plan/$planId/update" $executor @{ name = 'Team edition'; entitlements = @{ assets = 500; sites = -1; sso = 0; discovery = 1 } }) 204
Assert-Status 'plan activated' (Invoke-Api PUT "$billing/plan/$planId/control/activate" $executor) 204
Assert-Status 'an ACTIVE plan cannot be edited (409)' (Invoke-Api PUT "$billing/plan/$planId/update" $executor @{ name = 'x'; entitlements = @{} }) 409
$second = Invoke-Api POST "$billing/plan/initiate" $executor @{ code = $proCode; name = 'Pro'; entitlements = @{ assets = 5000; sso = 1 } }
Assert-Status 'a second plan drafted' $second 201
Assert-Status 'second plan activated' (Invoke-Api PUT "$billing/plan/$($second.Body.id)/control/activate" $executor) 204

# 2. No subscription yet: the default plan (if one is configured and ACTIVE) or nobody-is-managing-this (allowed).
$before = Evaluate 'assets'
Assert-Equal 'without a subscription the default plan or UNMANAGED decides' (@('DEFAULT_PLAN', 'UNMANAGED') -contains $before.source) $true

# 3. A subscription, and the entitlements it brings.
$sub = Invoke-Api POST "$billing/initiate" $tenant @{ planCode = $teamCode }
Assert-Status 'subscription started through the gateway' $sub 201
$subId = $sub.Body.id
Assert-Equal 'a new subscription is TRIALING' $sub.Body.status 'TRIALING'
$limit = Evaluate 'assets'
Assert-Equal 'assets are decided by the subscription plan' $limit.source 'SUBSCRIPTION'
Assert-Equal 'assets are limited to 500' $limit.limit 500
Assert-Equal 'sites are unlimited: allowed, no limit' ($(Evaluate 'sites') | ForEach-Object { "$($_.allowed)/$($_.limit)" }) 'True/'
Assert-Equal 'a feature set to 0 is not included' (Evaluate 'sso').allowed $false
Assert-Equal 'a feature the plan never mentions is not included' (Evaluate 'nonexistent.feature').allowed $false
Assert-Status 'activate the subscription' (Invoke-Api PUT "$billing/$subId/control/activate" $tenant) 204
Assert-Status 'move it to the Pro plan (plan/update)' (Invoke-Api PUT "$billing/$subId/plan/update" $tenant @{ planCode = $proCode }) 204
Assert-Equal 'SSO is now allowed, decided by the new plan' ((Evaluate 'sso') | ForEach-Object { "$($_.allowed)/$($_.planCode)" }) "True/$proCode"
Assert-Status 'mark it past due' (Invoke-Api PUT "$billing/$subId/control/mark-past-due" $tenant) 204
Assert-Equal 'PAST_DUE is a grace period: still allowed' (Evaluate 'sso').allowed $true
Assert-Status 'suspend it' (Invoke-Api PUT "$billing/$subId/control/suspend" $tenant) 204
$suspended = Evaluate 'sso'
Assert-Equal 'SUSPENDED allows nothing' $suspended.allowed $false
Assert-Equal 'and says why' $suspended.source 'SUSPENDED'
Assert-Status 're-activate it' (Invoke-Api PUT "$billing/$subId/control/activate" $tenant) 204

# 4. The rules: one current subscription per organisation, tenant isolation, a RETIRED plan is off sale.
Assert-Status 'a second subscription for the same organisation is refused (409)' (Invoke-Api POST "$billing/initiate" $tenant @{ planCode = $teamCode }) 409
$otherTenant = $executor + @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString() }
Assert-Status 'another tenant cannot read it (404)' (Invoke-Api GET "$billing/$subId/retrieve" $otherTenant) 404
Assert-Status 'another tenant cannot cancel it (404)' (Invoke-Api PUT "$billing/$subId/control/cancel" $otherTenant) 404
Assert-Status 'retire the Team plan' (Invoke-Api PUT "$billing/plan/$planId/control/retire" $executor) 204
Assert-Status 'cancel the subscription' (Invoke-Api PUT "$billing/$subId/control/cancel" $tenant) 204
Assert-Status 'a RETIRED plan is not on sale (409)' (Invoke-Api POST "$billing/initiate" $tenant @{ planCode = $teamCode }) 409
Assert-Status 'a cancelled subscription is terminal (409)' (Invoke-Api PUT "$billing/$subId/control/activate" $tenant) 409
$audit = (Invoke-Api GET "$billing/$subId/audit-log/retrieve" $tenant).Body
Assert-Equal 'the subscription ledger reads in order' (($audit | ForEach-Object { $_.action }) -join ',') 'INITIATED,STATUS_CHANGED,PLAN_CHANGED,STATUS_CHANGED,STATUS_CHANGED,STATUS_CHANGED,STATUS_CHANGED'

# 5. The gateway put every subscription mutation on the compliance ledger (the refused ones too); reads are not recorded.
$expected = 10
$entries = @()
for ($i = 0; $i -lt 30; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=100" @{ 'X-Tenant-Id' = $tenantId }).Body)
    if ($entries.Count -ge $expected) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'every mutation with the tenant is on the ledger' $entries.Count $expected
$oldestFirst = @($entries | Sort-Object { [long]$_.sequence })
Assert-Equal 'the first recorded call is the subscription initiate' $oldestFirst[0].action 'POST /subscription-billing/v1/initiate'
Assert-Equal 'the resource type is the Service Domain' $oldestFirst[0].resourceType 'subscription-billing'
Assert-Equal 'a control call is recorded with a masked path' $oldestFirst[1].action 'PUT /subscription-billing/v1/{id}/control/activate'
Assert-Equal 'its resource id is the subscription' $oldestFirst[1].resourceId $subId
Assert-Equal 'the actor is the caller' $oldestFirst[1].actor 'billing-smoke'
Assert-Equal 'the refused duplicate initiate is recorded with its status' (@($oldestFirst | Where-Object { $_.detail -eq 'status=409' -and $_.action -eq 'POST /subscription-billing/v1/initiate' }).Count) 2
Assert-Equal 'no read and no plan call (platform-wide, no tenant) is recorded' (@($entries | Where-Object { $_.action -like 'GET *' -or $_.action -like '*/v1/plan/*' }).Count) 0
$integrity = Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }
Assert-Equal 'the tenant chain is valid' $integrity.Body.valid $true
Assert-Equal 'with every entry checked' $integrity.Body.entriesChecked $expected

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Billing smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
