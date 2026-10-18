#!/usr/bin/env bash
# Live proof of Journey 15, first service (bash port of vendor-smoke.ps1; vendor-registry ADR-030..033): the vendor registry through the platform
# gateway. A vendor is a name and a category, an agreement is judged when read (not started, in force, expiring, expired) with the days to the end,
# twenty simultaneous registrations of one reference make one agreement, two people deactivating at once get one winner, an inactive vendor takes no new
# agreement, a renewal is a new last day, a date that cannot be read is refused and never repeated, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
vnd="$gateway/it-vendor-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
day() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }

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
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
vendor_json() { printf '{"name":"%s","category":"%s"}' "$1" "$2"; }
agreement_json() { printf '{"vendorId":"%s","kind":"%s","reference":"%s","assetId":%s,"startsOn":"%s","endsOn":"%s","noticeDays":%s,"autoRenew":false}' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
field() { stb GET "$vnd/agreement/$1/retrieve" | json "$2"; }
ids() { python3 -c "import json,sys; print(','.join(sorted(p['id'] for p in json.load(sys.stdin))))"; }
asset_ref="\"$asset_id\""

# 1. A vendor is a name and a category.
created=$(api POST "$vnd/initiate" "$(vendor_json 'Dell' HARDWARE)" "${staff[@]}")
vendor=$(api_body "$created" | json "['id']")
check_equal 'staff register a vendor: 201, ACTIVE, with its category' '201/ACTIVE/HARDWARE' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['category']))")"
check_equal 'the list finds it by status and category and not by another category' "$vendor/0" \
  "$(stb GET "$vnd/retrieve?status=ACTIVE&category=HARDWARE" | ids)/$(stb GET "$vnd/retrieve?category=CLOUD" | count)"
check_equal 'a vendor is renamed and recategorised (204)' 204 "$(st PUT "$vnd/$vendor/update" "$(vendor_json 'Dell Technologies' SERVICES)")"
check_equal 'and the change is kept' 'Dell Technologies/SERVICES' "$(stb GET "$vnd/$vendor/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['name'], d['category']))")"
check_equal 'the same name in the same organisation is a conflict (409)' 409 "$(st POST "$vnd/initiate" "$(vendor_json 'Dell Technologies' OTHER)")"

# 2. Four agreements, one for each way of standing.
expiring=$(api POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" WARRANTY 'WTY-2026/01' "$asset_ref" "$(day -400)" "$(day 20)" 30)" "${staff[@]}")
expiring_id=$(api_body "$expiring" | json "['id']")
check_equal 'a warranty ending in 20 days with 30 days of notice: 201, EXPIRING, 20 days left' '201/EXPIRING/20' \
  "$(api_status "$expiring")/$(api_body "$expiring" | json "['standing']")/$(api_body "$expiring" | json "['daysToEnd']")"
in_force=$(stb POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'CT-2026/02' null "$(day -10)" "$(day 400)" 30)" | json "['id']")
ended=$(stb POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" SUPPORT 'SUP-1' "$asset_ref" "$(day -400)" "$(day -10)" 30)" | json "['id']")
future=$(stb POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" LICENSE 'LIC-1' null "$(day 10)" "$(day 100)" 30)" | json "['id']")
check_equal 'a contract in force for 400 days, a support plan that ended 10 days ago and a licence that starts in 10 days are judged on their own' 'IN_FORCE/EXPIRED/-10/NOT_STARTED' \
  "$(field "$in_force" "['standing']")/$(field "$ended" "['standing']")/$(field "$ended" "['daysToEnd']")/$(field "$future" "['standing']")"
check_equal 'the list finds each standing, kind and asset' "$expiring_id/$ended/$future/$(printf '%s\n' "$expiring_id" "$ended" | sort | paste -sd, -)" \
  "$(stb GET "$vnd/agreement/retrieve?standing=EXPIRING" | ids)/$(stb GET "$vnd/agreement/retrieve?standing=EXPIRED" | ids)/$(stb GET "$vnd/agreement/retrieve?standing=NOT_STARTED" | ids)/$(stb GET "$vnd/agreement/retrieve?assetId=$asset_id" | ids)"
check_equal 'and by vendor and kind; all four are listed' "$in_force/4" "$(stb GET "$vnd/agreement/retrieve?vendorId=$vendor&kind=CONTRACT" | ids)/$(stb GET "$vnd/agreement/retrieve" | count)"

# 3. The same reference twenty times at once is one agreement.
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: $user" \
      -d "$(agreement_json "$vendor" CONTRACT 'RACE-1' null "$(day -1)" "$(day 100)" 10)" "$vnd/agreement/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; conflict=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 409) conflict=$((conflict + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same reference registered by twenty people at once: one 201, nineteen 409, no other answer' '1/19/0' "$created_count/$conflict/$other"
check_equal 'and exactly one such agreement exists' 1 "$(stb GET "$vnd/agreement/retrieve?kind=CONTRACT" | python3 -c "import json,sys; print(sum(1 for a in json.load(sys.stdin) if a['reference']=='RACE-1'))")"
second=$(stb POST "$vnd/initiate" "$(vendor_json 'Acme Cloud' CLOUD)" | json "['id']")
check_equal 'the same reference for another vendor is fine (201)' 201 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$second" CONTRACT 'RACE-1' null "$(day -1)" "$(day 100)" 10)")"

# 4. A renewal is a new last day; pausing stops the judging.
check_equal 'the support plan is renewed: another kind and a last day a year ahead (204)' 204 \
  "$(st PUT "$vnd/agreement/$ended/update" "{\"kind\":\"CONTRACT\",\"assetId\":null,\"startsOn\":\"$(day -400)\",\"endsOn\":\"$(day 365)\",\"noticeDays\":60,\"autoRenew\":true}")"
check_equal 'it is in force again, with the reference it had' 'IN_FORCE/SUP-1/CONTRACT' "$(field "$ended" "['standing']")/$(field "$ended" "['reference']")/$(field "$ended" "['kind']")"
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$vnd/agreement/$expiring_id/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing the same agreement at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused agreement is not judged: PAUSED and no days (the field is left out)' 'PAUSED/PAUSED/None' \
  "$(field "$expiring_id" "['status']")/$(field "$expiring_id" "['standing']")/$(stb GET "$vnd/agreement/$expiring_id/retrieve" | python3 -c "import json,sys; print(json.load(sys.stdin).get('daysToEnd'))")"
check_equal 'resume' 204 "$(st PUT "$vnd/agreement/$expiring_id/control/resume")"
check_equal 'the agreement trail holds each real change once, in order' 'INITIATED,PAUSED,RESUMED' \
  "$(stb GET "$vnd/agreement/$expiring_id/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 5. An inactive vendor takes no new agreement; two people deactivating at once get one winner.
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$vnd/$second/control/deactivate" > "$tmp/d$i" ) &
done
wait
check_equal 'two people deactivating the same vendor at once: one 204 and one 409' '204/409' "$(sort "$tmp/d1" "$tmp/d2" | paste -sd/ -)"
check_equal 'an agreement with the inactive vendor is refused (409)' 409 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$second" CONTRACT 'LATE-1' null "$(day -1)" "$(day 100)" 10)")"
check_equal 'the list shows it as INACTIVE' "$second" "$(stb GET "$vnd/retrieve?status=INACTIVE" | ids)"
check_equal 'activate (204) and an agreement is accepted again (201)' '204/201' \
  "$(st PUT "$vnd/$second/control/activate")/$(st POST "$vnd/agreement/initiate" "$(agreement_json "$second" CONTRACT 'LATE-1' null "$(day -1)" "$(day 100)" 10)")"
check_equal 'the vendor trail holds each real change once, in order' 'INITIATED,DEACTIVATED,ACTIVATED' \
  "$(stb GET "$vnd/$second/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 6. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(api POST "$vnd/initiate" "$(vendor_json 'n' 'HARDWARE' | sed 's/HARDWARE/HARDWARE-secret-value/')" "${staff[@]}")
check_equal 'an unknown category is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('secret-value' in sys.stdin.read())")"
baddate=$(api POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'BAD-1' null 'secret-31/12/2026' "$(day 100)" 10)" "${staff[@]}")
check_equal 'a date that cannot be read is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$baddate")/$(api_body "$baddate" | python3 -c "import sys; print('secret' in sys.stdin.read())")"
check_equal 'an agreement that ends before it starts is refused (400)' 400 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'BAD-2' null "$(day 100)" "$(day 10)" 10)")"
check_equal 'a term over 3660 days is refused (400)' 400 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'BAD-3' null "$(day -10)" "$(day 5000)" 10)")"
check_equal 'a reference that is a sentence is refused (400)' 400 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'not an identifier' null "$(day -10)" "$(day 100)" 10)")"
check_equal 'a notice over 365 days is refused (400)' 400 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'BAD-4' null "$(day -10)" "$(day 100)" 366)")"
check_equal 'an agreement for a vendor that is not the tenant'"'"'s is a 404' 404 "$(st POST "$vnd/agreement/initiate" "$(agreement_json "$(uuid)" CONTRACT 'BAD-5' null "$(day -10)" "$(day 100)" 10)")"

# 7. Staff only, the tenant.
check_equal 'a REQUESTER cannot register a vendor (403 ERR-VND-00403)' '403/ERR-VND-00403' \
  "$(api_status "$(rq POST "$vnd/initiate" "$(vendor_json 'r' OTHER)")")/$(api_body "$(rq POST "$vnd/initiate" "$(vendor_json 'r' OTHER)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a vendor (403)' 403 "$(api_status "$(rq GET "$vnd/$vendor/retrieve")")"
check_equal 'a REQUESTER cannot record an agreement (403)' 403 "$(api_status "$(rq POST "$vnd/agreement/initiate" "$(agreement_json "$vendor" CONTRACT 'R-1' null "$(day -10)" "$(day 100)" 10)")")"
check_equal 'a REQUESTER cannot list the agreements (403)' 403 "$(api_status "$(rq GET "$vnd/agreement/retrieve")")"
check_equal 'another tenant gets a 404 for the vendor and for the agreement' '404/404' \
  "$(api_status "$(api GET "$vnd/$vendor/retrieve" "" "${other_tenant[@]}")")/$(api_status "$(api GET "$vnd/agreement/$expiring_id/retrieve" "" "${other_tenant[@]}")")"
check_equal 'and finds no vendor and no agreement' '0/0' "$(api_body "$(api GET "$vnd/retrieve" "" "${other_tenant[@]}")" | count)/$(api_body "$(api GET "$vnd/agreement/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$vnd/$vendor")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 8. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-vendor-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-vendor-registry'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('secret' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Vendor smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
