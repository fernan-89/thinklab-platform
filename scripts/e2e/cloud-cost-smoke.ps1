<#
.SYNOPSIS
  Live proof of Journey 15, fourth service: cloud costs through the platform gateway (cloud-cost ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8111, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) an account is a provider account in one currency with a monthly budget: NO_DATA at first, found by provider and currency; a second
        account with the same name or the same provider account is a 409;
    (2) days move the verdict over the current UTC month: OK, NEAR_BUDGET from the straight line to the month end, back to OK when a day goes
        back to an earlier amount (the same report, restated), OVER_BUDGET; the same day and amount again is the stored report (200);
    (3) the same new amount reported by twenty tools at once is ONE report (one 201, nineteen 200);
    (4) last month stays out of this month; a day may be one day ahead, not two;
    (5) a bigger budget changes the verdict at once (nothing of it is stored);
    (6) two people pausing at once get one winner; a paused account is not judged but still takes costs; the trail reads in order;
    (7) an unknown provider and a day that cannot be read are refused (400) and never repeated; bad amounts and currencies are refused;
    (8) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (9) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    pwsh -File .\cloud-cost-smoke.ps1
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

$inv = [Globalization.CultureInfo]::InvariantCulture
function Money($Value) { if ($null -eq $Value) { 'None' } else { ([decimal]$Value).ToString('0.00', $inv) } }
$today = (Get-Date).ToUniversalTime().Date
function Day([int]$Offset) { $today.AddDays($Offset).ToString('yyyy-MM-dd') }
$firstDay = (Get-Date -Year $today.Year -Month $today.Month -Day 1).ToString('yyyy-MM-dd')
$lastOfPrevious = (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddDays(-1).ToString('yyyy-MM-dd')
$daysInMonth = [DateTime]::DaysInMonth($today.Year, $today.Month)
function Line([decimal]$PerDay) { Money ($PerDay * $daysInMonth) }

$cc = "$GatewayUrl/it-cloud-cost/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $vendorId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'billing-export' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Account-Body([string]$Name, [string]$Provider, [string]$ExternalId, [string]$Currency, [string]$Budget) {
    "{`"name`":`"$Name`",`"provider`":`"$Provider`",`"externalId`":`"$ExternalId`",`"currency`":`"$Currency`",`"monthlyBudget`":$Budget,`"warnPercent`":80,`"reportEveryHours`":24,`"vendorId`":`"$vendorId`"}" }
function Cost-Body([string]$Account, [string]$Day, [string]$Amount) { "{`"accountId`":`"$Account`",`"day`":`"$Day`",`"amount`":$Amount}" }
function Report($Body) { Invoke-Api POST "$cc/cost/initiate" $tool $Body }
function Judged([string]$Id) { $a = (Invoke-Api GET "$cc/$Id/retrieve" $staff).Body; "$($a.level)/$(Money $a.spent)/$(Money $a.projected)" }
function Count([string]$Url, $Headers = $staff) { @((Invoke-Api GET $Url $Headers).Body).Count }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }

# 1. An account is a provider account in one currency with a monthly budget, judged when read.
$created = Invoke-Api POST "$cc/initiate" $staff (Account-Body 'Production' 'AWS' '123456789012' 'USD' '3100.00')
$account = $created.Body.id
Assert-Equal 'staff register an AWS account in USD with 3100.00 a month: 201, ACTIVE, NO_DATA' "$($created.Status)/$($created.Body.status)/$($created.Body.level)/$($created.Body.currency)" '201/ACTIVE/NO_DATA/USD'
Assert-Equal 'the list finds it by provider and currency, and not by another currency' "$(@((Invoke-Api GET "$cc/retrieve?provider=AWS" $staff).Body)[0].id)/$(@((Invoke-Api GET "$cc/retrieve?currency=USD" $staff).Body)[0].id)/$(Count "$cc/retrieve?currency=EUR")" "$account/$account/0"
Assert-Equal 'a second account with the same name is a conflict (409)' (Invoke-Api POST "$cc/initiate" $staff (Account-Body 'Production' 'GCP' 'other-project' 'EUR' '1')).Status 409
Assert-Equal 'a second account for the same provider account is a conflict (409)' (Invoke-Api POST "$cc/initiate" $staff (Account-Body 'Other name' 'AWS' '123456789012' 'USD' '1')).Status 409

# 2. Days move the verdict: OK, NEAR_BUDGET from the line, back to OK, OVER_BUDGET.
$first = Report (Cost-Body $account $firstDay '50.00')
Assert-Equal 'the first day is a new fact: 201, the amount kept, reported by the tool' "$($first.Status)/$(Money $first.Body.amount)/$($first.Body.reportedBy)" '201/50.00/billing-export'
Assert-Equal '50.00 on day one heads well under the budget: OK, the line at 50.00 times the days of the month' (Judged $account) "OK/50.00/$(Line 50)"
$again = Report (Cost-Body $account $firstDay '50.00')
Assert-Equal 'the same day and amount again is the stored report (200)' "$($again.Status)/$($again.Body.id -eq $first.Body.id)" '200/True'
Assert-Equal 'a correction to 120.00 is a new report (201): NEAR_BUDGET from the line' "$((Report (Cost-Body $account $firstDay '120.00')).Status)/$(Judged $account)" "201/NEAR_BUDGET/120.00/$(Line 120)"
$back = Report (Cost-Body $account $firstDay '50.00')
Assert-Equal 'back to 50.00 is the first report, restated (200), and it counts again: OK' "$($back.Status)/$($back.Body.id -eq $first.Body.id)/$(Judged $account)" "200/True/OK/50.00/$(Line 50)"
Assert-Equal 'a correction to 3200.00 (201): OVER_BUDGET' "$((Report (Cost-Body $account $firstDay '3200.00')).Status)/$(Judged $account)" "201/OVER_BUDGET/3200.00/$(Line 3200)"
Assert-Equal 'the list finds it by level OVER_BUDGET and not by OK' "$(@((Invoke-Api GET "$cc/retrieve?level=OVER_BUDGET" $staff).Body)[0].id)/$(Count "$cc/retrieve?level=OK")" "$account/0"

# 3. The same new amount reported by twenty tools at once is one report.
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$same = Cost-Body $account $firstDay '3300.00'
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$cc/cost/initiate", $tenantId, "billing-export-$_", $same }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same day and amount reported by twenty tools at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'every answer is the same report' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'the account holds exactly four reports, and the month counts 3300.00' "$(Count "$cc/cost/retrieve?accountId=$account")/$(((Judged $account) -split '/')[0..1] -join '/')" '4/OVER_BUDGET/3300.00'

# 4. The month is this month; a day may be one day ahead, no more.
Assert-Equal 'a late cost for last month is new (201) and stays out of this month' "$((Report (Cost-Body $account $lastOfPrevious '99999.99')).Status)/$(((Judged $account) -split '/')[1])" '201/3300.00'
Assert-Equal 'the reports are listed newest day first, latest stated first, and limited' ((@((Invoke-Api GET "$cc/cost/retrieve?accountId=$account&limit=2" $staff).Body) | ForEach-Object { Money $_.amount }) -join ',') '3300.00,3200.00'
$second = (Invoke-Api POST "$cc/initiate" $staff (Account-Body 'Data platform' 'AZURE' 'sub-0f3c:prod' 'EUR' '500.00')).Body.id
Assert-Equal 'a cost for tomorrow is accepted (the provider day may be ahead): 201' (Report (Cost-Body $second (Day 1) '0.01')).Status 201
Assert-Equal 'a cost two days ahead is refused (400)' (Report (Cost-Body $second (Day 2) '0.01')).Status 400

# 5. A bigger budget changes the verdict at once, because nothing of it is stored.
Assert-Equal 'update to 10000.00 a month (204)' (Invoke-Api PUT "$cc/$account/update" $staff '{"name":"Production","monthlyBudget":10000.00,"warnPercent":80,"reportEveryHours":24}').Status 204
Assert-Equal '3300.00 on day one still heads over 10000.00: NEAR_BUDGET' (((Judged $account) -split '/')[0..1] -join '/') 'NEAR_BUDGET/3300.00'

# 6. Two people pause at once: one wins.
$pause = {
    param($url, $tenant, $executor)
    try { $r = Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$cc/$account/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
Assert-Equal 'two people pausing at once: one 204 and one 409' ((@($jobs | Wait-Job | Receive-Job) | Sort-Object) -join '/') '204/409'
$jobs | Remove-Job
Assert-Equal 'a paused account is not judged' (Judged $account) 'PAUSED/None/None'
Assert-Equal 'a paused account still accepts costs (201)' (Report (Cost-Body $account $firstDay '1.00')).Status 201
Assert-Equal 'resume' (Invoke-Api PUT "$cc/$account/control/resume" $staff).Status 204
Assert-Equal 'the account trail holds each real change once, in order' (Actions "$cc/$account/audit-log/retrieve") 'INITIATED,UPDATED,PAUSED,RESUMED'

# 7. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Invoke-Api POST "$cc/initiate" $staff (Account-Body 'n' 'AWS-secret-value' 'x1' 'USD' '1')
Assert-Equal 'an unknown provider is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text.Contains('secret-value'))" '400/False'
$badDay = Report "{`"accountId`":`"$account`",`"day`":`"secret-yesterday`",`"amount`":1}"
Assert-Equal 'a day that cannot be read is refused (400) and the answer does not repeat it' "$($badDay.Status)/$($badDay.Text.Contains('secret'))" '400/False'
Assert-Equal 'an amount with three decimals is refused (400)' (Report (Cost-Body $account $firstDay '1.005')).Status 400
Assert-Equal 'a negative amount is refused (400)' (Report (Cost-Body $account $firstDay '-1.00')).Status 400
Assert-Equal 'an unknown currency is refused (400)' (Invoke-Api POST "$cc/initiate" $staff (Account-Body 'Yen' 'AWS' 'y1' 'JPY' '1')).Status 400
Assert-Equal 'a cost for an account that is not the tenant''s is a 404' (Report (Cost-Body ([guid]::NewGuid().ToString()) $firstDay '1.00')).Status 404

# 8. Staff only, the tenant.
$refused = Invoke-Api POST "$cc/initiate" $asRequester (Account-Body 'r' 'AWS' 'r1' 'USD' '1')
Assert-Equal 'a REQUESTER cannot register an account (403 ERR-CLD-00403)' "$($refused.Status)/$($refused.Body.error_code)" '403/ERR-CLD-00403'
Assert-Equal 'a REQUESTER cannot read an account (403)' (Invoke-Api GET "$cc/$account/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report a cost (403)' (Invoke-Api POST "$cc/cost/initiate" $asRequester (Cost-Body $account $firstDay '1.00')).Status 403
Assert-Equal 'another tenant gets a 404 for the account and finds no reports' "$((Invoke-Api GET "$cc/$account/retrieve" $otherTenant).Status)/$(Count "$cc/cost/retrieve" $otherTenant)" '404/0'
$deleted = (Invoke-Api DELETE "$cc/$account" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 9. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-cloud-cost' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-cloud-cost' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Cloud cost smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
