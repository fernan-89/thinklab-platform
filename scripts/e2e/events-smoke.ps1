<#
.SYNOPSIS
  Live proof of the event backbone (micronaut-thinklab-service-kit ADR-003, ADR-023/024 of
  notification-dispatch-service): a real User creation publishes an outbox event, the relay ships it to
  NATS JetStream, notification-dispatch consumes it and dispatches a real welcome notification.

.DESCRIPTION
  Runs with THINKLAB_SECURITY_ENABLED left off (the default), so every call here is a plain,
  unauthenticated HTTP call directly to each service's own port - this journey is about the event
  backbone, not the security stack (see secured-smoke.ps1 for that). Start the stack with events on:

    $env:THINKLAB_EVENTS_ENABLED = 'true'
    .\start-local-stack.ps1 -Build

    powershell -File .\events-smoke.ps1

  It creates an Organisation, then a User - which makes party-authentication append an outbox event on
  thinklab.party-authentication.user.initiated - then polls notification-dispatch until the welcome
  notification the event triggered shows up as DELIVERED.
#>
param(
    [string]$OrgUrl = 'http://localhost:8081',
    [string]$AuthUrl = 'http://localhost:8082',
    [string]$NotificationUrl = 'http://localhost:8089'
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 5 }
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

$org = "$OrgUrl/party-reference-data-directory/v1"
$auth = "$AuthUrl/party-authentication/v1"
$notif = "$NotificationUrl/notification-dispatch/v1"
$executorHeader = @{ 'X-Executor' = 'events-smoke' }

# 1. A real Organisation and a real User, created with plain unauthenticated calls (security is off).
$taxId = (Get-Random -Minimum 10000000 -Maximum 99999999).ToString() + (Get-Random -Minimum 100000 -Maximum 999999).ToString()
$orgResponse = Invoke-Api POST "$org/initiate" $executorHeader @{ corporateName = 'Events Corp'; tradeName = 'Events'; taxIdentifier = $taxId; billing = @{ billingEmail = 'b@events.example'; currency = 'USD'; taxRegime = 'SIMPLES' } }
Assert-Status 'organisation created' $orgResponse 201
$orgId = $orgResponse.Body.id
$tenantAndExecutor = $executorHeader + @{ 'X-Tenant-Id' = $orgId }

$email = "ada.$([guid]::NewGuid().ToString('N').Substring(0,8))@events.example"
$userResponse = Invoke-Api POST "$auth/initiate" $tenantAndExecutor @{ fullName = 'Ada Lovelace'; email = $email; role = 'OPERATOR' }
Assert-Status 'user created (this appends the outbox event)' $userResponse 201

# 2. Poll notification-dispatch for the welcome notification the event triggered. The outbox relay polls
# every 5s by default and the JetStream consumer is push-like (near-instant once published), so this
# should resolve in well under the deadline - the wait exists to make the check reliable, not to hide a
# race that should already be closed.
Write-Output '  waiting up to 20s for the welcome notification to be delivered...'
$deadline = (Get-Date).AddSeconds(20)
$delivered = $null
while ((Get-Date) -lt $deadline -and -not $delivered) {
    $list = Invoke-Api GET "$notif/retrieve?status=DELIVERED" @{ 'X-Tenant-Id' = $orgId }
    if ($list.Status -eq 200) {
        $delivered = $list.Body | Where-Object { $_.recipient -eq $email } | Select-Object -First 1
    }
    if (-not $delivered) { Start-Sleep -Seconds 2 }
}
[void]$results.Add([pscustomobject]@{ Check = 'the welcome notification reaches DELIVERED'; Expected = 200; Actual = $(if ($delivered) { 200 } else { 0 }); Result = if ($delivered) { 'PASS' } else { 'FAIL' } })

if ($delivered) {
    [void]$results.Add([pscustomobject]@{ Check = 'the notification is on the LOG channel with the right subject'; Expected = 'LOG/Welcome to ThinkLab'; Actual = "$($delivered.channel)/$($delivered.subject)"; Result = if ($delivered.channel -eq 'LOG' -and $delivered.subject -eq 'Welcome to ThinkLab') { 'PASS' } else { 'FAIL' } })
    [void]$results.Add([pscustomobject]@{ Check = 'the notification body mentions the user by name'; Expected = 'contains Ada Lovelace'; Actual = $delivered.body; Result = if ($delivered.body -like '*Ada Lovelace*') { 'PASS' } else { 'FAIL' } })
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Events smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
