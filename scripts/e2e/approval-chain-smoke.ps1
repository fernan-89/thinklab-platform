<#
.SYNOPSIS
  Live proof of approval chains (workflow-approval ADR-033/034), through the platform gateway.

.DESCRIPTION
  Needs the stack up (start-local-stack.ps1). Uses its own tenant and its own approver ids (workflow-approval takes any UUID):
    (1) a policy with two stages (a team lead, then two security reviewers who must BOTH approve); stages together with the
        single-quorum pair, and one person in two stages, are refused (400);
    (2) a request waits on stage 1 only: the lead has it in the inbox, security does not and cannot decide yet (409);
    (3) the lead's approval moves it to stage 2 (still PENDING) and the inboxes swap;
    (4) the two security reviewers vote AT THE SAME TIME: whatever the interleaving no vote is lost - the one that lost a race is
        refused (409) and succeeds when it retries, and the request ends APPROVED with exactly two stage-2 votes;
    (5) a REJECT at stage 2 resolves the whole request REJECTED and the other reviewer is then refused (409);
    (6) editing the policy afterwards does not change a request already filed, and a policy given the original single-quorum shape
        still works as a one-stage chain; another tenant's inbox is empty (tenant isolation).

    powershell -File .\approval-chain-smoke.ps1
#>
param([string]$GatewayUrl = 'http://localhost:8088')

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Invoke-Api {
    param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, $Body = $null)
    $p = @{ Method = $Method; Uri = $Url; Headers = $Headers; UseBasicParsing = $true }
    if ($null -ne $Body) { $p.ContentType = 'application/json'; $p.Body = $Body | ConvertTo-Json -Depth 8 }
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

$wf = "$GatewayUrl/workflow-approval/v1"
$tenantId = [guid]::NewGuid().ToString()
$tenant = @{ 'X-Tenant-Id' = $tenantId; 'X-Executor' = 'approval-chain-smoke' }
$lead = [guid]::NewGuid().ToString(); $secA = [guid]::NewGuid().ToString(); $secB = [guid]::NewGuid().ToString()
$requester = [guid]::NewGuid().ToString()
function As([string]$Approver) { @{ 'X-Executor' = $Approver } }
function Inbox([string]$Approver, [string]$Tenant = $tenantId) { @((Invoke-Api GET "$wf/retrieve?pendingFor=$Approver" @{ 'X-Tenant-Id' = $Tenant }).Body) }
function File([string]$PolicyId) {
    (Invoke-Api POST "$wf/initiate" $tenant @{ subjectType = 'ChangeRequest'; subjectId = [guid]::NewGuid().ToString(); requesterId = $requester; policyId = $PolicyId })
}

# 1. The policy: two stages, and what is refused.
$policy = Invoke-Api POST "$wf/policy/initiate" $tenant @{ name = 'Production change'; stages = @(
    @{ requiredApprovals = 1; eligibleApproverIds = @($lead) },
    @{ requiredApprovals = 2; eligibleApproverIds = @($secA, $secB) }) }
Assert-Equal 'a policy with two stages is created' $policy.Status 201
Assert-Equal 'it answers with both stages' @($policy.Body.stages).Count 2
Assert-Equal 'the first stage is also the top-level quorum' $policy.Body.requiredApprovals 1
$ambiguous = Invoke-Api POST "$wf/policy/initiate" $tenant @{ name = 'Ambiguous'; requiredApprovals = 1; eligibleApproverIds = @($lead); stages = @(@{ requiredApprovals = 1; eligibleApproverIds = @($secA) }) }
Assert-Equal 'stages together with the single-quorum pair are refused (400)' $ambiguous.Status 400
$overlap = Invoke-Api POST "$wf/policy/initiate" $tenant @{ name = 'Same person twice'; stages = @(
    @{ requiredApprovals = 1; eligibleApproverIds = @($lead) }, @{ requiredApprovals = 1; eligibleApproverIds = @($lead, $secA) }) }
Assert-Equal 'one person in two stages is refused (400)' $overlap.Status 400
Assert-Equal 'and the refusal names segregation of duties' ($overlap.Body.detail -like '*Segregation of duties*') $true

# 2. A request waits on stage 1 only.
$filed = File $policy.Body.id
$requestId = $filed.Body.id
Assert-Equal 'a request is filed against the chain' $filed.Status 201
Assert-Equal 'it is PENDING on stage 1 of 2' "$($filed.Body.status)/$($filed.Body.currentStage)/$(@($filed.Body.stages).Count)" 'PENDING/1/2'
Assert-Equal 'the lead has it in the inbox' (@(Inbox $lead | Where-Object { $_.id -eq $requestId }).Count) 1
Assert-Equal 'security does not have it yet' (@(Inbox $secA | Where-Object { $_.id -eq $requestId }).Count) 0
Assert-Equal 'security cannot decide before its stage (409)' (Invoke-Api PUT "$wf/$requestId/decision/capture" (As $secA) @{ outcome = 'APPROVE' }).Status 409

# 3. The lead approves: stage 2, still PENDING, inboxes swap.
$first = Invoke-Api PUT "$wf/$requestId/decision/capture" (As $lead) @{ outcome = 'APPROVE'; comment = 'ok from the team' }
Assert-Equal 'the lead approves' $first.Status 200
Assert-Equal 'the request is still PENDING, now on stage 2 needing two approvals' "$($first.Body.status)/$($first.Body.currentStage)/$($first.Body.requiredApprovals)" 'PENDING/2/2'
Assert-Equal 'the lead vote is recorded on stage 1' $first.Body.decisions[0].stage 1
Assert-Equal 'the lead no longer has it' (@(Inbox $lead | Where-Object { $_.id -eq $requestId }).Count) 0
Assert-Equal 'security has it now' (@(Inbox $secA | Where-Object { $_.id -eq $requestId }).Count) 1
Assert-Equal 'the lead cannot decide a second time (409)' (Invoke-Api PUT "$wf/$requestId/decision/capture" (As $lead) @{ outcome = 'APPROVE' }).Status 409

# 4. Both reviewers vote at the same time: no vote may be lost.
$vote = {
    param($url, $approver)
    try {
        $r = Invoke-WebRequest -Method PUT -Uri $url -UseBasicParsing -ContentType 'application/json' -Body '{"outcome":"APPROVE"}' -Headers @{ 'X-Executor' = $approver }
        [int]$r.StatusCode
    } catch { [int]$_.Exception.Response.StatusCode }
}
$voteUrl = "$wf/$requestId/decision/capture"
$jobs = @((Start-Job -ScriptBlock $vote -ArgumentList $voteUrl, $secA), (Start-Job -ScriptBlock $vote -ArgumentList $voteUrl, $secB))
$codes = @($jobs | Wait-Job | Receive-Job)
$jobs | Remove-Job
Assert-Equal 'each simultaneous vote is accepted or told to retry (200/409), never an error' (@($codes | Where-Object { $_ -ne 200 -and $_ -ne 409 }).Count) 0
foreach ($pair in @(@($secA, $codes[0]), @($secB, $codes[1]))) {
    if ($pair[1] -eq 409) {
        $retry = Invoke-Api PUT $voteUrl (As $pair[0]) @{ outcome = 'APPROVE' }
        Assert-Equal 'a vote that lost the race succeeds when it retries (or was already counted)' (@(200, 409) -contains $retry.Status) $true
    }
}
$done = (Invoke-Api GET "$wf/$requestId/retrieve" $tenant).Body
Assert-Equal 'the request ends APPROVED' $done.status 'APPROVED'
Assert-Equal 'with exactly the three votes: nothing lost, nothing counted twice' @($done.decisions).Count 3
Assert-Equal 'two of them on stage 2' (@($done.decisions | Where-Object { $_.stage -eq 2 }).Count) 2
$audit = @((Invoke-Api GET "$wf/$requestId/audit-log/retrieve" $tenant).Body)
Assert-Equal 'the audit trail reads INITIATED then three DECISION_CAPTURED' (($audit | ForEach-Object { $_.action }) -join ',') 'INITIATED,DECISION_CAPTURED,DECISION_CAPTURED,DECISION_CAPTURED'
Assert-Equal 'the first decision records the stage change' ($audit[1].detail -like '*Stage 1 of 2 complete; now waiting on stage 2.*') $true

# 5. A REJECT at stage 2 ends everything.
$second = File $policy.Body.id
$secondId = $second.Body.id
Assert-Equal 'the lead approves the second request' (Invoke-Api PUT "$wf/$secondId/decision/capture" (As $lead) @{ outcome = 'APPROVE' }).Status 200
$rejected = Invoke-Api PUT "$wf/$secondId/decision/capture" (As $secA) @{ outcome = 'REJECT'; comment = 'not now' }
Assert-Equal 'a security reviewer rejects at stage 2' $rejected.Status 200
Assert-Equal 'the whole request is REJECTED at once' $rejected.Body.status 'REJECTED'
Assert-Equal 'the other reviewer is then refused (409)' (Invoke-Api PUT "$wf/$secondId/decision/capture" (As $secB) @{ outcome = 'APPROVE' }).Status 409
Assert-Equal 'a resolved request leaves the inbox' (@(Inbox $secB | Where-Object { $_.id -eq $secondId }).Count) 0

# 6. Editing the policy leaves a filed request alone; the original shape still works; tenants are isolated.
$third = File $policy.Body.id
Assert-Equal 'edit the policy to a single stage' (Invoke-Api PUT "$wf/policy/$($policy.Body.id)/update" $tenant @{ name = 'Production change v2'; stages = @(@{ requiredApprovals = 1; eligibleApproverIds = @($lead) }) }).Status 204
$stillTwo = (Invoke-Api GET "$wf/$($third.Body.id)/retrieve" $tenant).Body
Assert-Equal 'a request filed before the edit keeps its two stages' @($stillTwo.stages).Count 2
$flat = Invoke-Api POST "$wf/policy/initiate" $tenant @{ name = 'CAB'; requiredApprovals = 1; eligibleApproverIds = @($lead) }
Assert-Equal 'the original single-quorum shape is still accepted' $flat.Status 201
Assert-Equal 'and is a one-stage chain' @($flat.Body.stages).Count 1
$single = File $flat.Body.id
Assert-Equal 'its request resolves APPROVED with one vote' (Invoke-Api PUT "$wf/$($single.Body.id)/decision/capture" (As $lead) @{ outcome = 'APPROVE' }).Body.status 'APPROVED'
Assert-Equal 'another tenant sees an empty inbox for the same approver' (@(Inbox $lead ([guid]::NewGuid().ToString())).Count) 0

$results | Format-Table -AutoSize | Out-String | Write-Output
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Output ("Approval chain smoke: {0} checks, {1} failed" -f $results.Count, $failed)
exit $(if ($failed -eq 0) { 0 } else { 1 })
