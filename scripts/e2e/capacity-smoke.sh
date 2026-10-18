#!/usr/bin/env bash
# Live proof of Journey 14, fifth service (bash port of capacity-smoke.ps1; capacity-registry ADR-030..033): the capacity registry through the
# platform gateway. A policy is judged when read (level, stale, a straight-line forecast), twenty simultaneous reports of one sample make one
# sample, the latest sample only moves forward whatever the order of the reports, a different value for a moment already reported never overwrites
# it, a value the registry does not know is refused and never repeated, two people pausing at once get one winner, staff only, the tenant, and
# every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
cap="$gateway/it-capacity-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
ahead() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
DAY=1440

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); asset_id=$(uuid); quiet_asset=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: disk-agent-1')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$cap/sample/initiate" "$1" "${tool[@]}"; }
sample_json() { printf '{"policyId":"%s","value":%s,"measuredAt":"%s"}' "$1" "$2" "$3"; }
field() { stb GET "$cap/$policy/retrieve" | json "$1"; }
policy_json() { printf '{"name":"%s","assetId":"%s","metric":"DISK","limit":%s,"warnPercent":70,"criticalPercent":90,"windowDays":30,"horizonDays":30,"reportEveryHours":24}' "$1" "$2" "$3"; }

# 1. A policy is a watch, judged when read.
created=$(api POST "$cap/initiate" "$(policy_json 'Orders disk' "$asset_id" 100)" "${staff[@]}")
policy=$(api_body "$created" | json "['id']")
check_equal 'staff watch a disk of 100 units: 201, ACTIVE, NO_DATA, no forecast yet' '201/ACTIVE/NO_DATA/NOT_ENOUGH_DATA' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['level'], d['forecast']))")"
check_equal 'the list finds it by level, by asset and by metric' "$policy/$policy/$policy" \
  "$(stb GET "$cap/retrieve?level=NO_DATA&assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")/$(stb GET "$cap/retrieve?metric=DISK&assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")/$(stb GET "$cap/retrieve?status=ACTIVE" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")"

# 2. Samples a day apart draw a straight line: 10 units a day, 4 days to the limit.
day3=$(ago $((3 * DAY))); day2=$(ago $((2 * DAY))); day1=$(ago $DAY)
first=$(report "$(sample_json "$policy" 40 "$day3")")
first_id=$(api_body "$first" | json "['id']")
check_equal 'the first sample is a new fact: 201, value kept, reported by the tool' '201/40.0/disk-agent-1' "$(api_status "$first")/$(api_body "$first" | json "['value']")/$(api_body "$first" | json "['reportedBy']")"
check_equal 'one sample says nothing about the trend: OK at 40 percent, not enough data' 'OK/40.0/NOT_ENOUGH_DATA' "$(field "['level']")/$(field "['utilisationPercent']")/$(field "['forecast']")"
again=$(report "$(sample_json "$policy" 99 "$day3")")
check_equal 'the same moment with another value is the stored sample (200), the first value kept' "200/$first_id/40.0" "$(api_status "$again")/$(api_body "$again" | json "['id']")/$(api_body "$again" | json "['value']")"
check_equal 'the second and third samples are new (201)' '201/201' "$(api_status "$(report "$(sample_json "$policy" 50 "$day2")")")/$(api_status "$(report "$(sample_json "$policy" 60 "$day1")")")"
check_equal 'three samples a day apart: WITHIN_HORIZON, four days to the limit' 'OK/WITHIN_HORIZON/4.0' "$(field "['level']")/$(field "['forecast']")/$(stb GET "$cap/$policy/retrieve" | python3 -c "import json,sys; print(round(json.load(sys.stdin)['daysToLimit'], 3))")"
check_equal 'and it says when: four days after the latest sample' True "$(stb GET "$cap/$policy/retrieve" | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
p=lambda s: datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
print(abs((p(d['projectedExhaustionAt'])-p(d['lastMeasuredAt'])).total_seconds()-4*86400) < 5)")"

# 3. The same new moment reported by twenty tools at once is one sample.
moment=$(ago 120)
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: disk-agent-$i" \
      -d "$(sample_json "$policy" 61 "$moment")" "$cap/sample/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same sample reported by twenty tools at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other"
check_equal 'every answer is the same sample' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'and the policy holds exactly four samples' 4 "$(stb GET "$cap/sample/retrieve?policyId=$policy" | count)"

# 4. The latest sample only moves forward, whatever the order the reports arrive in.
for spec in "50 70" "40 71" "30 72"; do
  read -r minutes value <<<"$spec"
  ( curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H 'X-Executor: disk-agent-1' \
      -d "$(sample_json "$policy" "$value" "$(ago "$minutes")")" "$cap/sample/initiate" > "$tmp/m$minutes" ) &
done
wait
check_equal 'three samples reported at once: all new (201)' '201/201/201' "$(cat "$tmp/m50")/$(cat "$tmp/m40")/$(cat "$tmp/m30")"
check_equal 'the latest is the one with the newest moment, whichever arrived last: 72, now WARNING' '72.0/WARNING' "$(field "['lastValue']")/$(field "['level']")"
late=$(report "$(sample_json "$policy" 10 "$(ago $((5 * DAY)))")")
check_equal 'a late sample (five days ago) is new, joins the trend and does not move the latest back' '201/72.0' "$(api_status "$late")/$(field "['lastValue']")"
check_equal 'the samples are listed newest first and limited' '72.0,71.0/8' "$(stb GET "$cap/sample/retrieve?policyId=$policy&limit=2" | python3 -c "import json,sys; print(','.join(str(s['value']) for s in json.load(sys.stdin)))")/$(stb GET "$cap/sample/retrieve?policyId=$policy" | count)"

# 5. Tightening the limit changes the verdict at once, because nothing of it is stored.
check_equal 'update to a limit of 75 (204)' 204 "$(st PUT "$cap/$policy/update" "$(policy_json 'Orders disk' "$asset_id" 75)")"
check_equal '72 of 75 is now CRITICAL' 'CRITICAL/96.0' "$(field "['level']")/$(field "['utilisationPercent']")"
check_equal 'the list finds it by level CRITICAL and not by OK' "$policy/0" "$(stb GET "$cap/retrieve?level=CRITICAL" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")/$(stb GET "$cap/retrieve?level=OK" | count)"
check_equal 'a critical level not above the warning one is refused (400)' 400 "$(st PUT "$cap/$policy/update" '{"name":"x","assetId":"'"$asset_id"'","metric":"DISK","limit":100,"warnPercent":80,"criticalPercent":80,"windowDays":30,"horizonDays":30,"reportEveryHours":24}')"

# 6. A tool that went silent is stale, and still judged on its last known value.
quiet=$(api POST "$cap/initiate" "$(policy_json 'Quiet disk' "$quiet_asset" 100)" "${staff[@]}")
quiet_id=$(api_body "$quiet" | json "['id']")
check_equal 'a sample ten days old is accepted (201)' 201 "$(api_status "$(report "$(sample_json "$quiet_id" 95 "$(ago $((10 * DAY)))")")")"
check_equal 'that policy is stale (more than twice 24 hours), CRITICAL on 95, and has no trend' 'True/CRITICAL/NOT_ENOUGH_DATA' \
  "$(stb GET "$cap/$quiet_id/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['stale'], d['level'], d['forecast']))")"
check_equal 'the first policy is not stale' False "$(field "['stale']")"

# 7. Two people pause at once: one wins.
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$cap/$policy/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused policy is not judged and has no forecast (the field is left out)' 'PAUSED/PAUSED/None' \
  "$(stb GET "$cap/$policy/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['level'], d.get('forecast')))")"
check_equal 'a paused policy still accepts samples (201)' 201 "$(api_status "$(report "$(sample_json "$policy" 73 "$(ago 5)")")")"
check_equal 'resume' 204 "$(st PUT "$cap/$policy/control/resume")"
check_equal 'the policy trail holds each real change once, in order' 'INITIATED,UPDATED,PAUSED,RESUMED' \
  "$(stb GET "$cap/$policy/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 8. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(api POST "$cap/initiate" "$(policy_json 'n' "$asset_id" 100 | sed 's/"DISK"/"DISK-secret-value"/')" "${staff[@]}")
check_equal 'an unknown metric is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('secret-value' in sys.stdin.read())")"
check_equal 'a value that is not a number is refused (400)' 400 "$(api_status "$(report "{\"policyId\":\"$policy\",\"value\":\"lots\",\"measuredAt\":\"$(ago 3)\"}")")"
check_equal 'a negative value is refused (400)' 400 "$(api_status "$(report "$(sample_json "$policy" -1 "$(ago 3)")")")"
check_equal 'a sample taken in the future is refused (400)' 400 "$(api_status "$(report "$(sample_json "$policy" 10 "$(ahead 120)")")")"
check_equal 'a sample for a policy that is not the tenant'"'"'s is a 404' 404 "$(api_status "$(report "$(sample_json "$(uuid)" 10 "$(ago 3)")")")"

# 9. Staff only, the tenant.
check_equal 'a REQUESTER cannot watch (403 ERR-CAP-00403)' '403/ERR-CAP-00403' \
  "$(api_status "$(rq POST "$cap/initiate" "$(policy_json 'r' "$asset_id" 100)")")/$(api_body "$(rq POST "$cap/initiate" "$(policy_json 'r' "$asset_id" 100)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a policy (403)' 403 "$(api_status "$(rq GET "$cap/$policy/retrieve")")"
check_equal 'a REQUESTER cannot report a sample (403)' 403 "$(api_status "$(rq POST "$cap/sample/initiate" "$(sample_json "$policy" 10 "$(ago 3)")")")"
check_equal 'a REQUESTER cannot list the samples (403)' 403 "$(api_status "$(rq GET "$cap/sample/retrieve")")"
check_equal 'another tenant gets a 404 for the policy' 404 "$(api_status "$(api GET "$cap/$policy/retrieve" "" "${other_tenant[@]}")")"
check_equal 'another tenant cannot report a sample for it (404)' 404 "$(api_status "$(api POST "$cap/sample/initiate" "$(sample_json "$policy" 10 "$(ago 3)")" "${other_tenant[@]}")")"
check_equal 'and finds no samples' 0 "$(api_body "$(api GET "$cap/sample/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$cap/$policy")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 10. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-capacity-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-capacity-registry'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('secret-value' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Capacity smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
