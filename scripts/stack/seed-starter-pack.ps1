<#
.SYNOPSIS
  Starter pack of alert rules for one edition (HOMELAB, TEAM or ENTERPRISE), created through the gateway.
.DESCRIPTION
  RequesterId is the person the incidents of these rules are filed for. The pack is only rules: every other policy (capacity, backup, patch) is
  about one asset and a number only the owner knows. A rule with no checkId covers every check or policy of its source. Rule names are unique per
  organisation: running it again keeps what is there and adds what is missing, and never touches a rule that was changed or paused. No rule names a
  webhook (a pack cannot know a deployment's environment variables): add notifyTarget with rule/update.
#>
param(
    [Parameter(Mandatory)][ValidateSet('HOMELAB', 'TEAM', 'ENTERPRISE')][string]$Edition,
    [Parameter(Mandatory)][string]$OrganisationId,
    [Parameter(Mandatory)][string]$RequesterId,
    [string]$Gateway = $(if ($env:GATEWAY_URL) { $env:GATEWAY_URL } else { 'http://localhost:8088' })
)
$ErrorActionPreference = 'Stop'

# name|source|impact|urgency|reopenWithinMinutes
$homelab = @(
    'Starter: a health check is down|HEALTH_CHECK|MEDIUM|MEDIUM|30',
    'Starter: a capacity policy is critical|CAPACITY|MEDIUM|MEDIUM|0'
)
$team = $homelab + @(
    'Starter: a backup promise is broken|BACKUP|HIGH|MEDIUM|0',
    'Starter: a patch is overdue|PATCH|MEDIUM|MEDIUM|0',
    'Starter: a recovery plan is not ready|DR|MEDIUM|MEDIUM|0'
)
$enterprise = @(
    'Starter: a health check is down|HEALTH_CHECK|HIGH|HIGH|30',
    'Starter: a capacity policy is critical|CAPACITY|HIGH|MEDIUM|0',
    'Starter: a backup promise is broken|BACKUP|HIGH|HIGH|0',
    'Starter: a patch is overdue|PATCH|HIGH|MEDIUM|0',
    'Starter: a recovery plan is not ready|DR|HIGH|MEDIUM|0',
    'Starter: a vendor agreement is about to end|VENDOR|MEDIUM|LOW|0',
    'Starter: a licence is over its limit|LICENSE|MEDIUM|MEDIUM|0'
)
$pack = switch ($Edition) { 'HOMELAB' { $homelab } 'TEAM' { $team } 'ENTERPRISE' { $enterprise } }

$created = 0; $kept = 0; $failed = 0
foreach ($entry in $pack) {
    $name, $source, $impact, $urgency, $reopen = $entry.Split('|')
    $body = @{ name = $name; source = $source; impact = $impact; urgency = $urgency; reopenWithinMinutes = [int]$reopen; requesterId = $RequesterId } | ConvertTo-Json
    $response = Invoke-WebRequest -Method Post -Uri "$Gateway/it-alerting/v1/rule/initiate" -ContentType 'application/json' -Body $body -SkipHttpErrorCheck `
        -Headers @{ 'X-Tenant-Id' = $OrganisationId; 'X-Executor' = 'starter-pack' }
    switch ([int]$response.StatusCode) {
        201 { $created++; Write-Output "created  $name" }
        409 { $kept++; Write-Output "kept     $name" }
        default { $failed++; Write-Error "FAILED   $name (HTTP $($response.StatusCode))" -ErrorAction Continue }
    }
}
Write-Output "${Edition}: $created created, $kept already there, $failed failed"
exit ([int]($failed -gt 0))
