#!/usr/bin/env bash
# Live proof of Journey 15, second service (bash port of license-smoke.ps1; license-registry ADR-030..033): the licence registry through the
# platform gateway. A licence is judged when read (OK, near its limit, over it, with the seats available), twenty simultaneous reports of one count
# make one report, the latest count only moves forward whatever the order of the reports, a different count for a moment already reported never
# overwrites it, a tool that went silent is stale and still judged, nothing it says is kept as text, two people pausing at once get one winner,
# staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
lic="$gateway/it-license-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); vendor_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: inventory-agent')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$lic/usage/initiate" "$1" "${tool[@]}"; }
usage_json() { printf '{"licenseId":"%s","inUse":%s,"measuredAt":"%s"}' "$1" "$2" "$3"; }
license_json() { printf '{"product":"%s","unit":"%s","entitled":%s,"warnPercent":90,"reportEveryHours":24,"vendorId":"%s"}' "$1" "$2" "$3" "$vendor_id"; }
field() { stb GET "$lic/$license/retrieve" | json "$1"; }
judged() { stb GET "$lic/$1/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['level'], d.get('available')))"; }

# 1. A licence is what was bought, judged when read.
created=$(api POST "$lic/initiate" "$(license_json 'Office 365 E3' USER 100)" "${staff[@]}")
license=$(api_body "$created" | json "['id']")
check_equal 'staff register 100 user seats: 201, ACTIVE, NO_DATA, nothing available yet' '201/ACTIVE/NO_DATA/None' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['level'], d.get('available')))")"
check_equal 'the list finds it by unit and vendor, and not by another unit' "$license/$license/0" \
  "$(stb GET "$lic/retrieve?unit=USER" | json "[0]['id']")/$(stb GET "$lic/retrieve?vendorId=$vendor_id" | json "[0]['id']")/$(stb GET "$lic/retrieve?unit=CORE" | count)"
check_equal 'a second licence for the same product is a conflict (409)' 409 "$(st POST "$lic/initiate" "$(license_json 'Office 365 E3' DEVICE 5)")"

# 2. Counts move the verdict: OK, NEAR_LIMIT, OVER_LIMIT.
m180=$(ago 180)
first=$(report "$(usage_json "$license" 60 "$m180")")
first_id=$(api_body "$first" | json "['id']")
check_equal 'the first count is a new fact: 201, the count kept, reported by the tool' '201/60/inventory-agent' "$(api_status "$first")/$(api_body "$first" | json "['inUse']")/$(api_body "$first" | json "['reportedBy']")"
check_equal '60 of 100 is OK with 40 left' 'OK/40' "$(judged "$license")"
again=$(report "$(usage_json "$license" 99 "$m180")")
check_equal 'the same moment with another count is the stored report (200), the first count kept' "200/$first_id/60" "$(api_status "$again")/$(api_body "$again" | json "['id']")/$(api_body "$again" | json "['inUse']")"
check_equal '95 is reported (201): NEAR_LIMIT with 5 left' '201/NEAR_LIMIT/5' "$(api_status "$(report "$(usage_json "$license" 95 "$(ago 120)")")")/$(judged "$license")"
check_equal '104 is reported (201): OVER_LIMIT with 4 seats too many' '201/OVER_LIMIT/-4' "$(api_status "$(report "$(usage_json "$license" 104 "$(ago 60)")")")/$(judged "$license")"
check_equal 'the list finds it by level OVER_LIMIT and not by OK' "$license/0" "$(stb GET "$lic/retrieve?level=OVER_LIMIT" | json "[0]['id']")/$(stb GET "$lic/retrieve?level=OK" | count)"

# 3. The same new count reported by twenty tools at once is one report.
moment=$(ago 30)
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: inventory-agent-$i" \
      -d "$(usage_json "$license" 103 "$moment")" "$lic/usage/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same count reported by twenty tools at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other"
check_equal 'every answer is the same report' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'and the licence holds exactly four reports' 4 "$(stb GET "$lic/usage/retrieve?licenseId=$license" | count)"

# 4. The latest count only moves forward, whatever the order the reports arrive in.
for spec in "20 70" "15 71" "10 72"; do
  read -r minutes value <<<"$spec"
  ( curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H 'X-Executor: inventory-agent' \
      -d "$(usage_json "$license" "$value" "$(ago "$minutes")")" "$lic/usage/initiate" > "$tmp/m$minutes" ) &
done
wait
check_equal 'three counts reported at once: all new (201)' '201/201/201' "$(cat "$tmp/m20")/$(cat "$tmp/m15")/$(cat "$tmp/m10")"
check_equal 'the latest is the one with the newest moment, whichever arrived last: 72, OK again' '72/OK' "$(field "['lastInUse']")/$(field "['level']")"
check_equal 'a late count (five days ago) is new and does not move the latest back' '201/72' "$(api_status "$(report "$(usage_json "$license" 10 "$(ago 7200)")")")/$(field "['lastInUse']")"
check_equal 'the reports are listed newest first and limited' '72,71' "$(stb GET "$lic/usage/retrieve?licenseId=$license&limit=2" | python3 -c "import json,sys; print(','.join(str(r['inUse']) for r in json.load(sys.stdin)))")"

# 5. Fewer seats bought changes the verdict at once, because nothing of it is stored.
check_equal 'update to 70 seats bought (204)' 204 "$(st PUT "$lic/$license/update" "$(license_json 'Office 365 E3' USER 70)")"
check_equal '72 of 70 is now OVER_LIMIT' 'OVER_LIMIT/-2' "$(judged "$license")"

# 6. A tool that went silent is stale, and still judged on its last count.
quiet=$(stb POST "$lic/initiate" "$(license_json 'AutoCAD' DEVICE 10)" | json "['id']")
check_equal 'a count of 11 devices from three days ago is accepted (201)' 201 "$(api_status "$(report "$(usage_json "$quiet" 11 "$(ago 4320)")")")"
check_equal 'that licence is stale (more than twice 24 hours) and still OVER_LIMIT' 'True/OVER_LIMIT' \
  "$(stb GET "$lic/$quiet/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['stale'], d['level']))")"

# 7. Two people pause at once: one wins.
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$lic/$license/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused licence is not judged (no seats available given)' 'PAUSED/None' "$(judged "$license")"
check_equal 'a paused licence still accepts counts (201)' 201 "$(api_status "$(report "$(usage_json "$license" 5 "$(ago 5)")")")"
check_equal 'resume' 204 "$(st PUT "$lic/$license/control/resume")"
check_equal 'the licence trail holds each real change once, in order' 'INITIATED,UPDATED,PAUSED,RESUMED' \
  "$(stb GET "$lic/$license/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 8. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(api POST "$lic/initiate" "$(license_json 'n' 'USER-secret-value' 5)" "${staff[@]}")
check_equal 'an unknown unit is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('secret-value' in sys.stdin.read())")"
badtime=$(report "{\"licenseId\":\"$license\",\"inUse\":1,\"measuredAt\":\"secret-yesterday\"}")
check_equal 'a moment that cannot be read is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$badtime")/$(api_body "$badtime" | python3 -c "import sys; print('secret' in sys.stdin.read())")"
check_equal 'a count that is not a whole number is refused (400)' 400 "$(api_status "$(report "{\"licenseId\":\"$license\",\"inUse\":\"lots\",\"measuredAt\":\"$(ago 3)\"}")")"
check_equal 'a negative count is refused (400)' 400 "$(api_status "$(report "$(usage_json "$license" -1 "$(ago 3)")")")"
check_equal 'a count for a licence that is not the tenant'"'"'s is a 404' 404 "$(api_status "$(report "$(usage_json "$(uuid)" 1 "$(ago 3)")")")"

# 9. Staff only, the tenant.
check_equal 'a REQUESTER cannot register a licence (403 ERR-LIC-00403)' '403/ERR-LIC-00403' \
  "$(api_status "$(rq POST "$lic/initiate" "$(license_json 'r' USER 1)")")/$(api_body "$(rq POST "$lic/initiate" "$(license_json 'r' USER 1)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a licence (403)' 403 "$(api_status "$(rq GET "$lic/$license/retrieve")")"
check_equal 'a REQUESTER cannot report a count (403)' 403 "$(api_status "$(rq POST "$lic/usage/initiate" "$(usage_json "$license" 1 "$(ago 3)")")")"
check_equal 'another tenant gets a 404 for the licence and finds no reports' '404/0' \
  "$(api_status "$(api GET "$lic/$license/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$lic/usage/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$lic/$license")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 10. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-license-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-license-registry'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('secret' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "License smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
