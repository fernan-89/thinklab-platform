<#
.SYNOPSIS
  Live proof of Journey 15, fifth service: AWS and Azure resources through the platform gateway (cloud inventory ADR-030..034).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8113, routes it through the gateway and turns the ledger recording on). Uses its
  own tenant id, then drives, through the GATEWAY:
    (1) a resource is reported (201), the same one again is the same resource (200), a changed report replaces the snapshot, an Azure resource id
        (slashes, no tags) is valid, the same ARN under another account is another resource;
    (2) the same new resource reported by twenty tools at once is ONE resource (one 201, nineteen 200);
    (3) reading, the filters (account, provider, kind, region, state) and the summary;
    (4) a terminated resource is judged GONE, and comes back PRESENT when reported running;
    (5) an unknown provider or kind, a tag key that is not kept, a tag value with a person and an address, a name with a space and a region in
        capitals are refused (400) and never repeated;
    (6) staff only (a REQUESTER gets 403), another tenant gets a 404 and counts none, no delete;
    (7) every mutation, including the refused ones, is recorded on the ledger, and the chain verifies.

    pwsh -File .\cloud-inventory-smoke.ps1
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

$inv = "$GatewayUrl/it-cloud-inventory/v1"
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$tenantId = [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString(); $requester = [guid]::NewGuid().ToString()
$account = [guid]::NewGuid().ToString(); $otherAccount = [guid]::NewGuid().ToString()
$staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user }
$tool = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'steampipe-sync' }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $requester; 'X-Role' = 'REQUESTER' }
$otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $user }
$arn = 'arn:aws:ec2:us-east-1:123456789012:instance/i-0abc'
$azureId = '/subscriptions/0000-1111/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1'
$dbArn = 'arn:aws:rds:us-east-1:123456789012:db:orders'

function Res-Body([string]$Account, [string]$Provider, [string]$ExternalId, [string]$Name, [string]$Kind, [string]$Region, [string]$State, [string]$Tags) {
    "{`"accountId`":`"$Account`",`"provider`":`"$Provider`",`"externalId`":`"$ExternalId`",`"name`":`"$Name`",`"kind`":`"$Kind`",`"region`":`"$Region`",`"state`":`"$State`",`"tags`":$Tags}" }
function Report($Body) { Invoke-Api POST "$inv/initiate" $tool $Body }
function Count([string]$Url, $Headers = $staff) { @((Invoke-Api GET $Url $Headers).Body).Count }
function Tags($Value) { (($Value.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') }

# 1. A resource is reported, restated and replaced; the provider's id is its identity.
$first = Report (Res-Body $account 'AWS' $arn 'web-1' 'COMPUTE' 'us-east-1' 'RUNNING' '{"environment":"prod","owner":"team-a"}')
Assert-Equal 'a new AWS instance is 201, judged PRESENT, with what the tool said' "$($first.Status)/$($first.Body.presence)/$($first.Body.state)/$($first.Body.kind)" '201/PRESENT/RUNNING/COMPUTE'
$resource = $first.Body.id
$again = Report (Res-Body $account 'AWS' $arn 'web-1' 'COMPUTE' 'us-east-1' 'RUNNING' '{"environment":"prod","owner":"team-a"}')
Assert-Equal 'the same resource again is 200 and the same resource' "$($again.Status)/$($again.Body.id)" "200/$resource"
$replaced = Report (Res-Body $account 'AWS' $arn 'web-1b' 'COMPUTE' 'us-east-1' 'STOPPED' '{"environment":"dev"}')
Assert-Equal 'a changed report replaces the snapshot (200, same id, new state, name and tags)' "$($replaced.Status)/$($replaced.Body.id)/$($replaced.Body.state)/$($replaced.Body.name)/$(Tags $replaced.Body.tags)" "200/$resource/STOPPED/web-1b/environment=dev"
$azure = Report (Res-Body $account 'AZURE' $azureId 'vm1' 'COMPUTE' 'brazilsouth' 'RUNNING' '{}')
Assert-Equal 'an Azure resource id, with slashes and no tags, is 201' "$($azure.Status)/$($azure.Body.provider)/$(Tags $azure.Body.tags)" '201/AZURE/'
$other = Report (Res-Body $otherAccount 'AWS' $arn 'web-1' 'COMPUTE' 'us-east-1' 'RUNNING' '{}')
Assert-Equal 'the same ARN under another account is another resource (201)' "$($other.Status)/$($other.Body.id -ne $resource)" '201/True'
$db = Report (Res-Body $account 'AWS' $dbArn 'orders' 'DATABASE' 'us-east-1' 'RUNNING' '{}')
$dbId = $db.Body.id

# 2. The same new resource reported by twenty tools at once is one resource.
$run = {
    param($url, $tenant, $executor, $body)
    try { $r = Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Body $body -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor }; "$([int]$r.StatusCode)/$(($r.Content | ConvertFrom-Json).id)" }
    catch { "$([int]$_.Exception.Response.StatusCode)/" }
}
$same = Res-Body $account 'AWS' 'arn:aws:s3:::race-bucket' 'race-bucket' 'STORAGE' 'us-east-1' 'RUNNING' '{}'
$jobs = 1..20 | ForEach-Object { Start-Job -ScriptBlock $run -ArgumentList "$inv/initiate", $tenantId, "sync-$_", $same }
$answers = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
$codes = @($answers | ForEach-Object { ($_ -split '/')[0] })
Assert-Equal 'the same new resource reported by twenty tools at once: one 201, nineteen 200, no other answer' "$(@($codes | Where-Object { $_ -eq '201' }).Count)/$(@($codes | Where-Object { $_ -eq '200' }).Count)/$(@($codes | Where-Object { $_ -ne '201' -and $_ -ne '200' }).Count)" '1/19/0'
Assert-Equal 'every answer is the same resource' @($answers | ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique).Count 1
Assert-Equal 'the inventory holds exactly four resources of the account (and the other account has one)' "$(Count "$inv/retrieve?accountId=$account")/$(Count "$inv/retrieve?accountId=$otherAccount")" '4/1'

# 3. Reading, filters and the summary.
$one = (Invoke-Api GET "$inv/$resource/retrieve" $staff).Body
Assert-Equal 'one resource is read, judged now' "$($one.state)/$($one.presence)" 'STOPPED/PRESENT'
Assert-Equal 'the list finds the Azure resource by provider' @((Invoke-Api GET "$inv/retrieve?provider=AZURE" $staff).Body)[0].id $azure.Body.id
Assert-Equal 'the list finds the database by kind and by region, and nothing in another region' "$(@((Invoke-Api GET "$inv/retrieve?kind=DATABASE&region=us-east-1" $staff).Body)[0].id)/$(Count "$inv/retrieve?kind=DATABASE&region=eu-west-1")" "$dbId/0"
Assert-Equal 'the list finds the stopped one by state' @((Invoke-Api GET "$inv/retrieve?state=STOPPED" $staff).Body)[0].id $resource
Assert-Equal 'a limit is kept' (Count "$inv/retrieve?limit=2") 2
$summary = (Invoke-Api GET "$inv/summary/retrieve" $staff).Body
Assert-Equal 'the summary counts five resources by provider and by presence' "$($summary.total)/$($summary.byProvider.AWS)/$($summary.byProvider.AZURE)/$($summary.byPresence.PRESENT)" '5/4/1/5'
Assert-Equal 'the summary of one provider counts only it' (Invoke-Api GET "$inv/summary/retrieve?provider=AZURE" $staff).Body.total 1

# 4. A terminated resource is GONE, and comes back when reported running.
$gone = Report (Res-Body $account 'AWS' $dbArn 'orders' 'DATABASE' 'us-east-1' 'TERMINATED' '{}')
Assert-Equal 'a terminated resource is judged GONE (same resource)' "$($gone.Status)/$($gone.Body.id)/$($gone.Body.presence)" "200/$dbId/GONE"
Assert-Equal 'the list finds what is gone' @((Invoke-Api GET "$inv/retrieve?presence=GONE" $staff).Body)[0].id $dbId
$back = Report (Res-Body $account 'AWS' $dbArn 'orders' 'DATABASE' 'us-east-1' 'RUNNING' '{}')
Assert-Equal 'reported running again, it is PRESENT' $back.Body.presence 'PRESENT'

# 5. Nothing the registry does not know is accepted, and nothing of it is repeated.
$bad = Report (Res-Body $account 'GCP' $arn 'n' 'COMPUTE' 'us-east-1' 'RUNNING' '{}')
Assert-Equal 'an unknown provider is refused (400) and the answer does not repeat it' "$($bad.Status)/$($bad.Text -like '*GCP*')" '400/False'
$secret = Report (Res-Body $account 'AWS' 'i-secret' 'n' 'COMPUTE' 'us-east-1' 'RUNNING' '{"password":"hunter2-secret"}')
Assert-Equal 'a tag key that is not kept is refused (400) and the answer does not repeat it' "$($secret.Status)/$($secret.Text -like '*hunter2*')" '400/False'
$person = Report (Res-Body $account 'AWS' 'i-person' 'n' 'COMPUTE' 'us-east-1' 'RUNNING' '{"owner":"Ana <ana-secret@example.com>"}')
Assert-Equal 'a tag value with a person and an address is refused (400) and not repeated' "$($person.Status)/$($person.Text -like '*ana-secret*')" '400/False'
Assert-Equal 'a name with a space is refused (400)' (Report (Res-Body $account 'AWS' 'i-x' 'web 1' 'COMPUTE' 'us-east-1' 'RUNNING' '{}')).Status 400
Assert-Equal 'a region in capitals is refused (400)' (Report (Res-Body $account 'AWS' 'i-y' 'n' 'COMPUTE' 'US-EAST' 'RUNNING' '{}')).Status 400
Assert-Equal 'an unknown kind is refused (400)' (Report (Res-Body $account 'AWS' 'i-z' 'n' 'TOASTER' 'us-east-1' 'RUNNING' '{}')).Status 400

# 6. Staff only, the tenant.
$refused = Invoke-Api POST "$inv/initiate" $asRequester (Res-Body $account 'AWS' 'r1' 'n' 'COMPUTE' 'us-east-1' 'RUNNING' '{}')
Assert-Equal 'a REQUESTER cannot report a resource (403 ERR-INV-00403)' "$($refused.Status)/$($refused.Body.error_code)" '403/ERR-INV-00403'
Assert-Equal 'a REQUESTER cannot read, list or count (403)' "$((Invoke-Api GET "$inv/$resource/retrieve" $asRequester).Status)/$((Invoke-Api GET "$inv/retrieve" $asRequester).Status)/$((Invoke-Api GET "$inv/summary/retrieve" $asRequester).Status)" '403/403/403'
Assert-Equal 'another tenant gets a 404 for the resource, finds none and counts none' "$((Invoke-Api GET "$inv/$resource/retrieve" $otherTenant).Status)/$(Count "$inv/retrieve" $otherTenant)/$((Invoke-Api GET "$inv/summary/retrieve" $otherTenant).Body.total)" '404/0/0'
$deleted = (Invoke-Api DELETE "$inv/$resource" $staff).Status
Assert-Equal 'there is no delete (404 or 405)' ($deleted -eq 404 -or $deleted -eq 405) $true

# 7. The ledger.
$recorded = 0; $entries = @()
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body)
    $recorded = @($entries | Where-Object { $_.resourceType -eq 'it-cloud-inventory' }).Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.resourceType -eq 'it-cloud-inventory' -and $_.detail -eq 'status=403' }).Count -ge 1) $true
$ledgerText = $entries | ConvertTo-Json -Depth 6
Assert-Equal 'nothing anyone said is on the ledger' (($ledgerText -like '*hunter2*') -or ($ledgerText -like '*ana-secret*')) $false
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Cloud inventory smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
