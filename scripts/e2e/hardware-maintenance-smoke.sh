#!/usr/bin/env bash
# The WorkOrder <-> Asset event integration end to end against the running stack (bash port of
# hardware-maintenance-smoke.ps1): starting a repair moves the Asset into MAINTENANCE and passing quality
# check moves it back to DEPLOYED, both through NATS JetStream with no synchronous call between the two
# services. Postman can't prove this: it never observes the Asset's own state.
set -euo pipefail
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
asset_api="${ASSET_URL:-http://localhost:8083}/it-asset-registry/v1"
wo_api="${HARDWARE_MAINTENANCE_URL:-http://localhost:8085}/it-hardware-maintenance/v1"
executor='X-Executor: hardware-maintenance-smoke'
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
# call METHOD URL [BODY] [HEADER...] -> fails (set -e) on any non-2xx, printing the response
call() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -H "$executor" -w '\n%{http_code}')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out code
  out=$(curl "${args[@]}" "$url"); code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ "$code" != 2* ]]; then echo "$method $url -> $code: $out" >&2; return 1; fi
  printf '%s' "$out"
}
wait_asset() {
  local id=$1 tenant=$2 target=$3 status=""
  for _ in $(seq 1 10); do
    status=$(call GET "$asset_api/$id/retrieve" "" "X-Tenant-Id: $tenant" | json "['status']")
    [[ "$status" == "$target" ]] && { echo "asset is $target"; return 0; }
    sleep 2
  done
  echo "asset stayed $status, expected $target after 20s" >&2; return 1
}

tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
tenant=$(call POST "$org_api/initiate" "{\"corporateName\":\"Repairs Corp\",\"tradeName\":\"Repairs\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@repairs.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" | json "['id']")
echo "organisation created: $tenant"

# Only a DEPLOYED asset can enter MAINTENANCE.
asset_id=$(call POST "$asset_api/initiate" "{\"name\":\"Laptop for repair\",\"category\":\"LAPTOP\",\"serialNumber\":\"SN-SMOKE-$(uuid | cut -c1-8)\",\"specifications\":{\"cpu\":\"i7\"}}" "X-Tenant-Id: $tenant" | json "['id']")
call PUT "$asset_api/$asset_id/assignment/update" "{\"assignedToUserId\":\"$(uuid)\",\"locationId\":\"$(uuid)\"}" >/dev/null
call PUT "$asset_api/$asset_id/control/ready" "" >/dev/null
call PUT "$asset_api/$asset_id/control/deploy" "" >/dev/null
echo "asset $asset_id is DEPLOYED"

# Filed by the requester (self-service), then triaged, scheduled and started: control/start publishes repair-started.
requester=$(uuid)
wo_id=$(curl -sS -X POST "$wo_api/initiate" -H "X-Executor: $requester" -H 'X-Role: REQUESTER' -H "X-Tenant-Id: $tenant" \
  -H 'Content-Type: application/json' -d "{\"assetId\":\"$asset_id\",\"title\":\"Laptop wont boot\",\"symptom\":\"Black screen on power-on\",\"type\":\"CORRECTIVE\"}" | json "['id']")
echo "work order filed: $wo_id"
call PUT "$wo_api/$wo_id/triage" '{"priority":"P1"}' "X-Tenant-Id: $tenant" >/dev/null
call PUT "$wo_api/$wo_id/schedule" "" >/dev/null
call PUT "$wo_api/$wo_id/control/start" "" >/dev/null
wait_asset "$asset_id" "$tenant" MAINTENANCE

# Completed and passed: control/pass publishes repair-completed.
call PUT "$wo_api/$wo_id/control/complete-repair" '{"diagnosis":"Replaced the motherboard","additionalLaborMinutes":45}' >/dev/null
call PUT "$wo_api/$wo_id/control/pass" '{"resolutionCode":"RC-MOBO-SMOKE"}' >/dev/null
wait_asset "$asset_id" "$tenant" DEPLOYED
