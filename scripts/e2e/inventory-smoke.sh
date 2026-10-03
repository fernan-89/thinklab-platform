#!/usr/bin/env bash
# Live proof of Journey 13 (bash port of inventory-smoke.ps1): stock items and their movements through the platform gateway, the
# balance never going below zero even under concurrent issues, and the gateway recording every stock mutation on the compliance ledger.
# Needs the stack up (docker-compose.yml starts consumable-inventory, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
stock="$gateway/consumable-inventory/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
executor='X-Executor: inventory-smoke'
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# api METHOD URL [BODY] [HEADER...] -> prints "<status>\n<body>", never exits on a non-2xx.
api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}' -H "$executor")
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out; out=$(curl "${args[@]}" "$url")
  local code=${out##*$'\n'}; local content=${out%$'\n'*}
  printf '%s\n%s' "$code" "$content"
}
api_status() { head -1 <<<"$1"; }
api_body() { tail -n +2 <<<"$1"; }

check_status() {
  local name=$1 expected=$2 response=$3
  local actual; actual=$(api_status "$response")
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected $expected, got $actual: $(api_body "$response")"; fi
}

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

tenant_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
stamp=$(date +%s%3N)
balance() { api_body "$(api GET "$stock/$1/retrieve" "" "$tenant")"; }

# 1. An item and its movements.
a=$(api POST "$stock/initiate" "{\"sku\":\"smk-toner-$stamp\",\"name\":\"HP 85A toner\",\"unit\":\"unit\",\"reorderLevel\":3,\"initialQuantity\":10}" "$tenant")
check_status 'item registered through the gateway' 201 "$a"
a_id=$(api_body "$a" | json "['id']")
check_equal 'the SKU is normalised to upper case' "SMK-TONER-$stamp" "$(api_body "$a" | json "['sku']")"
check_equal 'it starts with the opening balance' 10 "$(api_body "$a" | json "['onHand']")"
check_status 'the same SKU again is refused (409), whatever its case' 409 "$(api POST "$stock/initiate" "{\"sku\":\"SMK-TONER-$stamp\",\"name\":\"again\",\"unit\":\"unit\",\"reorderLevel\":1}" "$tenant")"
check_status 'receive 5' 204 "$(api PUT "$stock/$a_id/movement/receive" '{"quantity":5,"reason":"delivery"}' "$tenant")"
check_equal 'the balance is 15' 15 "$(balance "$a_id" | json "['onHand']")"
check_status 'issue 12' 204 "$(api PUT "$stock/$a_id/movement/issue" '{"quantity":12,"reason":"printers"}' "$tenant")"
check_equal 'the balance is 3' 3 "$(balance "$a_id" | json "['onHand']")"
check_equal '3 on hand is at the reorder level: flagged low' True "$(balance "$a_id" | json "['belowReorderLevel']")"
check_equal 'the low-stock list names it' True "$(api_body "$(api GET "$stock/low-stock/retrieve" "" "$tenant")" | python3 -c "import json,sys; print(any(i['id']==sys.argv[1] for i in json.load(sys.stdin)))" "$a_id")"
refused=$(api PUT "$stock/$a_id/movement/issue" '{"quantity":4}' "$tenant")
check_status 'an issue larger than the balance is refused (409)' 409 "$refused"
check_equal 'and the refusal says there is not enough' True "$(api_body "$refused" | python3 -c "import json,sys; print('only 3 on hand' in json.load(sys.stdin)['detail'])")"
check_equal 'nothing changed' 3 "$(balance "$a_id" | json "['onHand']")"
check_status 'an adjustment without a reason is refused (400)' 400 "$(api PUT "$stock/$a_id/movement/adjust" '{"newQuantity":8}' "$tenant")"
check_status 'a counted adjustment with its reason' 204 "$(api PUT "$stock/$a_id/movement/adjust" '{"newQuantity":8,"reason":"recount after audit"}' "$tenant")"
check_equal 'the balance is the counted 8' 8 "$(balance "$a_id" | json "['onHand']")"
check_equal 'which is above the reorder level again' False "$(balance "$a_id" | json "['belowReorderLevel']")"

# 2. Concurrency: eight callers race to issue one unit each from five units.
b=$(api POST "$stock/initiate" "{\"sku\":\"smk-race-$stamp\",\"name\":\"Spare SSD\",\"unit\":\"unit\",\"reorderLevel\":1,\"initialQuantity\":5}" "$tenant")
check_status 'a second item with 5 units registered' 201 "$b"
b_id=$(api_body "$b" | json "['id']")
codes_dir=$(mktemp -d)
for i in $(seq 1 8); do
  ( curl -s -o /dev/null -w '%{http_code}' -X PUT -H "$executor" -H "$tenant" -H 'Content-Type: application/json' -d '{"quantity":1,"reason":"race"}' "$stock/$b_id/movement/issue" > "$codes_dir/$i" ) &
done
wait
codes=$(for f in "$codes_dir"/*; do cat "$f"; echo; done)
check_equal 'exactly five of the eight concurrent issues succeeded' 5 "$(grep -c '^204$' <<<"$codes")"
check_equal 'and the other three were refused (409)' 3 "$(grep -c '^409$' <<<"$codes")"
rm -rf "$codes_dir"
check_equal 'the balance ends at exactly 0, never below' 0 "$(balance "$b_id" | json "['onHand']")"
race_history=$(api_body "$(api GET "$stock/$b_id/history/retrieve" "" "$tenant")")
check_equal 'the history has the opening entry and five issues' 6 "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$race_history")"
check_equal 'newest first, and every issue is a -1' '-1,-1,-1,-1,-1' "$(python3 -c "import json,sys; print(','.join(str(e['quantity']) for e in json.loads(sys.argv[1])[:5]))" "$race_history")"

# 3. Update, discontinue, and the rules around them.
check_status 'update name, unit and reorder level' 204 "$(api PUT "$stock/$a_id/update" '{"name":"HP 85A toner (2 pack)","unit":"pack","reorderLevel":10}' "$tenant")"
check_equal 'the new reorder level flags 8 as low' True "$(balance "$a_id" | json "['belowReorderLevel']")"
check_status 'discontinue' 204 "$(api PUT "$stock/$a_id/control/discontinue" "" "$tenant")"
check_status 'a discontinued item accepts no movement (409)' 409 "$(api PUT "$stock/$a_id/movement/receive" '{"quantity":1}' "$tenant")"
check_equal 'it keeps its balance' 8 "$(balance "$a_id" | json "['onHand']")"
check_equal 'and is no longer on the low-stock list' False "$(api_body "$(api GET "$stock/low-stock/retrieve" "" "$tenant")" | python3 -c "import json,sys; print(any(i['id']==sys.argv[1] for i in json.load(sys.stdin)))" "$a_id")"
other="X-Tenant-Id: $(uuid)"
check_status 'another tenant cannot read it (404)' 404 "$(api GET "$stock/$a_id/retrieve" "" "$other")"
check_status 'another tenant cannot move it (404)' 404 "$(api PUT "$stock/$a_id/movement/receive" '{"quantity":1}' "$other")"
audit=$(api_body "$(api GET "$stock/$a_id/history/retrieve" "" "$tenant")" | python3 -c "import json,sys; print(','.join(f\"{e['action']}:{e['balanceAfter']}\" for e in json.load(sys.stdin)))")
check_equal 'the history reads newest first with signed balances' 'DISCONTINUED:8,UPDATED:8,ADJUSTED:8,ISSUED:3,RECEIVED:15,INITIATED:10' "$audit"

# 4. The gateway put every stock mutation on the compliance ledger (the refused ones too); reads are not recorded.
expected=19
entries='[]'
for _ in $(seq 1 30); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=100" "" "$tenant")")
  [[ $(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$entries") -ge $expected ]] && break
  sleep 0.5
done
summary() { python3 -c "
import json,sys
e = sorted(json.loads(sys.argv[1]), key=lambda x: x['sequence'])
$1
" "$entries"; }
check_equal 'every mutation with the tenant is on the ledger' "$expected" "$(summary 'print(len(e))')"
check_equal 'the first recorded call is the first registration' 'POST /consumable-inventory/v1/initiate' "$(summary "print(e[0]['action'])")"
check_equal 'the resource type is the Service Domain' consumable-inventory "$(summary "print(e[0]['resourceType'])")"
check_equal 'a movement is recorded with a masked path' 'PUT /consumable-inventory/v1/{id}/movement/receive' "$(summary "print(e[2]['action'])")"
check_equal 'its resource id is the item' "$a_id" "$(summary "print(e[2]['resourceId'])")"
check_equal 'the actor is the caller' inventory-smoke "$(summary "print(e[2]['actor'])")"
check_equal 'every refused call is recorded with its status (duplicate SKU, big issue, 3 lost races, discontinued)' 6 "$(summary "print(len([x for x in e if x['detail']=='status=409']))")"
check_equal 'reads are not recorded' 0 "$(summary "print(len([x for x in e if x['action'].startswith('GET ')]))")"
integrity=$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")")
check_equal 'the tenant chain is valid' True "$(json "['valid']" <<<"$integrity")"
check_equal 'with every entry checked' "$expected" "$(json "['entriesChecked']" <<<"$integrity")"

echo
echo "Inventory smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
