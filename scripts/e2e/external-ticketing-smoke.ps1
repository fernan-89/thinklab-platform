<#
.SYNOPSIS
  Live proof of Journey 12, fifth service: the ServiceNow and Jira connector through the platform gateway (connector ADR-030..033).

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1 starts it on 8102, routes it through the gateway, turns the ledger recording on and sets the
  environment variables the connections name). The script starts the ticketing double (mock-ticketing.mjs, Node built-ins only: a Jira and
  a ServiceNow in one process that CALLS the webhook for what an API call changes, like the real ones) when nothing listens on its port.
  Uses its own tenant id, then drives, through the GATEWAY:
    (1) a connection is registered: it names environment variables and never holds a secret; an unsafe address, bad variable names and a
        duplicate name are refused; the check proves the credentials work, and says so when a variable is not set;
    (2) a REAL incident is linked to a Jira ticket: the ticket is created from it, a second link is refused, an unknown incident is a 404;
    (3) platform -> provider: its status and its PUBLIC comments reach the ticket (the internal note does not), nothing is sent twice, and
        the provider's calls back for the integration's own pushes are recognised and ignored;
    (4) provider -> platform: a person moves the ticket and the incident follows, as the integration identity; a comment arrives as an
        INTERNAL note a requester cannot read; the same event delivered five times is applied once;
    (5) the platform wins: a provider status the incident refuses is a recorded conflict, the incident is untouched, and the webhook still answers 200;
    (6) the webhook proves its caller (a wrong or missing token is 401, an unknown connection 404);
    (7) a ServiceNow connection and a REAL problem: the state codes, the platform refusing a resolve with no root cause, and an action a problem does not model;
    (8) a provider that is down or refuses leaves the link FAILED, never echoes its body, and a sync retries it;
    (9) a disabled connection accepts and sends nothing; a detached link is no longer followed;
   (10) staff only (a REQUESTER gets 403), another tenant gets a 404, two people linking the same item at once: exactly one ticket;
   (11) no secret appears in any answer, and every mutation, including the refused ones, is recorded on the ledger.

    powershell -File .\external-ticketing-smoke.ps1
#>
param(
    [string]$GatewayUrl = 'http://localhost:8088',
    [string]$LedgerUrl = 'http://localhost:8094',
    [string]$TicketingUrl = 'http://localhost:9100',
    [string]$TicketingInternalUrl = '',
    [string]$WebhookBaseUrl = '',
    [string]$NodeExe = (Join-Path $PSScriptRoot '..\..\..\tools\node\node.exe')
)

$ErrorActionPreference = 'Stop'
if (-not $TicketingInternalUrl) { $TicketingInternalUrl = $TicketingUrl }
if (-not $WebhookBaseUrl) { $WebhookBaseUrl = $GatewayUrl }
$results = New-Object System.Collections.ArrayList
$everything = New-Object System.Text.StringBuilder

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 8 }
    try {
        $r = Invoke-WebRequest @p
        [void]$everything.Append($r.Content)
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }; Raw = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        $text = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message }
                elseif ($resp) { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } else { '' }
        [void]$everything.Append($text)
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = if ($text) { try { $text | ConvertFrom-Json } catch { $null } } else { $null }; Raw = $text }
    }
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    $ok = ("$Actual" -eq "$Expected")
    if (-not $ok) { Write-Output ("  {0} -> expected [{1}], got [{2}]" -f $Name, $Expected, $Actual) }
    [void]$results.Add([pscustomobject]@{ Check = $Name; Expected = $Expected; Actual = $Actual; Result = if ($ok) { 'PASS' } else { 'FAIL' } })
}

function Merge-Body([hashtable]$Base, [hashtable]$Over) { $copy = $Base.Clone(); foreach ($k in $Over.Keys) { $copy[$k] = $Over[$k] }; return $copy }

function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 300 }
    return [bool](& $Condition)
}

# ---- The ticketing double ------------------------------------------------------------------------------------------------------
$mockProcess = $null
$mockPort = ([uri]$TicketingUrl).Port
function Test-MockUp { try { [void](Invoke-WebRequest -Uri "$TicketingUrl/__mock/state" -UseBasicParsing -TimeoutSec 2); return $true } catch { return $false } }
if (-not (Test-MockUp)) {
    $env:MOCK_TICKETING_PORT = "$mockPort"
    $env:MOCK_TICKETING_JIRA_AUTH = 'Basic bW9jay1qaXJhOm1vY2s='
    $env:MOCK_TICKETING_SNOW_AUTH = 'Basic bW9jay1zbm93Om1vY2s='
    $mockProcess = Start-Process -FilePath $NodeExe -ArgumentList (Join-Path $PSScriptRoot 'mock-ticketing.mjs') -PassThru -WindowStyle Hidden
    if (-not (Wait-Until { Test-MockUp } 15)) { throw 'the ticketing double did not start' }
}
function Mock([string]$Method, [string]$Path, $Body = $null) {
    $p = @{ Method = $Method; Uri = "$TicketingUrl$Path"; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 6 }
    $r = Invoke-WebRequest @p
    return $r.Content | ConvertFrom-Json
}
function Mock-State { Mock GET '/__mock/state' }

try {
    [void](Mock POST '/__mock/reset')
    $ext = "$GatewayUrl/it-external-ticketing/v1"
    $inc = "$GatewayUrl/it-incident-management/v1"
    $prb = "$GatewayUrl/it-problem-management/v1"
    $tenantId = [guid]::NewGuid().ToString()
    $staffUser = [guid]::NewGuid().ToString(); $staffUser2 = [guid]::NewGuid().ToString(); $filedFor = [guid]::NewGuid().ToString(); $assetId = [guid]::NewGuid().ToString()
    $staff = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $staffUser }
    $asRequester = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = $filedFor; 'X-Role' = 'REQUESTER' }
    $otherTenant = @{ 'X-Tenant-Id' = [guid]::NewGuid().ToString(); 'X-Executor' = $staffUser }
    $jiraAuthValue = 'bW9jay1qaXJhOm1vY2s='; $jiraHookValue = 'mock-jira-webhook-token'; $snowAuthValue = 'bW9jay1zbm93Om1vY2s='; $snowHookValue = 'mock-snow-webhook-token'

    function New-Incident([string]$Title = 'Printer on floor 3 is down') {
        (Invoke-Api POST "$inc/initiate" $staff @{ title = $Title; description = 'Nothing prints since morning'; impact = 'MEDIUM'; urgency = 'MEDIUM'; requesterId = $filedFor; affectedAssetIds = @($assetId) }).Body.id
    }
    function Get-Incident([string]$Id) { (Invoke-Api GET "$inc/$Id/retrieve" $staff).Body }
    function Get-Link([string]$Id) { (Invoke-Api GET "$ext/$Id/retrieve" $staff).Body }
    function Link-Actions([string]$Id) { (@((Invoke-Api GET "$ext/$Id/audit-log/retrieve" $staff).Body | ForEach-Object { $_.action }) -join ',') }
    function Link-Of([string]$ConnectionId, [string]$Type, [string]$SubjectId) {
        Invoke-Api POST "$ext/initiate" $staff @{ connectionId = $ConnectionId; subjectType = $Type; subjectId = $SubjectId }
    }
    function Event([string]$Product, [string]$Id, $Status, $Comment, [string]$Actor, [int]$Repeat = 1) {
        $body = @{ product = $Product; id = $Id; actor = $Actor; repeat = $Repeat }
        if ($null -ne $Status) { $body.status = $Status }
        if ($null -ne $Comment) { $body.comment = $Comment }
        (Mock POST '/__mock/event' $body).deliveries
    }

    # 1. A connection that names its secrets.
    $jiraBody = @{ name = 'Jira prod'; provider = 'JIRA'; baseUrl = "$TicketingInternalUrl/jira"; secretRef = 'THINKLAB_MOCK_JIRA_AUTH'; webhookSecretRef = 'THINKLAB_MOCK_JIRA_HOOK'; integrationActor = 'svc-thinklab'; projectKey = 'ITSM' }
    $made = Invoke-Api POST "$ext/connection/initiate" $staff $jiraBody
    $jira = $made.Body.id
    Assert-Equal 'staff register a Jira connection: 201, ACTIVE, project ITSM' "$($made.Status)/$($made.Body.status)/$($made.Body.projectKey)" '201/ACTIVE/ITSM'
    Assert-Equal 'it names the variables and says they are set, and holds no secret' "$($made.Body.secretRef)/$($made.Body.secretConfigured)/$($made.Body.webhookSecretConfigured)" 'THINKLAB_MOCK_JIRA_AUTH/True/True'
    Assert-Equal 'the default maps were filled in' "$($made.Body.outboundStatus.RESOLVED)/$($made.Body.inboundActions.Done)" 'Done/RESOLVE'
    Assert-Equal 'the same name again is a duplicate (409)' (Invoke-Api POST "$ext/connection/initiate" $staff $jiraBody).Status 409
    Assert-Equal 'a plain http address that is not on the test list is refused (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x1'; baseUrl = 'http://example.com' })).Status 400
    Assert-Equal 'a link-local address is refused (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x2'; baseUrl = 'https://169.254.169.254' })).Status 400
    Assert-Equal 'a private address is refused (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x3'; baseUrl = 'https://10.0.0.5' })).Status 400
    Assert-Equal 'a secret name that is not a variable name is refused (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x4'; secretRef = 'Basic abc123' })).Status 400
    Assert-Equal 'the two variables must differ (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x5'; webhookSecretRef = 'THINKLAB_MOCK_JIRA_AUTH' })).Status 400
    Assert-Equal 'a Jira connection needs its project key (400)' (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'x6'; projectKey = '' })).Status 400
    Assert-Equal 'the tenant is mandatory (400)' (Invoke-Api GET "$ext/connection/$jira/retrieve" @{ 'X-Executor' = $staffUser }).Status 400
    $check = (Invoke-Api PUT "$ext/connection/$jira/check/execute" $staff).Body
    Assert-Equal 'the check proves the credentials work against the provider' "$($check.reachable)/$($check.secretConfigured)" 'True/True'
    $unsetBody = Merge-Body $jiraBody @{ name = 'Unset secret'; secretRef = 'THINKLAB_NOT_SET_ANYWHERE' }
    $unset = (Invoke-Api POST "$ext/connection/initiate" $staff $unsetBody).Body
    $unsetCheck = (Invoke-Api PUT "$ext/connection/$($unset.id)/check/execute" $staff).Body
    Assert-Equal 'a variable that is not set is reported, and the provider is not called' "$($unsetCheck.secretConfigured)/$($unsetCheck.reachable)" 'False/False'
    [void](Mock POST '/__mock/register' @{ product = 'jira'; webhookUrl = "$WebhookBaseUrl/it-external-ticketing/v1/webhook/$jira/receive"; token = $jiraHookValue; actor = 'svc-thinklab' })

    # 2. A real incident linked to a Jira ticket.
    $incidentId = New-Incident
    $linked = Link-Of $jira 'INCIDENT' $incidentId
    $linkId = $linked.Body.id
    $key = $linked.Body.externalId
    Assert-Equal 'linking creates the ticket: 201, LINKED, with its key' "$($linked.Status)/$($linked.Body.status)/$([bool]$key)" '201/LINKED/True'
    $issue = (Mock-State).jira.issues.$key
    Assert-Equal 'the ticket was created from the incident (its title, in the project, typed Incident)' "$($issue.summary)/$($issue.project)/$($issue.type)" 'Printer on floor 3 is down/ITSM/Incident'
    Assert-Equal 'the ticket starts To Do, as the incident is NEW' $issue.status 'To Do'
    Assert-Equal 'linking the same item to the same connection again is a duplicate (409)' (Link-Of $jira 'INCIDENT' $incidentId).Status 409
    Assert-Equal 'an incident that does not exist is a 404' (Link-Of $jira 'INCIDENT' ([guid]::NewGuid().ToString())).Status 404
    Assert-Equal 'a link is found from the item side' (@((Invoke-Api GET "$ext/retrieve?subjectId=$incidentId&subjectType=INCIDENT" $staff).Body).Count) 1

    # 3. Platform -> provider.
    Assert-Equal 'acknowledge the incident' (Invoke-Api PUT "$inc/$incidentId/control/acknowledge" $staff).Status 204
    $synced = Invoke-Api PUT "$ext/$linkId/sync/execute" $staff
    Assert-Equal 'sync records the status as pushed' "$($synced.Status)/$($synced.Body.lastPushedStatus)/$($synced.Body.lastDirection)" '200/ACKNOWLEDGED/OUTBOUND'
    Assert-Equal 'the ticket needed no move (To Do is where it is)' (Mock-State).jira.issues.$key.transitions 0
    [void](Invoke-Api POST "$inc/$incidentId/comment/initiate" $staff @{ text = 'We are looking into it'; internal = $false })
    [void](Invoke-Api POST "$inc/$incidentId/comment/initiate" $staff @{ text = 'Internal: the vendor is slow'; internal = $true })
    [void](Invoke-Api PUT "$ext/$linkId/sync/execute" $staff)
    $commentsAtProvider = @((Mock-State).jira.issues.$key.comments | ForEach-Object { $_.body })
    Assert-Equal 'only the PUBLIC comment reached the ticket' ($commentsAtProvider -join '|') 'We are looking into it'
    [void](Invoke-Api PUT "$ext/$linkId/sync/execute" $staff)
    Assert-Equal 'a second sync sends nothing twice' @((Mock-State).jira.issues.$key.comments).Count 1
    Assert-Equal 'the link remembers the pushed comment' (Get-Link $linkId).syncedComments 1
    Assert-Equal 'start work, then resolve on the platform' ((Invoke-Api PUT "$inc/$incidentId/control/start" $staff).Status) 204
    Assert-Equal 'the incident is resolved' (Invoke-Api PUT "$inc/$incidentId/control/resolve" $staff @{ resolutionCode = 'REPLACED_TONER'; notes = 'Toner replaced' }).Status 204
    [void](Invoke-Api PUT "$ext/$linkId/sync/execute" $staff)
    Assert-Equal 'the ticket moved to Done through its transition' (Mock-State).jira.issues.$key.status 'Done'
    Assert-Equal 'the provider called the webhook for what the integration did, and every one was recognised as its own and ignored' `
        (Wait-Until { $d = @((Mock-State).deliveries | Where-Object { $_.product -eq 'jira' }); ($d.Count -ge 2) -and (@($d | Where-Object { $_.outcome -ne 'IGNORED_OWN_EVENT' }).Count -eq 0) }) $true
    Assert-Equal 'the incident was not touched by those echoes (still RESOLVED)' (Get-Incident $incidentId).status 'RESOLVED'

    # 4. Provider -> platform.
    $second = New-Incident 'VPN drops every hour'
    $secondLink = (Link-Of $jira 'INCIDENT' $second).Body
    $secondKey = $secondLink.externalId
    [void](Invoke-Api PUT "$inc/$second/control/acknowledge" $staff)
    $moved = Event 'jira' $secondKey 'In Progress' $null 'alice'
    Assert-Equal 'a person moves the ticket to In Progress: the webhook is applied' "$($moved[0].status)/$($moved[0].outcome)" '200/APPLIED'
    $followed = Get-Incident $second
    Assert-Equal 'the incident followed: IN_PROGRESS' $followed.status 'IN_PROGRESS'
    $ackTrail = @((Invoke-Api GET "$inc/$second/audit-log/retrieve" $staff).Body | Where-Object { $_.action -eq 'WORK_STARTED' })
    Assert-Equal 'the move is attributed to the integration identity in the incident audit trail' $ackTrail[0].executor "external-ticketing:$jira"
    $afterMove = Get-Link $secondLink.id
    Assert-Equal 'the link remembers it as the last status, and that it came in' "$($afterMove.lastPushedStatus)/$($afterMove.lastDirection)" 'IN_PROGRESS/INBOUND'
    $callsBefore = @((Mock-State).calls).Count
    [void](Invoke-Api PUT "$ext/$($secondLink.id)/sync/execute" $staff)
    Assert-Equal 'a sync right after pushes nothing back (no echo of the provider status)' (Mock-State).jira.issues.$secondKey.transitions 0
    $comment = Event 'jira' $secondKey $null 'Please send the logs' 'alice' 5
    Assert-Equal 'the same event delivered 5 times: applied once, the other four are duplicates' "$($comment[0].outcome)/$(@($comment | Where-Object { $_.outcome -eq 'DUPLICATE' }).Count)" 'APPLIED/4'
    $notes = @((Get-Incident $second).comments | Where-Object { $_.text -like '*Please send the logs*' })
    Assert-Equal 'the comment is on the incident exactly once, as an INTERNAL note naming its origin' "$($notes.Count)/$($notes[0].internal)/$($notes[0].text)" "1/True/[Jira $secondKey] Please send the logs"
    $seenByRequester = (Invoke-Api GET "$inc/$second/retrieve" $asRequester).Body
    Assert-Equal 'the requester cannot read it' @($seenByRequester.comments | Where-Object { $_.text -like '*Please send the logs*' }).Count 0
    Assert-Equal 'a status nobody mapped, with no comment, has nothing to apply' (Event 'jira' $secondKey 'Waiting for customer' $null 'alice')[0].outcome 'NOTHING_TO_APPLY'
    Assert-Equal 'the ticket moved by the person, then Done: the incident resolves' (Event 'jira' $secondKey 'Done' $null 'alice')[0].outcome 'APPLIED'
    $done = Get-Incident $second
    Assert-Equal 'RESOLVED, with the code the integration chose' "$($done.status)/$($done.resolutionCode)" 'RESOLVED/RESOLVED_EXTERNALLY'
    Assert-Equal 'the audit trail of the link tells the story in order' (Link-Actions $secondLink.id) 'INITIATED,TICKET_CREATED,SYNCED_IN,SYNCED_IN,SYNCED_IN'

    # 5. The platform wins.
    $conflict = Event 'jira' $key 'Cancelled' $null 'alice'
    Assert-Equal 'a cancel the resolved incident refuses is a conflict the platform wins, still answered 200' "$($conflict[0].status)/$($conflict[0].outcome)" '200/CONFLICT_PLATFORM_WINS'
    Assert-Equal 'the incident is untouched (still RESOLVED)' (Get-Incident $incidentId).status 'RESOLVED'
    $conflicted = Get-Link $linkId
    Assert-Equal 'the conflict is recorded on the link, which stays LINKED' "$($conflicted.status)/$([bool]$conflicted.lastError)" 'LINKED/True'
    Assert-Equal 'and in its audit trail' ((Link-Actions $linkId) -like '*INBOUND_CONFLICT*') $true

    # 6. The webhook proves its caller.
    $hook = "$ext/webhook/$jira/receive"
    $payload = @{ webhookEvent = 'jira:issue_updated'; timestamp = 1; issue = @{ key = $key }; user = @{ accountId = 'mallory' }; changelog = @{ items = @(@{ field = 'status'; toString = 'Cancelled' }) } }
    Assert-Equal 'no token: 401 ERR-ETK-00401' "$((Invoke-Api POST $hook @{} $payload).Status)/$((Invoke-Api POST $hook @{} $payload).Body.error_code)" '401/ERR-ETK-00401'
    Assert-Equal 'a wrong token: 401' (Invoke-Api POST $hook @{ 'X-Webhook-Token' = 'guess' } $payload).Status 401
    Assert-Equal 'an unknown connection: 404' (Invoke-Api POST "$ext/webhook/$([guid]::NewGuid())/receive" @{ 'X-Webhook-Token' = $jiraHookValue } $payload).Status 404
    Assert-Equal 'a payload that is not a Jira one is refused (400)' (Invoke-Api POST $hook @{ 'X-Webhook-Token' = $jiraHookValue } @{ nothing = 'here' }).Status 400
    Assert-Equal 'the right token needs no tenant and no role' (Invoke-Api POST $hook @{ 'X-Webhook-Token' = $jiraHookValue } $payload).Status 200

    # 7. ServiceNow and a real problem.
    $snowBody = @{ name = 'ServiceNow prod'; provider = 'SERVICENOW'; baseUrl = "$TicketingInternalUrl/snow"; secretRef = 'THINKLAB_MOCK_SNOW_AUTH'; webhookSecretRef = 'THINKLAB_MOCK_SNOW_HOOK'; integrationActor = 'svc.thinklab' }
    $snow = (Invoke-Api POST "$ext/connection/initiate" $staff $snowBody).Body.id
    [void](Mock POST '/__mock/register' @{ product = 'snow'; webhookUrl = "$WebhookBaseUrl/it-external-ticketing/v1/webhook/$snow/receive"; token = $snowHookValue; actor = 'svc.thinklab' })
    $problem = (Invoke-Api POST "$prb/initiate" $staff @{ title = 'Switch drops packets'; description = 'Intermittent'; priority = 'P2'; relatedIncidentIds = @($incidentId); affectedAssetIds = @($assetId) }).Body.id
    $problemLink = (Link-Of $snow 'PROBLEM' $problem).Body
    $record = (Mock-State).snow.records.($problemLink.externalId)
    Assert-Equal 'a ServiceNow row of the problem table was created, with the platform item as its correlation id' "$($problemLink.status)/$($record.table)/$($record.correlation_id)/$($record.state)" "LINKED/problem/$problem/1"
    [void](Invoke-Api PUT "$prb/$problem/control/investigate" $staff)
    [void](Invoke-Api PUT "$ext/$($problemLink.id)/sync/execute" $staff)
    Assert-Equal 'investigating moved the row to state 2' (Mock-State).snow.records.($problemLink.externalId).state '2'
    $early = Event 'snow' $problemLink.externalId '6' $null 'bob'
    Assert-Equal 'ServiceNow says resolved but the problem has no root cause: the platform refuses, a recorded conflict' "$($early[0].status)/$($early[0].outcome)" '200/CONFLICT_PLATFORM_WINS'
    Assert-Equal 'the problem is still under investigation' (Invoke-Api GET "$prb/$problem/retrieve" $staff).Body.status 'UNDER_INVESTIGATION'
    [void](Invoke-Api PUT "$prb/$problem/analysis/update" $staff @{ rootCause = 'Firmware 2.1 leaks buffers' })
    $late = Event 'snow' $problemLink.externalId '6' 'Fixed it' 'bob'
    Assert-Equal 'with the root cause on record the same state is applied, comment included' "$($late[0].outcome)" 'APPLIED'
    $solved = (Invoke-Api GET "$prb/$problem/retrieve" $staff).Body
    Assert-Equal 'the problem is RESOLVED, with the resolution the integration wrote' "$($solved.status)/$($solved.resolution)" "RESOLVED/Resolved in ServiceNow ($($problemLink.externalId))"
    Assert-Equal 'a problem has no public comments: the one from the provider is an internal staff note' (@($solved.comments | Where-Object { $_.text.StartsWith('[ServiceNow') }).Count) 1
    $snowUpdate = @{ name = 'ServiceNow prod'; baseUrl = "$TicketingInternalUrl/snow"; secretRef = 'THINKLAB_MOCK_SNOW_AUTH'; webhookSecretRef = 'THINKLAB_MOCK_SNOW_HOOK'; integrationActor = 'svc.thinklab'; inboundActions = @{ '9' = 'ACKNOWLEDGE'; '6' = 'RESOLVE' } }
    Assert-Equal 'staff change the inbound map of the connection' (Invoke-Api PUT "$ext/connection/$snow/update" $staff $snowUpdate).Status 204
    $other = (Invoke-Api POST "$prb/initiate" $staff @{ title = 'Second problem'; description = 'd'; priority = 'P3' }).Body.id
    $otherLink = (Link-Of $snow 'PROBLEM' $other).Body
    $unsupported = Event 'snow' $otherLink.externalId '9' $null 'bob'
    Assert-Equal 'an action a problem does not model is a conflict, never forced' "$($unsupported[0].outcome)" 'CONFLICT_PLATFORM_WINS'
    Assert-Equal 'and says why' ("$($unsupported[0].detail)" -like '*PROBLEM*') $true

    # 8. A provider that is down or refuses.
    $deadBody = Merge-Body $jiraBody @{ name = 'Jira, nobody home'; baseUrl = 'http://localhost:9199/jira' }
    $dead = (Invoke-Api POST "$ext/connection/initiate" $staff $deadBody).Body.id
    $down = New-Incident 'Provider is down'
    $failedLink = Link-Of $dead 'INCIDENT' $down
    Assert-Equal 'an unreachable provider is a 502 ERR-ETK-00502' "$($failedLink.Status)/$($failedLink.Body.error_code)" '502/ERR-ETK-00502'
    $failures = @((Invoke-Api GET "$ext/retrieve?connectionId=$dead&status=FAILED" $staff).Body)
    Assert-Equal 'the link is saved FAILED, with a short error and no ticket' "$($failures.Count)/$([bool]$failures[0].lastError)/$([bool]$failures[0].externalId)" '1/True/False'
    Assert-Equal 'the address is fixed (an update), then a sync creates the ticket' (Invoke-Api PUT "$ext/connection/$dead/update" $staff (Merge-Body $deadBody @{ baseUrl = "$TicketingInternalUrl/jira" })).Status 204
    $retried = Invoke-Api PUT "$ext/$($failures[0].id)/sync/execute" $staff
    Assert-Equal 'the retry made the ticket and the link is LINKED' "$($retried.Status)/$($retried.Body.status)/$([bool]$retried.Body.externalId)" '200/LINKED/True'
    [void](Mock POST '/__mock/fail' @{ count = 1; status = 500; echo = $true })
    $refused = Link-Of $jira 'INCIDENT' (New-Incident 'The provider refuses')
    Assert-Equal 'a provider that refuses is a 502, and its answer (which echoed our credentials) is not relayed' "$($refused.Status)/$(($refused.Raw -notmatch 'echoed') -and ($refused.Raw -notmatch $jiraAuthValue))" '502/True'
    Assert-Equal 'the message names the operation and the status' ("$($refused.Body.detail)" -match 'HTTP 500') $true

    # 9. Disabled connections and detached links.
    $toggle = (Invoke-Api POST "$ext/connection/initiate" $staff (Merge-Body $jiraBody @{ name = 'Toggle' })).Body.id
    Assert-Equal 'disable' (Invoke-Api PUT "$ext/connection/$toggle/control/disable" $staff).Status 204
    Assert-Equal 'disabling twice is an illegal transition (409)' (Invoke-Api PUT "$ext/connection/$toggle/control/disable" $staff).Status 409
    Assert-Equal 'a disabled connection links nothing (409)' (Link-Of $toggle 'INCIDENT' (New-Incident 'Disabled')).Status 409
    Assert-Equal 'a disabled connection accepts no webhook (409)' (Invoke-Api POST "$ext/webhook/$toggle/receive" @{ 'X-Webhook-Token' = $jiraHookValue } $payload).Status 409
    Assert-Equal 'enable' (Invoke-Api PUT "$ext/connection/$toggle/control/enable" $staff).Status 204
    Assert-Equal 'and it links again' (Link-Of $toggle 'INCIDENT' (New-Incident 'Enabled again')).Status 201
    Assert-Equal 'detach the first link' (Invoke-Api PUT "$ext/$linkId/control/detach" $staff).Status 204
    Assert-Equal 'a detached link is no longer synced (409)' (Invoke-Api PUT "$ext/$linkId/sync/execute" $staff).Status 409
    Assert-Equal 'nor followed: its ticket is now unknown to the platform' (Event 'jira' $key 'Done' $null 'alice')[0].outcome 'IGNORED_UNKNOWN_TICKET'
    Assert-Equal 'and the item is not linked again (409, the history is kept)' (Link-Of $jira 'INCIDENT' $incidentId).Status 409
    Assert-Equal 'detaching twice is an illegal transition (409)' (Invoke-Api PUT "$ext/$linkId/control/detach" $staff).Status 409

    # 10. Staff only, the tenant, and a race.
    $denied = Invoke-Api POST "$ext/connection/initiate" $asRequester $jiraBody
    Assert-Equal 'a REQUESTER cannot register a connection (403 ERR-ETK-00403)' "$($denied.Status)/$($denied.Body.error_code)" '403/ERR-ETK-00403'
    Assert-Equal 'a REQUESTER cannot list connections (403)' (Invoke-Api GET "$ext/connection/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot link (403)' (Invoke-Api POST "$ext/initiate" $asRequester @{ connectionId = $jira; subjectType = 'INCIDENT'; subjectId = $incidentId }).Status 403
    Assert-Equal 'a REQUESTER cannot read a link (403)' (Invoke-Api GET "$ext/$($secondLink.id)/retrieve" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot sync (403)' (Invoke-Api PUT "$ext/$($secondLink.id)/sync/execute" $asRequester).Status 403
    Assert-Equal 'a REQUESTER cannot read the audit trail (403)' (Invoke-Api GET "$ext/$($secondLink.id)/audit-log/retrieve" $asRequester).Status 403
    Assert-Equal 'another tenant gets a 404 for the link' (Invoke-Api GET "$ext/$($secondLink.id)/retrieve" $otherTenant).Status 404
    Assert-Equal 'and for the connection' (Invoke-Api GET "$ext/connection/$jira/retrieve" $otherTenant).Status 404
    Assert-Equal 'and finds no links' (@((Invoke-Api GET "$ext/retrieve" $otherTenant).Body).Count) 0
    $raced = New-Incident 'Two people link me at once'
    $issuesBefore = @((Mock-State).jira.issues.PSObject.Properties).Count
    $link = {
        param($url, $tenant, $executor, $connection, $subject)
        try { [int](Invoke-WebRequest -Method POST -Uri $url -UseBasicParsing -ContentType 'application/json' -Headers @{ 'X-Tenant-Id' = $tenant; 'X-Executor' = $executor } `
            -Body (@{ connectionId = $connection; subjectType = 'INCIDENT'; subjectId = $subject } | ConvertTo-Json)).StatusCode }
        catch { [int]$_.Exception.Response.StatusCode }
    }
    $jobs = @((Start-Job -ScriptBlock $link -ArgumentList "$ext/initiate", $tenantId, $staffUser, $jira, $raced),
              (Start-Job -ScriptBlock $link -ArgumentList "$ext/initiate", $tenantId, $staffUser2, $jira, $raced))
    $codes = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job
    Assert-Equal 'two people linking the same incident at the same instant: one 201 and one 409' (($codes | Sort-Object) -join ',') '201,409'
    Assert-Equal 'and exactly one ticket was created for it' (@((Mock-State).jira.issues.PSObject.Properties).Count - $issuesBefore) 1

    # 11. No secret anywhere, and the ledger.
    $text = $everything.ToString()
    Assert-Equal 'no credential or webhook token appears in any answer' (($text -notmatch [regex]::Escape($jiraAuthValue)) -and ($text -notmatch [regex]::Escape($snowAuthValue)) -and ($text -notmatch [regex]::Escape($jiraHookValue)) -and ($text -notmatch [regex]::Escape($snowHookValue))) $true
    $trailText = (Invoke-Api GET "$ext/connection/$jira/audit-log/retrieve" $staff).Raw
    Assert-Equal 'nor in the audit trail of a connection' (($trailText -notmatch $jiraAuthValue) -and ($trailText -notmatch $jiraHookValue)) $true
    $ledger = "$LedgerUrl/compliance-audit-ledger/v1"
    $recorded = 0
    for ($i = 0; $i -lt 20; $i++) {
        $entries = @((Invoke-Api GET "$ledger/retrieve?limit=500" @{ 'X-Tenant-Id' = $tenantId }).Body | Where-Object { $_.resourceType -eq 'it-external-ticketing' })
        $recorded = $entries.Count
        if ($recorded -ge 40) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-Equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' ($recorded -ge 40) $true
    Assert-Equal 'a refused one is there with its status' (@($entries | Where-Object { $_.detail -eq 'status=403' }).Count -ge 1) $true
    Assert-Equal 'the chain verifies' (Invoke-Api GET "$ledger/integrity-check/evaluate" @{ 'X-Tenant-Id' = $tenantId }).Body.valid $true
}
finally {
    if ($mockProcess) { Stop-Process -Id $mockProcess.Id -Force -ErrorAction SilentlyContinue }
}

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("External ticketing smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
