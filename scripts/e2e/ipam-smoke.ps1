<#
.SYNOPSIS
  Live proof of Journey 15, third service: IP address management through the platform gateway (ipam ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8110, routes it through the gateway and turns the ledger recording on). Uses its own
  tenant id, then drives, through the GATEWAY:
    (1) a subnet is an IPv4 range judged when read; an overlapping one is refused and names the other range; host bits set are refused;
    (2) twenty creations at once of ranges that all overlap each other: exactly one survives;
    (3) an address is held once: twenty requests for one address give one winner; twenty requests for the next free one all get a different one;
    (4) a released address is handed out again, and the allocation keeps its trail;
    (5) a /29 fills up (FULL, no next free address), the network and broadcast addresses are never handed out, a retired subnet takes no address
        and cannot be reactivated over a range taken meanwhile (the undone reactivation is on its trail);
    (6) a hostname that is not a DNS name and addresses that are not dotted quads are refused, and never repeated;
    (7) staff only (a REQUESTER gets 403), another tenant gets a 404, no delete;
    (8) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    pwsh -File .\ipam-smoke.ps1
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

$ipm = "$GatewayUrl/it-ipam/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString(); $siteId = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }

function Subnet-Body([string]$Name, [string]$Cidr, [int]$Warn = 80) { @{ name = $Name; cidr = $Cidr; warnPercent = $Warn; siteId = $siteId } }
function Alloc-Body([string]$Subnet, [string]$Ip = $null) { if ($Ip) { @{ subnetId = $Subnet; ip = $Ip } } else { @{ subnetId = $Subnet } } }
function Judged([string]$Id) { $s = (Invoke-Api GET "$ipm/$Id/retrieve" $staff).Body; "$($s.level)/$($s.used)/$($s.free)" }
function Actions([string]$Url) { (@((Invoke-Api GET $Url $staff).Body | ForEach-Object { $_.action }) -join ',') }
$post = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).ip)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
function Tally($answers) { $c = @($answers | ForEach-Object { ($_ -split '/')[0] }); "$(@($c | Where-Object { $_ -eq '201' }).Count)/$(@($c | Where-Object { $_ -eq '409' }).Count)/$(@($c | Where-Object { $_ -ne '201' -and $_ -ne '409' }).Count)" }
function Race([string]$Url, $Bodies) {
    $jobs = @($Bodies | ForEach-Object { Start-Job -ScriptBlock $post -ArgumentList $Url, $tenantId, $user, ($_ | ConvertTo-Json) })
    $answers = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job
    return $answers
}

# 1. A subnet is an IPv4 range, judged when read; an overlapping one is refused.
$created = Invoke-Api POST "$ipm/initiate" $staff (Subnet-Body 'Office LAN' '10.20.0.0/24')
$office = $created.Body.id
Assert-Equal 'staff register 10.20.0.0/24: 201, ACTIVE, OK, 254 free, broadcast 10.20.0.255' "$($created.Status)/$($created.Body.status)/$($created.Body.level)/$($created.Body.free)/$($created.Body.broadcast)" '201/ACTIVE/OK/254/10.20.0.255'
Assert-Equal 'the list finds it by site and status' (@((Invoke-Api GET "$ipm/retrieve?siteId=$siteId&status=ACTIVE" $staff).Body)[0].id) $office
$overlap = Invoke-Api POST "$ipm/initiate" $staff (Subnet-Body 'Inside' '10.20.0.128/25')
Assert-Equal 'an overlapping range is refused (409) and the answer names the range it overlaps' "$($overlap.Status)/$($overlap.Text.Contains('10.20.0.0/24'))" '409/True'
Assert-Equal 'a CIDR with host bits set is refused (400)' (Invoke-Api POST "$ipm/initiate" $staff (Subnet-Body 'Host bits' '10.30.0.7/24')).Status 400

# 2. Twenty creations at once of ranges that all overlap each other (all start at 172.16.0.0): exactly one survives.
$bodies = 1..20 | ForEach-Object { Subnet-Body "Race $_" $(if ($_ % 2 -eq 0) { '172.16.0.0/16' } else { "172.16.0.0/$(16 + $_ % 8)" }) }
Assert-Equal 'twenty overlapping subnets created at once: one 201, nineteen 409, no other answer' (Tally (Race "$ipm/initiate" $bodies)) '1/19/0'
Assert-Equal 'and exactly one subnet holds the 172.16 range' @((Invoke-Api GET "$ipm/retrieve" $staff).Body | Where-Object { $_.cidr.StartsWith('172.16.') }).Count 1

# 3. An address is held once.
$first = Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office)
Assert-Equal 'without an address the lowest free one is handed out: 201, 10.20.0.1' "$($first.Status)/$($first.Body.ip)" '201/10.20.0.1'
Assert-Equal 'twenty requests for 10.20.0.50 at once: one 201, nineteen 409, no other answer' (Tally (Race "$ipm/allocation/initiate" (1..20 | ForEach-Object { Alloc-Body $office '10.20.0.50' }))) '1/19/0'
$free = Race "$ipm/allocation/initiate" (1..20 | ForEach-Object { Alloc-Body $office })
Assert-Equal 'twenty requests for the next free address at once: twenty 201' (Tally $free) '20/0/0'
$ips = @($free | ForEach-Object { ($_ -split '/')[1] })
Assert-Equal 'and twenty different addresses, none of them .1 or .50' "$(@($ips | Sort-Object -Unique).Count)/$(@($ips | Where-Object { $_ -eq '10.20.0.1' -or $_ -eq '10.20.0.50' }).Count -gt 0)" '20/False'
Assert-Equal 'the subnet counts 22 used, 232 free, OK' (Judged $office) 'OK/22/232'

# 4. Released, an address is handed out again.
$held = @((Invoke-Api GET "$ipm/allocation/retrieve?subnetId=$office" $staff).Body | Where-Object { $_.ip -eq '10.20.0.50' })[0].id
Assert-Equal '10.20.0.50 is released (204), and a second release is a 409' "$((Invoke-Api PUT "$ipm/allocation/$held/control/release" $staff).Status)/$((Invoke-Api PUT "$ipm/allocation/$held/control/release" $staff).Status)" '204/409'
Assert-Equal '10.20.0.50 can be handed out again (201)' (Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office '10.20.0.50')).Status 201
Assert-Equal 'its trail reads ALLOCATED, RELEASED' (Actions "$ipm/allocation/$held/audit-log/retrieve") 'ALLOCATED,RELEASED'

# 5. A tiny subnet fills up; retired, it takes nothing and cannot come back over a range taken meanwhile.
$tiny = (Invoke-Api POST "$ipm/initiate" $staff (Subnet-Body 'Lab' '192.168.50.0/29' 50)).Body.id
1..6 | ForEach-Object { [void](Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $tiny)) }
Assert-Equal 'six addresses fill a /29: FULL, nothing free' (Judged $tiny) 'FULL/6/0'
Assert-Equal 'a full subnet has no next free address (409)' (Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $tiny)).Status 409
Assert-Equal 'the network and the broadcast address are never handed out (400)' "$((Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office '10.20.0.0')).Status)/$((Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office '10.20.0.255')).Status)" '400/400'
Assert-Equal 'the /29 is retired (204) and takes no address (409)' "$((Invoke-Api PUT "$ipm/$tiny/control/retire" $staff).Status)/$((Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $tiny '192.168.50.6')).Status)" '204/409'
Assert-Equal 'a new subnet over the retired range is fine (201)' (Invoke-Api POST "$ipm/initiate" $staff (Subnet-Body 'Lab 2' '192.168.50.0/28')).Status 201
Assert-Equal 'reactivating the old /29 is refused now (409) and it stays RETIRED' "$((Invoke-Api PUT "$ipm/$tiny/control/reactivate" $staff).Status)/$((Invoke-Api GET "$ipm/$tiny/retrieve" $staff).Body.status)" '409/RETIRED'
Assert-Equal 'its trail shows the reactivation undone' (Actions "$ipm/$tiny/audit-log/retrieve") 'INITIATED,RETIRED,REACTIVATED,REACTIVATION_UNDONE'

# 6. Nothing that is not an address or a DNS name is kept, nor repeated.
$bad = Invoke-Api POST "$ipm/allocation/initiate" $staff @{ subnetId = $office; hostname = 'John secret-value Smith' }
Assert-Equal 'a hostname that is not a DNS name is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text.Contains('secret-value'))" '400/False'
Assert-Equal 'an address that is not a dotted quad is refused (400)' (Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office '10.20.0')).Status 400
Assert-Equal 'an address with a leading zero is refused (400)' (Invoke-Api POST "$ipm/allocation/initiate" $staff (Alloc-Body $office '10.20.0.010')).Status 400

# 7. Staff only, the tenant.
$refused = Invoke-Api POST "$ipm/initiate" $asRequester (Subnet-Body 'r' '10.99.0.0/24')
Assert-Equal 'a REQUESTER cannot register a subnet (403 ERR-IPM-00403)' "$($refused.Status)/$($refused.Body.error_code)" '403/ERR-IPM-00403'
Assert-Equal 'a REQUESTER cannot allocate or list allocations (403)' "$((Invoke-Api POST "$ipm/allocation/initiate" $asRequester (Alloc-Body $office)).Status)/$((Invoke-Api GET "$ipm/allocation/retrieve" $asRequester).Status)" '403/403'
Assert-Equal 'another tenant gets a 404 for the subnet and finds no allocations' "$((Invoke-Api GET "$ipm/$office/retrieve" $otherTenant).Status)/$(@((Invoke-Api GET "$ipm/allocation/retrieve" $otherTenant).Body).Count)" '404/0'
$deleted = (Invoke-Api DELETE "$ipm/$office" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 8. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-ipam' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-ipam' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'nothing anyone said is on the ledger' (($entries | ConvertTo-Json -Depth 6) -like '*secret*') $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("IPAM smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
