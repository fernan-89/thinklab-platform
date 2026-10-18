#!/usr/bin/env bash
# Live proof of Journey 14, fourth service (bash port of patch-smoke.ps1; patch-registry ADR-030..033): the patch registry through the platform
# gateway. A policy is judged when read, twenty simultaneous reports of one patch make one finding, an applied patch is never reopened by being
# reported again, a waiver has a fixed reason and runs out by itself, nothing in a tool's own words is kept or repeated, two people waiving at once
# get one winner, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
pch="$gateway/it-patch-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
days_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
seconds_ahead() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); asset_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: scanner-1')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$pch/finding/initiate" "$1" "${tool[@]}"; }
field() { stb GET "$pch/$policy/retrieve" | json "$1"; }
finding_field() { stb GET "$pch/finding/$1/retrieve" | json "$2"; }
finding_json() { printf '{"policyId":"%s","patchRef":"%s","severity":"%s","announcedAt":"%s"}' "$policy" "$1" "$2" "$3"; }
policy_json() { printf '{"name":"%s","assetId":"%s","criticalDays":2,"highDays":7,"mediumDays":30,"lowDays":90}' "$1" "$asset_id"; }

# 1. A policy is a promise, judged when read.
created=$(api POST "$pch/initiate" "$(policy_json 'Servers')" "${staff[@]}")
policy=$(api_body "$created" | json "['id']")
check_equal 'staff promise 2/7/30/90 days: 201, ACTIVE, COMPLIANT with nothing open' '201/ACTIVE/COMPLIANT' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['compliance']))")"
check_equal 'the list finds it by compliance and by asset' "$policy/$policy" \
  "$(stb GET "$pch/retrieve?compliance=COMPLIANT&assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")/$(stb GET "$pch/retrieve?assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")"

# 2. A scanner reports; the same patch twenty times at once is one finding.
fresh=$(days_ago 1)
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: scanner-$i" \
      -d "$(finding_json KB5030211 HIGH "$fresh")" "$pch/finding/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same patch reported by twenty scanners at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other"
fresh_id=$(json "['id']" < "$tmp/body1")
check_equal 'every answer is the same finding' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'and the list holds exactly one finding for the policy' 1 "$(stb GET "$pch/finding/retrieve?policyId=$policy" | count)"
check_equal 'within its 7 days the patch is open but not overdue, and the policy is COMPLIANT' 'False/COMPLIANT/1' \
  "$(finding_field "$fresh_id" "['overdue']")/$(field "['compliance']")/$(field "['openFindings']")"

# 3. A patch past its deadline makes the policy OVERDUE.
late=$(report "$(finding_json CVE-2026-1234 CRITICAL "$(days_ago 5)")")
late_id=$(api_body "$late" | json "['id']")
check_equal 'a critical patch announced 5 days ago (2 days allowed) is reported: 201, overdue' '201/True' "$(api_status "$late")/$(api_body "$late" | json "['overdue']")"
check_equal 'the policy is OVERDUE with one overdue patch and the deadline that was missed' 'OVERDUE/1/True' \
  "$(field "['compliance']")/$(field "['overdueFindings']")/$(field "['oldestOverdueDueAt']" | python3 -c "import sys; print(sys.stdin.read().strip() != 'None')")"

# 4. A waiver has a fixed reason and runs out by itself.
check_equal 'staff waive it for 4 seconds, accepted risk (204)' 204 "$(st PUT "$pch/finding/$late_id/control/waive" "{\"reason\":\"ACCEPTED_RISK\",\"until\":\"$(seconds_ahead 4)\"}")"
check_equal 'while the waiver lasts, the patch is out of the count: COMPLIANT, one waived' 'WAIVED/COMPLIANT/1' \
  "$(finding_field "$late_id" "['status']")/$(field "['compliance']")/$(field "['waivedFindings']")"
sleep 6
check_equal 'when it ran out, with nobody doing anything, the policy is OVERDUE again' 'OVERDUE/1/0' "$(field "['compliance']")/$(field "['overdueFindings']")/$(field "['waivedFindings']")"
check_equal 'a waiver in the tool'"'"'s own words is refused (400)' 400 "$(st PUT "$pch/finding/$late_id/control/waive" "{\"reason\":\"password=hunter2\",\"until\":\"$(seconds_ahead 600)\"}")"
denied=$(api PUT "$pch/finding/$late_id/control/waive" "{\"reason\":\"password=hunter2\",\"until\":\"$(seconds_ahead 600)\"}" "${staff[@]}")
check_equal 'and the answer does not repeat it' False "$(api_body "$denied" | python3 -c "import sys; print('hunter2' in sys.stdin.read())")"

# 5. Two people waive at once: one wins. (A waiver that ran out is withdrawn first: a waived finding is waived until someone says otherwise.)
check_equal 'the expired waiver is withdrawn (204)' 204 "$(st PUT "$pch/finding/$late_id/control/unwaive")"
check_equal 'a waiver that ends in the past is refused (400)' 400 "$(st PUT "$pch/finding/$late_id/control/waive" "{\"reason\":\"ACCEPTED_RISK\",\"until\":\"$(days_ago 1)\"}")"
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: $(uuid)" \
      -d "{\"reason\":\"COMPENSATING_CONTROL\",\"until\":\"$(seconds_ahead 3600)\"}" "$pch/finding/$late_id/control/waive" > "$tmp/w$i" ) &
done
wait
check_equal 'two people waiving at once: one 204 and one 409' '204/409' "$(sort "$tmp/w1" "$tmp/w2" | paste -sd/ -)"
check_equal 'the waiver is withdrawn (204) and the patch is pending again' '204/PENDING' "$(st PUT "$pch/finding/$late_id/control/unwaive")/$(finding_field "$late_id" "['status']")"

# 6. Applied is for good.
check_equal 'the update agent reports it applied (204)' 204 "$(api_status "$(api PUT "$pch/finding/$late_id/control/apply" '' 'X-Tenant-Id: '"$tenant_id" 'X-Executor: update-agent-1')")"
check_equal 'the finding is APPLIED and the policy is COMPLIANT again' 'APPLIED/COMPLIANT' "$(finding_field "$late_id" "['status']")/$(field "['compliance']")"
reported_again=$(report "$(finding_json CVE-2026-1234 CRITICAL "$(days_ago 5)")")
check_equal 'the scanner reports the same patch again: 200, still APPLIED, never reopened' '200/APPLIED' "$(api_status "$reported_again")/$(api_body "$reported_again" | json "['status']")"
check_equal 'applying it twice is a conflict (409)' 409 "$(api_status "$(api PUT "$pch/finding/$late_id/control/apply" '' 'X-Tenant-Id: '"$tenant_id" 'X-Executor: update-agent-1')")"
check_equal 'a reference that is a sentence is refused (400)' 400 "$(api_status "$(report "$(finding_json 'disk /dev/sda1 is full' LOW "$fresh")")")"
check_equal 'a patch announced in the future is refused (400)' 400 "$(api_status "$(report "$(finding_json KB9 LOW "$(seconds_ahead 7200)")")")"
check_equal 'the trail of the finding holds each real change once, in order' 'REPORTED,WAIVED,UNWAIVED,WAIVED,UNWAIVED,APPLIED' \
  "$(stb GET "$pch/finding/$late_id/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 7. The policy.
check_equal 'a tighter high of 3 days (update, 204)' 204 "$(st PUT "$pch/$policy/update" "{\"name\":\"Servers\",\"assetId\":\"$asset_id\",\"criticalDays\":2,\"highDays\":3,\"mediumDays\":30,\"lowDays\":90}")"
check_equal 'days out of order are refused (400)' 400 "$(st PUT "$pch/$policy/update" "{\"name\":\"Servers\",\"assetId\":\"$asset_id\",\"criticalDays\":10,\"highDays\":3,\"mediumDays\":30,\"lowDays\":90}")"
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$pch/$policy/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused policy is not judged' 'PAUSED/PAUSED' "$(field "['status']")/$(field "['compliance']")"
check_equal 'resume' 204 "$(st PUT "$pch/$policy/control/resume")"
check_equal 'the policy trail holds each real change once, in order' 'INITIATED,UPDATED,PAUSED,RESUMED' \
  "$(stb GET "$pch/$policy/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 8. Staff only, the tenant.
check_equal 'a REQUESTER cannot promise (403 ERR-PCH-00403)' '403/ERR-PCH-00403' \
  "$(api_status "$(rq POST "$pch/initiate" "$(policy_json 'r')")")/$(api_body "$(rq POST "$pch/initiate" "$(policy_json 'r')")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a policy (403)' 403 "$(api_status "$(rq GET "$pch/$policy/retrieve")")"
check_equal 'a REQUESTER cannot report a finding (403)' 403 "$(api_status "$(rq POST "$pch/finding/initiate" "$(finding_json KB1 LOW "$fresh")")")"
check_equal 'a REQUESTER cannot list the findings (403)' 403 "$(api_status "$(rq GET "$pch/finding/retrieve")")"
check_equal 'a REQUESTER cannot waive (403)' 403 "$(api_status "$(rq PUT "$pch/finding/$fresh_id/control/waive" "{\"reason\":\"ACCEPTED_RISK\",\"until\":\"$(seconds_ahead 600)\"}")")"
check_equal 'another tenant gets a 404 for the policy' 404 "$(api_status "$(api GET "$pch/$policy/retrieve" "" "${other_tenant[@]}")")"
check_equal 'another tenant cannot report a finding for it (404)' 404 "$(api_status "$(api POST "$pch/finding/initiate" "$(finding_json KB1 LOW "$fresh")" "${other_tenant[@]}")")"
check_equal 'and finds no findings' 0 "$(api_body "$(api GET "$pch/finding/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$pch/$policy")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 9. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-patch-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-patch-registry'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('hunter2' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Patch smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
