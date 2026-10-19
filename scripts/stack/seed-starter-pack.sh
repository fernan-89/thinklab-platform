#!/usr/bin/env bash
# Starter pack of alert rules for one edition (HOMELAB, TEAM or ENTERPRISE), created through the gateway.
#
#   scripts/stack/seed-starter-pack.sh <EDITION> <organisationId> <requesterId>
#
# <requesterId> is the person the incidents of these rules are filed for. The pack is only rules: every other policy (capacity, backup, patch) is
# about one asset and a number that only the owner knows, so it cannot be guessed. A rule with no checkId covers every check or policy of its
# source, so the pack keeps working as assets are added. Rule names are unique per organisation: running it again keeps what is there and adds
# what is missing, and it never touches a rule that has been changed or paused. No rule names a webhook: a pack cannot know the environment
# variables of a deployment, so add notifyTarget with rule/update.
set -uo pipefail

edition="${1:-}"; tenant_id="${2:-}"; requester="${3:-}"
gateway="${GATEWAY_URL:-http://localhost:8088}"
if [[ -z "$edition" || -z "$tenant_id" || -z "$requester" ]]; then
  echo "usage: $0 <HOMELAB|TEAM|ENTERPRISE> <organisationId> <requesterId>" >&2; exit 2
fi

# name|source|impact|urgency|reopenWithinMinutes
homelab=(
  "Starter: a health check is down|HEALTH_CHECK|MEDIUM|MEDIUM|30"
  "Starter: a capacity policy is critical|CAPACITY|MEDIUM|MEDIUM|0"
)
team=(
  "${homelab[@]}"
  "Starter: a backup promise is broken|BACKUP|HIGH|MEDIUM|0"
  "Starter: a patch is overdue|PATCH|MEDIUM|MEDIUM|0"
  "Starter: a recovery plan is not ready|DR|MEDIUM|MEDIUM|0"
)
enterprise=(
  "Starter: a health check is down|HEALTH_CHECK|HIGH|HIGH|30"
  "Starter: a capacity policy is critical|CAPACITY|HIGH|MEDIUM|0"
  "Starter: a backup promise is broken|BACKUP|HIGH|HIGH|0"
  "Starter: a patch is overdue|PATCH|HIGH|MEDIUM|0"
  "Starter: a recovery plan is not ready|DR|HIGH|MEDIUM|0"
  "Starter: a vendor agreement is about to end|VENDOR|MEDIUM|LOW|0"
  "Starter: a licence is over its limit|LICENSE|MEDIUM|MEDIUM|0"
)
case "$edition" in
  HOMELAB) pack=("${homelab[@]}") ;;
  TEAM) pack=("${team[@]}") ;;
  ENTERPRISE) pack=("${enterprise[@]}") ;;
  *) echo "unknown edition [$edition]: use HOMELAB, TEAM or ENTERPRISE" >&2; exit 2 ;;
esac

created=0; kept=0; failed=0
for entry in "${pack[@]}"; do
  IFS='|' read -r name source impact urgency reopen <<<"$entry"
  body=$(python3 -c 'import json,sys; n,s,i,u,r,q=sys.argv[1:]; print(json.dumps({"name":n,"source":s,"impact":i,"urgency":u,"reopenWithinMinutes":int(r),"requesterId":q}))' \
    "$name" "$source" "$impact" "$urgency" "$reopen" "$requester")
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$gateway/it-alerting/v1/rule/initiate" \
    -H "X-Tenant-Id: $tenant_id" -H 'X-Executor: starter-pack' -H 'Content-Type: application/json' -d "$body")
  case "$code" in
    201) created=$((created + 1)); echo "created  $name" ;;
    409) kept=$((kept + 1)); echo "kept     $name" ;;
    *) failed=$((failed + 1)); echo "FAILED   $name (HTTP $code)" >&2 ;;
  esac
done
echo "$edition: $created created, $kept already there, $failed failed"
exit $((failed > 0 ? 1 : 0))
