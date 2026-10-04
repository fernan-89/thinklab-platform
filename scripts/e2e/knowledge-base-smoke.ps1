<#
.SYNOPSIS
  Live proof of Journey 12, fourth service: the knowledge base through the platform gateway (knowledge-base ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8101, routes it through the gateway and turns the ledger recording on). Uses
  its own tenant id (the service takes any UUID), then drives, through the GATEWAY:
    (1) an article is drafted by an author and linked to a REAL problem (opened on the problem service); it is found from the article
        side by problem, by keyword and by free text (MongoDB text index), and never across tenants;
    (2) the review: the author cannot publish or return their own article, a return needs a comment, a returned article is edited and
        resubmitted, and a different reviewer publishes it;
    (3) versions: a new version is a new draft with the same key, a second one at the same time is refused, and publishing it retires
        the first as SUPERSEDED while nothing was served in between;
    (4) the two audiences: a REQUESTER reads only published public articles (internal, draft and retired ones answer 404), without the
        people and links, searches only inside that set, and is refused on every staff route;
    (5) two reviewers publishing and returning the same article at the same instant: exactly one wins;
    (6) every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\knowledge-base-smoke.ps1
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
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null } }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

$knb = "$GatewayUrl/it-knowledge-base/v1"
$prb = "$GatewayUrl/it-problem-management/v1"
$tenantId = [guid]::NewGuid().ToString()
$author = 'author-' + [guid]::NewGuid().ToString(); $reviewer = 'reviewer-' + [guid]::NewGuid().ToString(); $reviewer2 = 'reviewer-' + [guid]::NewGuid().ToString()
$user = [guid]::NewGuid().ToString()
function As([string]$Who) { @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $Who } }
$asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $user; 'X-Role' = 'REQUESTER' }
function Get-Article([string]$Id) { (Invoke-Api GET "$knb/$Id/retrieve" (As $author)).Body }
function Ids($List) { (@($List | ForEach-Object { $_.id }) -join ',') }
function Draft([string]$Title, [string]$Body, [string]$Visibility, [string[]]$Keywords, [string[]]$Problems = @()) {
    Invoke-Api POST "$knb/initiate" (As $author) @{ title = $Title; body = $Body; category = 'NETWORK'; keywords = $Keywords; visibility = $Visibility; relatedProblemIds = $Problems }
}
function Publish([string]$Id) {
    [void](Invoke-Api PUT "$knb/$Id/control/submit" (As $author))
    (Invoke-Api PUT "$knb/$Id/control/publish" (As $reviewer)).Status
}

# 1. An article that explains a real problem, and finding it.
$problem = Invoke-Api POST "$prb/initiate" (As $author) @{ title = 'Switch drops packets'; description = 'Intermittent loss on floor 3'; priority = 'P2' }
$problemId = $problem.Body.id
Assert-Equal 'a problem is opened on the problem service' $problem.Status 201
$drafted = Draft 'Switch drops packets' 'Reboot the switch every Sunday' 'PUBLIC' @('Switch', ' Firmware ') @($problemId)
$id = $drafted.Body.id; $key = $drafted.Body.articleKey
Assert-Equal 'an author drafts an article: 201, DRAFT, version 1, the key is its own id' "$($drafted.Status)/$($drafted.Body.status)/$($drafted.Body.version)/$($key -eq $id)" '201/DRAFT/1/True'
Assert-Equal 'keywords are normalised (trimmed, lower-cased) and the author is the caller' "$((@($drafted.Body.keywords) | Sort-Object) -join ',')/$($drafted.Body.authorId -eq $author)" 'firmware,switch/True'
Assert-Equal 'a blank title is refused (400)' (Invoke-Api POST "$knb/initiate" (As $author) @{ title = ''; body = 'b'; visibility = 'PUBLIC' }).Status 400
Assert-Equal 'a missing visibility is refused (400)' (Invoke-Api POST "$knb/initiate" (As $author) @{ title = 't'; body = 'b' }).Status 400
Assert-Equal 'the tenant is mandatory on every route (400)' (Invoke-Api GET "$knb/$id/retrieve" @{ 'X-Executor' = $author }).Status 400
Assert-Equal 'what do we know about this problem is answered from the article side' (Ids (Invoke-Api GET "$knb/retrieve?problemId=$problemId" (As $author)).Body) $id
Assert-Equal 'the problem service is untouched by the link (still NEW)' (Invoke-Api GET "$prb/$problemId/retrieve" (As $author)).Body.status 'NEW'
Assert-Equal 'a keyword finds it whatever its case' (Ids (Invoke-Api GET "$knb/retrieve?keyword=FIRMWARE" (As $author)).Body) $id
Assert-Equal 'the text search finds it by a word of its body' (Ids (Invoke-Api GET "$knb/retrieve?q=Sunday" (As $author)).Body) $id
Assert-Equal 'and by a word of its title' (Ids (Invoke-Api GET "$knb/retrieve?q=packets" (As $author)).Body) $id
Assert-Equal 'a word that is nowhere finds nothing' (@((Invoke-Api GET "$knb/retrieve?q=nonexistentterm" (As $author)).Body).Count) 0
Assert-Equal 'another tenant finds nothing by the same word' (@((Invoke-Api GET "$knb/retrieve?q=Sunday" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $author }).Body).Count) 0

# 2. The review.
Assert-Equal 'update the draft' (Invoke-Api PUT "$knb/$id/update" (As $author) @{ title = 'Switch drops packets'; body = 'Reboot the switch every Sunday after the firmware leak'; category = 'NETWORK'; keywords = @('switch', 'firmware'); visibility = 'PUBLIC'; relatedProblemIds = @($problemId) }).Status 204
Assert-Equal 'submit for review' (Invoke-Api PUT "$knb/$id/control/submit" (As $author)).Status 204
Assert-Equal 'an article in review takes no edit (409)' (Invoke-Api PUT "$knb/$id/update" (As $author) @{ title = 't'; body = 'b'; visibility = 'PUBLIC' }).Status 409
$self = Invoke-Api PUT "$knb/$id/control/publish" (As $author)
Assert-Equal 'the author cannot publish their own article (409 ERR-KNB-00409)' "$($self.Status)/$($self.Body.error_code)" '409/ERR-KNB-00409'
Assert-Equal 'nor return it (409)' (Invoke-Api PUT "$knb/$id/control/return" (As $author) @{ comment = 'fine' }).Status 409
Assert-Equal 'a return needs a comment (400)' (Invoke-Api PUT "$knb/$id/control/return" (As $reviewer) @{ comment = '' }).Status 400
Assert-Equal 'the reviewer returns it with a comment' (Invoke-Api PUT "$knb/$id/control/return" (As $reviewer) @{ comment = 'Say which firmware version leaks' }).Status 204
$returned = Get-Article $id
Assert-Equal 'it is a DRAFT again, with the comment and the reviewer' "$($returned.status)/$($returned.reviewComment)/$($returned.reviewerId -eq $reviewer)" "DRAFT/Say which firmware version leaks/True"
Assert-Equal 'the author fixes it' (Invoke-Api PUT "$knb/$id/update" (As $author) @{ title = 'Switch drops packets'; body = 'Firmware 2.1 leaks buffers: reboot the switch every Sunday'; category = 'NETWORK'; keywords = @('switch', 'firmware'); visibility = 'PUBLIC'; relatedProblemIds = @($problemId) }).Status 204
Assert-Equal 'submits again' (Invoke-Api PUT "$knb/$id/control/submit" (As $author)).Status 204
Assert-Equal 'a different reviewer publishes it' (Invoke-Api PUT "$knb/$id/control/publish" (As $reviewer)).Status 204
$publishedOne = Get-Article $id
Assert-Equal 'PUBLISHED, with its date, the old comment cleared' "$($publishedOne.status)/$([bool]$publishedOne.publishedAt)/$([bool]$publishedOne.reviewComment)" 'PUBLISHED/True/False'

# 3. Versions.
$v2 = Invoke-Api POST "$knb/$id/version/initiate" (As $reviewer)
$v2Id = $v2.Body.id
Assert-Equal 'a new version is a new draft of the same key, authored by who asked' "$($v2.Status)/$($v2.Body.version)/$($v2.Body.status)/$($v2.Body.articleKey -eq $key)/$($v2.Body.authorId -eq $reviewer)" '201/2/DRAFT/True/True'
Assert-Equal 'the published version keeps serving meanwhile' (Get-Article $id).status 'PUBLISHED'
Assert-Equal 'a second new version of the same article at the same time is refused (409)' (Invoke-Api POST "$knb/$id/version/initiate" (As $author)).Status 409
Assert-Equal 'a DRAFT has no new version (409)' (Invoke-Api POST "$knb/$v2Id/version/initiate" (As $author)).Status 409
Assert-Equal 'the author of version 2 submits it' (Invoke-Api PUT "$knb/$v2Id/control/submit" (As $reviewer)).Status 204
Assert-Equal 'the author of version 1 publishes version 2 (allowed: they did not write it)' (Invoke-Api PUT "$knb/$v2Id/control/publish" (As $author)).Status 204
$versions = @((Invoke-Api GET "$knb/$id/versions/retrieve" (As $author)).Body)
Assert-Equal 'version 1 is retired and version 2 serves, oldest first' "$(($versions | ForEach-Object { $_.version }) -join ',')/$(($versions | ForEach-Object { $_.status }) -join ',')" '1,2/RETIRED,PUBLISHED'
Assert-Equal 'version 1 trail tells the story, ending as SUPERSEDED' ((@((Invoke-Api GET "$knb/$id/audit-log/retrieve" (As $author)).Body | ForEach-Object { $_.action })) -join ',') 'INITIATED,UPDATED,SUBMITTED,RETURNED,UPDATED,SUBMITTED,PUBLISHED,SUPERSEDED'
Assert-Equal 'a search finds only the serving version' (Ids (Invoke-Api GET "$knb/retrieve?q=Sunday&status=PUBLISHED" (As $author)).Body) $v2Id

# 4. The two audiences.
$internal = Draft 'Core router credentials rotation' 'Rotate through the vault, never by email' 'INTERNAL' @('router')
$internalId = $internal.Body.id
Assert-Equal 'an INTERNAL article is published' (Publish $internalId) 204
$seen = Invoke-Api GET "$knb/$v2Id/retrieve" $asRequester
Assert-Equal 'a REQUESTER reads the published public article' "$($seen.Status)/$($seen.Body.status)" '200/PUBLISHED'
Assert-Equal 'without the people, the review comment and the links' "$([bool]$seen.Body.authorId)/$([bool]$seen.Body.reviewerId)/$([bool]$seen.Body.relatedProblemIds)" 'False/False/False'
Assert-Equal 'a REQUESTER cannot read an INTERNAL article even published (404)' (Invoke-Api GET "$knb/$internalId/retrieve" $asRequester).Status 404
Assert-Equal 'nor a retired version (404)' (Invoke-Api GET "$knb/$id/retrieve" $asRequester).Status 404
$draftOnly = (Draft 'Not ready' 'Still a draft' 'PUBLIC' @()).Body.id
Assert-Equal 'nor a draft (404)' (Invoke-Api GET "$knb/$draftOnly/retrieve" $asRequester).Status 404
Assert-Equal 'a REQUESTER searches only inside the published public set, whatever they ask' (Ids (Invoke-Api GET "$knb/retrieve?status=DRAFT&visibility=INTERNAL&authorId=$author" $asRequester).Body) $v2Id
Assert-Equal 'staff see more than a REQUESTER does' (@((Invoke-Api GET "$knb/retrieve" (As $author)).Body).Count -gt @((Invoke-Api GET "$knb/retrieve" $asRequester).Body).Count) $true
$denied = Invoke-Api POST "$knb/initiate" $asRequester @{ title = 't'; body = 'b'; visibility = 'PUBLIC' }
Assert-Equal 'a REQUESTER cannot write (403 ERR-KNB-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-KNB-00403'
Assert-Equal 'cannot publish (403)' (Invoke-Api PUT "$knb/$v2Id/control/publish" $asRequester).Status 403
Assert-Equal 'cannot retire (403)' (Invoke-Api PUT "$knb/$v2Id/control/retire" $asRequester).Status 403
Assert-Equal 'cannot start a version (403)' (Invoke-Api POST "$knb/$v2Id/version/initiate" $asRequester).Status 403
Assert-Equal 'cannot read the versions (403)' (Invoke-Api GET "$knb/$v2Id/versions/retrieve" $asRequester).Status 403
Assert-Equal 'cannot read the audit trail (403)' (Invoke-Api GET "$knb/$v2Id/audit-log/retrieve" $asRequester).Status 403
Assert-Equal 'staff retire the internal article' (Invoke-Api PUT "$knb/$internalId/control/retire" (As $author)).Status 204
Assert-Equal 'a retired article takes no new version (409)' (Invoke-Api POST "$knb/$internalId/version/initiate" (As $author)).Status 409
Assert-Equal 'another tenant gets a 404 for the article' (Invoke-Api GET "$knb/$v2Id/retrieve" @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $author }).Status 404

# 5. A race: two reviewers decide the same article at the same instant.
$raced = (Draft 'Race' 'Two reviewers' 'PUBLIC' @()).Body.id
Assert-Equal 'the racing article is in review' (Invoke-Api PUT "$knb/$raced/control/submit" (As $author)).Status 204
$decide = {
    param($url, $tenant, $executor, $body)
    try {
        $p = @{ Method = 'PUT'; Uri = $url; UseBasicParsing = $true; Headers = @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor } }
        if ($body) { $p.ContentType = 'application/json'; $p.Body = $body }
        [int](Invoke-WebRequest @p).StatusCode
    } catch { [int]$_.Exception.Response.StatusCode }
}
$jobs = @((Start-Job -ScriptBlock $decide -ArgumentList "$knb/$raced/control/publish", $tenantId, $reviewer, $null),
          (Start-Job -ScriptBlock $decide -ArgumentList "$knb/$raced/control/return", $tenantId, $reviewer2, '{"comment":"Not yet"}'))
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'exactly one reviewer wins and the other is told 409, never both and never an error' ((@($codes | Sort-Object)) -join ',') '204,409'
Assert-Equal 'the article ends in the state of the winner' (@('PUBLISHED', 'DRAFT') -contains (Get-Article $raced).status) $true
Assert-Equal 'the audit trail holds the opening, the submission and exactly the winning move' @((Invoke-Api GET "$knb/$raced/audit-log/retrieve" (As $author)).Body).Count 3
Assert-Equal 'a delete is not a thing (404 or 405)' (@(404, 405) -contains (Invoke-Api DELETE "$knb/$id" (As $author)).Status) $true

# 6. The ledger.
$ledger = "$LedgerUrl/compliance-audit-ledger/v1"
$recorded = 0
for ($i = 0; $i -lt 20; $i++) {
    $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-knowledge-base' })
    $recorded = $entries.Count
    if ($recorded -ge 30) { break }
    Start-Sleep -Milliseconds 500
}
Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 30) $true
Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Knowledge base smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
