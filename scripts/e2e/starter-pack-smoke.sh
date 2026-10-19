#!/usr/bin/env bash
# Live proof of the starter pack of alert rules (scripts/stack/seed-starter-pack.sh) through the platform gateway: an edition gets its rules (Homelab 2,
# Team 5, Enterprise 7), each watching every policy of its source and taking the class of that source; running it again creates nothing; moving up an
# edition adds only what is missing; a rule a person paused stays paused; another tenant has none of it; an unknown edition or a missing argument
# exits 2.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pack="$here/../stack/seed-starter-pack.sh"
gateway="${GATEWAY_URL:-http://localhost:8088}"
alr="$gateway/it-alerting/v1"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }

api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out; out=$(curl "${args[@]}" "$url")
  local code=${out##*$'\n'}; local content=${out%$'\n'*}
  printf '%s\n%s' "$code" "$content"
}
api_status() { head -1 <<<"$1"; }
api_body() { tail -n +2 <<<"$1"; }

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

tenant_id=$(uuid); requester=$(uuid)
staff=("X-Tenant-Id: $tenant_id" 'X-Executor: smoke')
rules() { api_body "$(api GET "$alr/rule/retrieve" "" "${staff[@]}")"; }
last_line() { tail -1 <<<"$1"; }
# sources -> the sorted sources of the rules, e.g. CAPACITY,HEALTH_CHECK
sources() { rules | python3 -c "import json,sys; print(','.join(sorted(r.get('source','HEALTH_CHECK') for r in json.load(sys.stdin))))"; }

# 1. Homelab.
out=$("$pack" HOMELAB "$tenant_id" "$requester" 2>&1); status=$?
check_equal 'Homelab creates two rules (exit 0)' '0/HOMELAB: 2 created, 0 already there, 0 failed' "$status/$(last_line "$out")"
check_equal 'they watch health checks and capacity policies' 'CAPACITY,HEALTH_CHECK' "$(sources)"
check_equal 'every rule is ACTIVE, covers every policy of its source and is filed for the requester' 'ACTIVE/True/True' \
  "$(rules | python3 -c "
import json,sys; r=json.load(sys.stdin)
print('%s/%s/%s' % ('ACTIVE' if all(x['status']=='ACTIVE' for x in r) else 'NO', all(x.get('checkId') is None for x in r), all(x['requesterId']==sys.argv[1] for x in r)))" "$requester")"
check_equal 'each takes the class of its source' 'AVAILABILITY,CAPACITY' \
  "$(rules | python3 -c "import json,sys; print(','.join(sorted(r['alertClass'] for r in json.load(sys.stdin))))")"
check_equal 'no rule names a webhook' True "$(rules | python3 -c "import json,sys; print(all(not r.get('notifyTarget') and not r.get('escalateTarget') for r in json.load(sys.stdin)))")"

# 2. A person pauses the health-check rule; moving up to Team adds the two missing rules and leaves it paused.
health=$(rules | python3 -c "import json,sys; print([r['id'] for r in json.load(sys.stdin) if r.get('source','HEALTH_CHECK')=='HEALTH_CHECK'][0])")
check_equal 'a person can pause a rule (204)' 204 "$(api_status "$(api PUT "$alr/rule/$health/control/pause" "" "${staff[@]}")")"
out=$("$pack" TEAM "$tenant_id" "$requester" 2>&1); status=$?
check_equal 'Team keeps the two and adds three' '0/TEAM: 3 created, 2 already there, 0 failed' "$status/$(last_line "$out")"
check_equal 'now backups, patches and recovery plans are watched too' 'BACKUP,CAPACITY,DR,HEALTH_CHECK,PATCH' "$(sources)"
check_equal 'the rule that was paused is still paused' PAUSED "$(api_body "$(api GET "$alr/rule/$health/retrieve" "" "${staff[@]}")" | json "['status']")"

# 3. Again: nothing to create.
out=$("$pack" TEAM "$tenant_id" "$requester" 2>&1); status=$?
check_equal 'running Team again creates nothing' '0/TEAM: 0 created, 5 already there, 0 failed' "$status/$(last_line "$out")"
check_equal 'still five rules' 5 "$(rules | count)"

# 4. Enterprise.
out=$("$pack" ENTERPRISE "$tenant_id" "$requester" 2>&1); status=$?
check_equal 'Enterprise adds the vendor and licence rules' '0/ENTERPRISE: 2 created, 5 already there, 0 failed' "$status/$(last_line "$out")"
check_equal 'seven rules, all seven sources' 'BACKUP,CAPACITY,DR,HEALTH_CHECK,LICENSE,PATCH,VENDOR' "$(sources)"
check_equal 'the contract rules are CONTRACT' 'CONTRACT,CONTRACT' \
  "$(rules | python3 -c "import json,sys; print(','.join(r['alertClass'] for r in json.load(sys.stdin) if r.get('source') in ('VENDOR','LICENSE')))")"

# 5. The tenant, and a wrong call.
other=("X-Tenant-Id: $(uuid)" 'X-Executor: smoke')
check_equal 'another tenant has none of it' 0 "$(api_body "$(api GET "$alr/rule/retrieve" "" "${other[@]}")" | count)"
"$pack" NOPE "$tenant_id" "$requester" >/dev/null 2>&1; check_equal 'an unknown edition exits 2' 2 "$?"
"$pack" HOMELAB >/dev/null 2>&1; check_equal 'a missing argument exits 2' 2 "$?"

echo "Starter pack smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
