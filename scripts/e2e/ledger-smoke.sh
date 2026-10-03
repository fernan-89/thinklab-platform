#!/usr/bin/env bash
# Live proof of Journey 8 (bash port of ledger-smoke.ps1): the platform gateway records every mutating request on the
# compliance ledger (ADR-023 of the gateway, ADR-032 of the ledger), and the ledger's hash chain verifies (ADR-030/031).
# Needs the stack up with the gateway started with GATEWAY_AUDIT_ENABLED=true (docker-compose.yml sets it) and the ledger.
set -uo pipefail
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
gateway="${GATEWAY_URL:-http://localhost:8088}"
gw_asset="$gateway/it-asset-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
executor='X-Executor: ledger-smoke'
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

# 0. A real Organisation (the tenant whose chain we inspect).
tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
org_response=$(api POST "$org_api/initiate" "{\"corporateName\":\"Ledger Corp\",\"tradeName\":\"LED\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@led.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}")
check_status 'organisation created' 201 "$org_response"
org_id=$(api_body "$org_response" | json "['id']")
tenant="X-Tenant-Id: $org_id"

# 1. Mutations through the gateway: three that succeed, a read that must not be recorded, one that is refused.
serial="SN-LED-$(uuid | tr -d '-' | cut -c1-8)"
created=$(api POST "$gw_asset/initiate" "{\"name\":\"Audited switch\",\"category\":\"NETWORK_DEVICE\",\"serialNumber\":\"$serial\",\"specifications\":{\"model\":\"SW-1\"}}" "$tenant")
check_status 'asset initiated through the gateway' 201 "$created"
asset_id=$(api_body "$created" | json "['id']")
check_status 'assignment/update through the gateway' 204 "$(api PUT "$gw_asset/$asset_id/assignment/update" "{\"locationId\":\"$(uuid)\"}" "$tenant")"
check_status 'control/ready through the gateway' 204 "$(api PUT "$gw_asset/$asset_id/control/ready" "" "$tenant")"
check_status 'a read through the gateway' 200 "$(api GET "$gw_asset/$asset_id/retrieve" "" "$tenant")"
check_status 'control/ready again is refused (409)' 409 "$(api PUT "$gw_asset/$asset_id/control/ready" "" "$tenant")"

# 2. The gateway appends asynchronously: wait (bounded) until all four land.
entries='[]'
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve" "" "$tenant")")
  [[ $(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$entries") -ge 4 ]] && break
  sleep 0.5
done
count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$entries")
check_equal 'exactly the four mutations were recorded (the read was not)' 4 "$count"

# Newest first: [0]=refused, [1]=ready, [2]=assignment, [3]=initiate.
field() { python3 -c "import json,sys; print(json.loads(sys.argv[1])[$1]$2)" "$entries"; }
check_equal 'oldest: POST initiate, masked' 'POST /it-asset-registry/v1/initiate' "$(field 3 "['action']")"
check_equal 'oldest: status=201' 'status=201' "$(field 3 "['detail']")"
check_equal 'assignment/update, masked' 'PUT /it-asset-registry/v1/{id}/assignment/update' "$(field 2 "['action']")"
check_equal 'control/ready, masked' 'PUT /it-asset-registry/v1/{id}/control/ready' "$(field 1 "['action']")"
check_equal 'control/ready: the resource id is the asset' "$asset_id" "$(field 1 "['resourceId']")"
check_equal 'the refused call is on the ledger too, with its status' 'status=409' "$(field 0 "['detail']")"
check_equal 'actor is the caller (X-Executor)' 'ledger-smoke' "$(field 1 "['actor']")"
check_equal 'resourceType is the Service Domain' 'it-asset-registry' "$(field 1 "['resourceType']")"
check_equal 'source is the gateway' 'platform-gateway' "$(field 1 "['source']")"
check_equal 'the writer recorded as executor is the gateway' 'platform-gateway' "$(field 1 "['recordedBy']")"

# 3. The entries form one chain.
check_equal 'positions 1..4 (oldest to newest)' '1,2,3,4' "$(python3 -c "import json,sys; print(','.join(str(e['sequence']) for e in reversed(json.loads(sys.argv[1]))))" "$entries")"
check_equal 'the first entry sits on the genesis hash' "$(printf '0%.0s' $(seq 1 64))" "$(field 3 "['previousHash']")"
check_equal 'each entry links to the one before' 'True' "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); print(all(e[i]['previousHash']==e[i+1]['hash'] for i in range(3)))" "$entries")"

by_resource=$(api_body "$(api GET "$ledger_api/retrieve?resourceType=it-asset-registry&resourceId=$asset_id" "" "$tenant")")
check_equal 'filtering by resource id finds the three calls on that asset' 3 "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$by_resource")"

# 4. Integrity, directly and through the gateway (reads are not recorded, so the chain does not grow).
direct=$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")")
head_hash=$(field 0 "['hash']")
check_equal 'chain is valid' 'True' "$(json "['valid']" <<<"$direct")"
check_equal 'four entries checked' 4 "$(json "['entriesChecked']" <<<"$direct")"
check_equal 'head hash is the newest entry hash' "$head_hash" "$(json "['headHash']" <<<"$direct")"
via_gateway=$(api GET "$gateway/compliance-audit-ledger/v1/integrity-check/evaluate" "" "$tenant")
check_status 'integrity check is reachable through the gateway' 200 "$via_gateway"
check_equal 'same verdict through the gateway' "$head_hash" "$(api_body "$via_gateway" | json "['headHash']")"

# 5. Another tenant sees none of it.
other=$(api_body "$(api GET "$ledger_api/retrieve" "" "X-Tenant-Id: $(uuid)")")
check_equal 'another tenant has an empty ledger' 0 "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$other")"

# 6. Data protection (ledger ADR-033, gateway ADR-024): a sign-in attempt is recorded with a keyed pseudonym of the email and the
#    outcome - and neither the password nor the email appears anywhere on the ledger.
secret_user="smoke.$(uuid | tr -d '-' | cut -c1-8)"
secret_email="$secret_user@example.com"
secret_password="Sm0ke-P@ss-$(uuid | tr -d '-' | cut -c1-8)"
sign_in=$(api POST "$gateway/party-authentication/v1/session/initiate" "{\"organisationId\":\"$org_id\",\"email\":\"$secret_email\",\"password\":\"$secret_password\"}")
sign_in_status=$(api_status "$sign_in")
check_equal 'a sign-in with unknown credentials is refused (4xx)' 'True' "$([[ $sign_in_status -ge 400 && $sign_in_status -lt 500 ]] && echo True || echo False)"
login_entry=''
for _ in $(seq 1 20); do
  login_entry=$(api_body "$(api GET "$ledger_api/retrieve?limit=50" "" "$tenant")" | python3 -c "import json,sys; m=[e for e in json.load(sys.stdin) if e['action']=='POST /party-authentication/v1/session/initiate']; print(json.dumps(m[0]) if m else '')")
  [[ -n "$login_entry" ]] && break
  sleep 0.5
done
check_equal 'the sign-in attempt was recorded' 'True' "$([[ -n "$login_entry" ]] && echo True || echo False)"
[[ -z "$login_entry" ]] && login_entry='{}'
login_actor=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['actor'])" "$login_entry" 2>/dev/null || echo '')
check_equal 'actor is a keyed pseudonym, not the email' 'True' "$(python3 -c "import re,sys; print(bool(re.fullmatch(r'login:[0-9a-f]{32}', sys.argv[1])))" "$login_actor")"
check_equal 'the outcome is recorded' "status=$sign_in_status" "$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['detail'])" "$login_entry" 2>/dev/null || echo '')"
ledger_dump=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
check_equal 'the password appears nowhere on the ledger' 'False' "$([[ "$ledger_dump" == *"$secret_password"* ]] && echo True || echo False)"
check_equal 'the email appears nowhere on the ledger' 'False' "$([[ "${ledger_dump,,}" == *"${secret_user,,}"* ]] && echo True || echo False)"
check_equal 'the chain is still valid with the sign-in entry on it' 'True' "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo
echo "Ledger smoke: $checks checks, $failed failed"
exit $((failed > 0))
