<#
.SYNOPSIS
  Live proof of Journey 15, second service: the licence registry through the platform gateway (license-registry ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8109, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a licence is what was bought: NO_DATA at first, found by unit and vendor; a second licence for the same product is a 409;
    (2) counts move the verdict: OK with the seats left, NEAR_LIMIT, OVER_LIMIT with the seats too many; a different count for a moment already
        reported is the stored report (200);
    (3) the same new count reported by twenty tools at once is ONE report (one 201, nineteen 200);
    (4) the latest count only moves forward, whatever the order three simultaneous reports arrive in; a late count never moves it back;
    (5) fewer seats bought changes the verdict at once (nothing of it is stored);
    (6) a tool that went silent is stale and still judged on its last count;
    (7) two people pausing at once get one winner; a paused licence is not judged but still takes counts; the trail reads in order;
    (8) an unknown unit and a moment that cannot be read are refused (400) and never repeated; bad counts are refused;
    (9) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (10) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    pwsh -File .\license-smoke.ps1
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

function Ago([double]$Minutes) { (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

$lic = "$GatewayUrl/it-license-registry/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $vendorId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'inventory-agent' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function License-Body([string]$Product, [string]$Unit, [int]$Entitled) { @{ product = $Product; unit = $Unit; entitled = $Entitled; warnPercent = 90; reportEveryHours = 24; vendorId = $vendorId } }
function Usage-Body([string]$License, $InUse, [string]$At) { @{ licenseId = $License; inUse = $InUse; measuredAt = $At } }
function Report($Body) { Invoke-Api POST "$lic/usage/initiate" $tool $Body }
function Judged([string]$Id) { $l = (Invoke-Api GET "$lic/$Id/retrieve" $staff).Body; "$($l.level)/$($l.available)" }
function Field([string]$Id, [string]$Name) { (Invoke-Api GET "$lic/$Id/retrieve" $staff).Body.$Name }
function Count([string]$Url, $Headers = $staff) { @((Invoke-Api GET $Url $Headers).Body).Count }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }

# 1. A licence is what was bought, judged when read.
$created = Invoke-Api POST "$lic/initiate" $staff (License-Body 'Office 365 E3' 'USER' 100)
$license = $created.Body.id
Assert-Equal 'staff register 100 user seats: 201, ACTIVE, NO_DATA, nothing available yet' "$($created.Status)/$($created.Body.status)/$($created.Body.level)/$($null -eq $created.Body.available)" '201/ACTIVE/NO_DATA/True'
Assert-Equal 'the list finds it by unit and vendor, and not by another unit' "$(@((Invoke-Api GET "$lic/retrieve?unit=USER" $staff).Body)[0].id)/$(@((Invoke-Api GET "$lic/retrieve?vendorId=$vendorId" $staff).Body)[0].id)/$(Count "$lic/retrieve?unit=CORE")" "$license/$license/0"
Assert-Equal 'a second licence for the same product is a conflict (409)' (Invoke-Api POST "$lic/initiate" $staff (License-Body 'Office 365 E3' 'DEVICE' 5)).Status 409

# 2. Counts move the verdict: OK, NEAR_LIMIT, OVER_LIMIT.
$m180 = Ago 180
$first = Report (Usage-Body $license 60 $m180)
Assert-Equal 'the first count is a new fact: 201, the count kept, reported by the tool' "$($first.Status)/$($first.Body.inUse)/$($first.Body.reportedBy)" '201/60/inventory-agent'
Assert-Equal '60 of 100 is OK with 40 left' (Judged $license) 'OK/40'
$again = Report (Usage-Body $license 99 $m180)
Assert-Equal 'the same moment with another count is the stored report (200), the first count kept' "$($again.Status)/$($again.Body.id -eq $first.Body.id)/$($again.Body.inUse)" '200/True/60'
Assert-Equal '95 is reported (201): NEAR_LIMIT with 5 left' "$((Report (Usage-Body $license 95 (Ago 120))).Status)/$(Judged $license)" '201/NEAR_LIMIT/5'
Assert-Equal '104 is reported (201): OVER_LIMIT with 4 seats too many' "$((Report (Usage-Body $license 104 (Ago 60))).Status)/$(Judged $license)" '201/OVER_LIMIT/-4'
Assert-Equal 'the list finds it by level OVER_LIMIT and not by OK' "$(@((Invoke-Api GET "$lic/retrieve?level=OVER_LIMIT" $staff).Body)[0].id)/$(Count "$lic/retrieve?level=OK")" "$license/0"

# 3. The same new count reported by twenty tools at once is one report.
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$same = (Usage-Body $license 103 (Ago 30)) | ConvertTo-Json
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$lic/usage/initiate", $tenantId, "inventory-agent-$_", $same }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same count reported by twenty tools at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'every answer is the same report' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'and the licence holds exactly four reports' (Count "$lic/usage/retrieve?licenseId=$license") 4

# 4. The latest count only moves forward, whatever the order the reports arrive in.
$specs = @(@(20, 70), @(15, 71), @(10, 72))
$jobs = $specs | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$lic/usage/initiate", $tenantId, 'inventory-agent', ((Usage-Body $license $_[1] (Ago $_[0])) | ConvertTo-Json) }
$three = @($jobs | Wait-Job | Receive-Job | ForEach-Object { ($_ -split '/')[0] })
$jobs | Remove-Job
Assert-Equal 'three counts reported at once: all new (201)' (($three | Sort-Object) -join '/') '201/201/201'
Assert-Equal 'the latest is the one with the newest moment, whichever arrived last: 72, OK again' "$(Field $license 'lastInUse')/$(Field $license 'level')" '72/OK'
Assert-Equal 'a late count (five days ago) is new and does not move the latest back' "$((Report (Usage-Body $license 10 (Ago 7200))).Status)/$(Field $license 'lastInUse')" '201/72'
Assert-Equal 'the reports are listed newest first and limited' ((@((Invoke-Api GET "$lic/usage/retrieve?licenseId=$license&limit=2" $staff).Body) | ForEach-Object { $_.inUse }) -join ',') '72,71'

# 5. Fewer seats bought changes the verdict at once, because nothing of it is stored.
Assert-Equal 'update to 70 seats bought (204)' (Invoke-Api PUT "$lic/$license/update" $staff (License-Body 'Office 365 E3' 'USER' 70)).Status 204
Assert-Equal '72 of 70 is now OVER_LIMIT' (Judged $license) 'OVER_LIMIT/-2'

# 6. A tool that went silent is stale, and still judged on its last count.
$quiet = (Invoke-Api POST "$lic/initiate" $staff (License-Body 'AutoCAD' 'DEVICE' 10)).Body.id
Assert-Equal 'a count of 11 devices from three days ago is accepted (201)' (Report (Usage-Body $quiet 11 (Ago 4320))).Status 201
Assert-Equal 'that licence is stale (more than twice 24 hours) and still OVER_LIMIT' "$(Field $quiet 'stale')/$(Field $quiet 'level')" 'True/OVER_LIMIT'

# 7. Two people pause at once: one wins.
$pause = {
    param($url, $tenant, $executor)
    try { $r = Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)" }
    catch { "$([int]$_.Exception.Response.StatusCode)" }
}
$jobs = 1..2 | ForEach-Object { Start-Job -ScriptBlock $pause -ArgumentList "$lic/$license/control/pause", $tenantId, ([guid]::NewGuid().ToString()) }
Assert-Equal 'two people pausing at once: one 204 and one 409' ((@($jobs | Wait-Job | Receive-Job) | Sort-Object) -join '/') '204/409'
$jobs | Remove-Job
Assert-Equal 'a paused licence is not judged (no seats available given)' (Judged $license) 'PAUSED/'
Assert-Equal 'a paused licence still accepts counts (201)' (Report (Usage-Body $license 5 (Ago 5))).Status 201
Assert-Equal 'resume' (Invoke-Api PUT "$lic/$license/control/resume" $staff).Status 204
Assert-Equal 'the licence trail holds each real change once, in order' (Actions "$lic/$license/audit-log/retrieve") 'INITIATED,UPDATED,PAUSED,RESUMED'

# 8. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Invoke-Api POST "$lic/initiate" $staff (License-Body 'n' 'USER-secret-value' 5)
Assert-Equal 'an unknown unit is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text.Contains('secret-value'))" '400/False'
$badTime = Report "{`"licenseId`":`"$license`",`"inUse`":1,`"measuredAt`":`"secret-yesterday`"}"
Assert-Equal 'a moment that cannot be read is refused (400) and the answer does not repeat it' "$($badTime.Status)/$($badTime.Text.Contains('secret'))" '400/False'
Assert-Equal 'a count that is not a whole number is refused (400)' (Report "{`"licenseId`":`"$license`",`"inUse`":`"lots`",`"measuredAt`":`"$(Ago 3)`"}").Status 400
Assert-Equal 'a negative count is refused (400)' (Report (Usage-Body $license -1 (Ago 3))).Status 400
Assert-Equal 'a count for a licence that is not the tenant''s is a 404' (Report (Usage-Body ([guid]::NewGuid().ToString()) 1 (Ago 3))).Status 404

# 9. Staff only, the tenant.
$refused = Invoke-Api POST "$lic/initiate" $asRequester (License-Body 'r' 'USER' 1)
Assert-Equal 'a REQUESTER cannot register a licence (403 ERR-LIC-00403)' "$($refused.Status)/$($refused.Body.error_code)" '403/ERR-LIC-00403'
Assert-Equal 'a REQUESTER cannot read a licence (403)' (Invoke-Api GET "$lic/$license/retrieve" $asRequester).Status 403
Assert-Equal 'a REQUESTER cannot report a count (403)' (Invoke-Api POST "$lic/usage/initiate" $asRequester (Usage-Body $license 1 (Ago 3))).Status 403
Assert-Equal 'another tenant gets a 404 for the licence and finds no reports' "$((Invoke-Api GET "$lic/$license/retrieve" $otherTenant).Status)/$(Count "$lic/usage/retrieve" $otherTenant)" '404/0'
$deleted = (Invoke-Api DELETE "$lic/$license" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 10. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-license-registry' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-license-registry' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("License smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
