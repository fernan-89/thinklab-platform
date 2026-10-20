#!/usr/bin/env bash
# Live proof of the promises contract (platform ADR-001) on EVERY registry, through the gateway: each answers GET <domain>/promises/retrieve with the same
# shape (id, name, assetId, verdict from the fixed three, a fixed code only when broken, status, changedAt), refuses a REQUESTER (403), refuses a window or a
# limit out of range (400), shows nothing of another tenant, and a freshly created promise is in the answer. One loop, so a registry that drifts from the
# contract is caught here and not by the alerting service in production.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# api METHOD URL BODY HEADER... -> prints "<status>\n<body>", never exits on a non-2xx.
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

tenant_id=$(uuid); other_id=$(uuid); user=$(uuid); asset=$(uuid); vendor=$(uuid); account=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: contract-smoke')
requester=("$tenant" "X-Executor: $user" 'X-Role: REQUESTER')
other=("X-Tenant-Id: $other_id" "X-Executor: $user")

# The shape every promise must have, checked on every item of every answer: the verdict is one of three, a code only when broken, a status, an instant.
shape_ok() { python3 -c "
import json,sys,uuid,datetime
items=json.load(sys.stdin)
ok=isinstance(items,list)
for p in items:
    ok = ok and set(p.keys()) <= {'id','name','assetId','verdict','code','status','changedAt'} and {'id','name','verdict','status','changedAt'} <= set(p.keys())
    ok = ok and p['verdict'] in ('KEPT','BROKEN','NOT_JUDGED') and bool(p['name']) and bool(p['status'])
    ok = ok and ((p['verdict']=='BROKEN') == (p.get('code') is not None))
    uuid.UUID(p['id']); datetime.datetime.fromisoformat(p['changedAt'].replace('Z','+00:00'))
print(ok)"; }
has_id() { python3 -c "import json,sys; print(any(p['id']=='$1' for p in json.load(sys.stdin)))"; }

# registry NAME PATH CREATE_URL CREATE_BODY -> creates one item of that registry and runs the contract checks on it.
registry() {
  local name=$1 path=$2 create_url=$3 body=$4 id
  local base="$gateway$path/promises/retrieve"
  id=$(api_body "$(api POST "$create_url" "$body" "${tool[@]}")" | json "['id']")
  local answer; answer=$(api GET "$base" "" "${staff[@]}")
  check_equal "$name: answers the contract (200) with the same shape on every item" '200/True' "$(api_status "$answer")/$(api_body "$answer" | shape_ok)"
  check_equal "$name: what was just created is in the answer" True "$(api_body "$answer" | has_id "$id")"
  check_equal "$name: the created item is listed once" 1 "$(api_body "$answer" | python3 -c "import json,sys; print(sum(1 for p in json.load(sys.stdin) if p['id']=='$id'))")"
  check_equal "$name: a window of one day and a limit of one are accepted" 200 "$(api_status "$(api GET "$base?changedWithinDays=1&limit=1" "" "${staff[@]}")")"
  check_equal "$name: a window of 0 and of 366 days are refused (400)" '400/400' "$(api_status "$(api GET "$base?changedWithinDays=0" "" "${staff[@]}")")/$(api_status "$(api GET "$base?changedWithinDays=366" "" "${staff[@]}")")"
  check_equal "$name: a limit of 0 and of 1001 are refused (400)" '400/400' "$(api_status "$(api GET "$base?limit=0" "" "${staff[@]}")")/$(api_status "$(api GET "$base?limit=1001" "" "${staff[@]}")")"
  check_equal "$name: a REQUESTER is refused (403)" 403 "$(api_status "$(api GET "$base" "" "${requester[@]}")")"
  check_equal "$name: another tenant sees none of it" 'False' "$(api_body "$(api GET "$base" "" "${other[@]}")" | has_id "$id")"
  check_equal "$name: a route that is not a promise is no part of the contract (POST is not allowed)" True "$(s=$(api_status "$(api POST "$base" '{}' "${staff[@]}")"); [[ "$s" == 404 || "$s" == 405 ]] && echo True || echo False)"
}

registry backup /it-backup-registry/v1 "$gateway/it-backup-registry/v1/initiate" "{\"name\":\"Contract $(uuid | cut -c1-8)\",\"assetId\":\"$asset\",\"frequencyHours\":24,\"rpoHours\":48,\"rtoMinutes\":120,\"retentionDays\":30}"
registry patch /it-patch-registry/v1 "$gateway/it-patch-registry/v1/initiate" "{\"name\":\"Contract $(uuid | cut -c1-8)\",\"assetId\":\"$asset\",\"criticalDays\":2,\"highDays\":7,\"mediumDays\":30,\"lowDays\":90}"
registry capacity /it-capacity-registry/v1 "$gateway/it-capacity-registry/v1/initiate" "{\"name\":\"Contract $(uuid | cut -c1-8)\",\"assetId\":\"$asset\",\"metric\":\"DISK\",\"limit\":1000,\"warnPercent\":70,\"criticalPercent\":90,\"windowDays\":30,\"horizonDays\":30,\"reportEveryHours\":24}"
registry vendor /it-vendor-registry/v1 "$gateway/it-vendor-registry/v1/agreement/initiate" "{\"vendorId\":\"$(api_body "$(api POST "$gateway/it-vendor-registry/v1/initiate" "{\"name\":\"Contract vendor $(uuid | cut -c1-8)\",\"category\":\"SOFTWARE\"}" "${tool[@]}")" | json "['id']")\",\"reference\":\"CT-$(uuid | cut -c1-8)\",\"kind\":\"CONTRACT\",\"startsOn\":\"2026-01-01\",\"endsOn\":\"2030-12-31\",\"noticeDays\":30,\"autoRenew\":false}"
registry license /it-license-registry/v1 "$gateway/it-license-registry/v1/initiate" "{\"product\":\"Contract $(uuid | cut -c1-8)\",\"unit\":\"USER\",\"entitled\":100,\"warnPercent\":90,\"reportEveryHours\":24}"
registry dr /it-dr-registry/v1 "$gateway/it-dr-registry/v1/initiate" "{\"name\":\"Contract $(uuid | cut -c1-8)\",\"assetId\":\"$asset\",\"strategy\":\"WARM_STANDBY\",\"rtoMinutes\":120,\"rpoMinutes\":30,\"testEveryDays\":30}"
registry inventory /it-cloud-inventory/v1 "$gateway/it-cloud-inventory/v1/initiate" "{\"accountId\":\"$account\",\"provider\":\"AWS\",\"externalId\":\"i-$(uuid | cut -c1-8)\",\"name\":\"contract-1\",\"kind\":\"COMPUTE\",\"region\":\"us-east-1\",\"state\":\"RUNNING\",\"tags\":{}}"
registry procurement /it-procurement/v1 "$gateway/it-procurement/v1/initiate" "{\"reference\":\"PO-$(uuid | cut -c1-8)\",\"vendorId\":\"$vendor\",\"requesterId\":\"$user\",\"currency\":\"BRL\",\"expectedOn\":null,\"lines\":[{\"category\":\"OTHER\",\"item\":\"X\",\"quantity\":1,\"unitPrice\":1}]}"

echo "Promises contract smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
