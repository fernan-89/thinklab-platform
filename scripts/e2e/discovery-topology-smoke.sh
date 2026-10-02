#!/usr/bin/env bash
# Live proof of Journey 10 (bash port of discovery-topology-smoke.ps1): discovery -> promotion into a real
# Asset, tenant-configured specification schemas enforced by it-asset-registry (ADR-027) and relayed by
# it-discovery as ERR-DSC-00422 (ADR-032), and a real $graphLookup blast radius on it-topology-graph
# (ADR-031). Needs the stack up, including it-discovery, it-topology-graph and ci-type-catalog.
set -uo pipefail
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
asset_api="${ASSET_URL:-http://localhost:8083}/it-asset-registry/v1"
disc_api="${DISCOVERY_URL:-http://localhost:8091}/it-discovery/v1"
topo_api="${TOPOLOGY_URL:-http://localhost:8092}/it-topology-graph/v1"
catalog_api="${CATALOG_URL:-http://localhost:8093}/ci-type-catalog/v1"
executor='X-Executor: discovery-topology-smoke'
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
short() { uuid | tr -d '-' | cut -c1-10; }

# api METHOD URL [BODY] [HEADER...] -> prints "<status>\n<body>", never exits on a non-2xx. A caller-supplied
# X-Executor replaces the default instead of being sent next to it (see change-management-smoke.sh).
api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}')
  local has_executor=0
  for h in "$@"; do
    args+=(-H "$h")
    [[ "$h" == X-Executor:* ]] && has_executor=1
  done
  ((has_executor)) || args+=(-H "$executor")
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
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name -> expected $expected, got $actual: $(api_body "$response")"
  fi
}

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name -> expected [$expected], got [$actual]"
  fi
}

# radius NODE_ID DIRECTION [MAX_HOPS] -> "label:hops,label:hops" ordered by hops then label
radius() {
  local response; response=$(api GET "$topo_api/$1/blast-radius/retrieve?direction=$2&maxHops=${3:-3}" "" "$tenant")
  api_body "$response" | python3 -c 'import json,sys; print(",".join("%s:%d" % (n["label"], n["hops"]) for n in sorted(json.load(sys.stdin)["impactedNodes"], key=lambda n: (n["hops"], n["label"]))))'
}

# 0. A real Organisation (the tenant for everything below).
tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
org_response=$(api POST "$org_api/initiate" "{\"corporateName\":\"Journey10 Corp\",\"tradeName\":\"J10\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@j10.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}")
check_status 'organisation created' 201 "$org_response"
org_id=$(api_body "$org_response" | json "['id']")
tenant="X-Tenant-Id: $org_id"

# 1. Discovery: ingest -> claim -> review/update -> promote -> a REAL Asset.
external_key="AA:BB:$(short)"
ingest=$(api POST "$disc_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"$external_key\",\"name\":\"Mystery sensor\",\"rawAttributes\":{\"mac\":\"$external_key\"}}" "$tenant")
check_status 'ingest creates the item (201)' 201 "$ingest"
item_id=$(api_body "$ingest" | json "['id']")
again=$(api POST "$disc_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"$external_key\",\"name\":\"Mystery sensor\",\"rawAttributes\":{\"mac\":\"$external_key\",\"vendor\":\"Acme\"}}" "$tenant")
check_status 're-ingesting the same key is idempotent (200)' 200 "$again"
check_equal 're-sighting keeps the same id' "$item_id" "$(api_body "$again" | json "['id']")"
check_status 'promote straight from DISCOVERED is refused (409)' 409 "$(api PUT "$disc_api/$item_id/control/promote")"
check_status 'review/claim' 204 "$(api PUT "$disc_api/$item_id/review/claim")"
check_status 'promote without a suggestedCategory is refused (409)' 409 "$(api PUT "$disc_api/$item_id/control/promote")"
check_status 'review/update records the category' 204 "$(api PUT "$disc_api/$item_id/review/update" '{"suggestedCategory":"IOT_SENSOR"}')"
promoted=$(api PUT "$disc_api/$item_id/control/promote")
check_status 'promote creates the Asset' 200 "$promoted"
check_equal 'item is PROMOTED' PROMOTED "$(api_body "$promoted" | json "['status']")"
promoted_asset_id=$(api_body "$promoted" | json "['promotedAssetId']")
real_asset=$(api GET "$asset_api/$promoted_asset_id/retrieve")
check_status 'the promoted Asset really exists on it-asset-registry' 200 "$real_asset"
check_equal 'its serial number is the externalKey' "$external_key" "$(api_body "$real_asset" | json "['serialNumber']")"
check_equal 'its category is the suggested one' IOT_SENSOR "$(api_body "$real_asset" | json "['category']")"
reseen_terminal=$(api POST "$disc_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"$external_key\",\"name\":\"Mystery sensor\",\"rawAttributes\":{\"mac\":\"$external_key\"}}" "$tenant")
check_equal 're-detecting a PROMOTED item never reopens it' PROMOTED "$(api_body "$reseen_terminal" | json "['status']")"

# 2. Tenant-configured specification schema (ADR-027) enforced by it-asset-registry, relayed by it-discovery.
definition=$(api POST "$catalog_api/initiate" '{"category":"VIRTUAL_MACHINE","jsonSchema":"{\"type\":\"object\",\"required\":[\"cpu\"]}"}' "$tenant")
check_status 'TypeDefinition (VIRTUAL_MACHINE) created' 201 "$definition"
definition_id=$(api_body "$definition" | json "['id']")
check_status 'TypeDefinition activated' 204 "$(api PUT "$catalog_api/$definition_id/control/activate")"

bad=$(api POST "$asset_api/initiate" "{\"name\":\"vm-bad\",\"category\":\"VIRTUAL_MACHINE\",\"serialNumber\":\"VM-BAD-$(short)\",\"specifications\":{}}" "$tenant")
check_status 'non-conforming specifications are rejected (422)' 422 "$bad"
check_equal 'asset error_code is ERR-AST-00422' ERR-AST-00422 "$(api_body "$bad" | json "['error_code']")"
good=$(api POST "$asset_api/initiate" "{\"name\":\"vm-good\",\"category\":\"VIRTUAL_MACHINE\",\"serialNumber\":\"VM-OK-$(short)\",\"specifications\":{\"cpu\":\"4\"}}" "$tenant")
check_status 'conforming specifications are accepted (201)' 201 "$good"
no_schema=$(api POST "$asset_api/initiate" "{\"name\":\"laptop\",\"category\":\"LAPTOP\",\"serialNumber\":\"LP-$(short)\",\"specifications\":{}}" "$tenant")
check_status 'a category with no schema is unaffected (201)' 201 "$no_schema"

vm_key="VM:$(short)"
vm_item=$(api POST "$disc_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"$vm_key\",\"name\":\"vm-discovered\",\"rawAttributes\":{\"hostname\":\"vm1\"}}" "$tenant")
check_status 'VM item ingested' 201 "$vm_item"
vm_id=$(api_body "$vm_item" | json "['id']")
check_status 'VM item claimed' 204 "$(api PUT "$disc_api/$vm_id/review/claim")"
check_status 'VM item categorised' 204 "$(api PUT "$disc_api/$vm_id/review/update" '{"suggestedCategory":"VIRTUAL_MACHINE"}')"
rejected=$(api PUT "$disc_api/$vm_id/control/promote")
check_status 'promotion violating the schema is relayed (422)' 422 "$rejected"
check_equal 'discovery error_code is ERR-DSC-00422' ERR-DSC-00422 "$(api_body "$rejected" | json "['error_code']")"
check_equal 'the item stayed UNDER_REVIEW' UNDER_REVIEW "$(api_body "$(api GET "$disc_api/$vm_id/retrieve")" | json "['status']")"
resight=$(api POST "$disc_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"$vm_key\",\"name\":\"vm-discovered\",\"rawAttributes\":{\"hostname\":\"vm1\",\"cpu\":\"8\"}}" "$tenant")
check_status 're-sighting supplies the missing cpu attribute (200)' 200 "$resight"
check_equal 'promotion now succeeds' PROMOTED "$(api_body "$(api PUT "$disc_api/$vm_id/control/promote")" | json "['status']")"

# 3. Topology: web -> app -> db, exact blast radius per direction ($graphLookup on a real MongoDB).
# new_node LABEL VAR -> creates the node and stores its id in VAR (no command substitution, so the
# check counters of check_status survive).
new_node() {
  local response; response=$(api POST "$topo_api/initiate" "{\"nodeType\":\"ASSET\",\"externalId\":\"$(uuid)\",\"label\":\"$1\"}" "$tenant")
  check_status "node '$1' created" 201 "$response"
  printf -v "$2" '%s' "$(api_body "$response" | json "['id']")"
}
new_node web web; new_node app app; new_node db db
e1=$(api POST "$topo_api/edge/initiate" "{\"relationshipType\":\"DEPENDS_ON\",\"sourceNodeId\":\"$web\",\"targetNodeId\":\"$app\"}" "$tenant")
e2=$(api POST "$topo_api/edge/initiate" "{\"relationshipType\":\"DEPENDS_ON\",\"sourceNodeId\":\"$app\",\"targetNodeId\":\"$db\"}" "$tenant")
check_status 'edge web -> app created' 201 "$e1"
check_status 'edge app -> db created' 201 "$e2"
check_status 'duplicate edge is refused (409)' 409 "$(api POST "$topo_api/edge/initiate" "{\"relationshipType\":\"DEPENDS_ON\",\"sourceNodeId\":\"$web\",\"targetNodeId\":\"$app\"}" "$tenant")"
check_equal 'web DOWNSTREAM reaches app(1), db(2)' 'app:1,db:2' "$(radius "$web" DOWNSTREAM)"
check_equal 'db UPSTREAM reaches app(1), web(2)' 'app:1,web:2' "$(radius "$db" UPSTREAM)"
check_equal 'app BOTH reaches db(1), web(1)' 'db:1,web:1' "$(radius "$app" BOTH)"
check_equal 'maxHops=1 stops at the first hop' 'app:1' "$(radius "$web" DOWNSTREAM 1)"
edge2_id=$(api_body "$e2" | json "['id']")
check_status 'retire the app -> db edge' 204 "$(api PUT "$topo_api/edge/$edge2_id/control/retire")"
check_equal 'a RETIRED edge is no longer traversed' 'app:1' "$(radius "$web" DOWNSTREAM)"
check_status 'maxHops above the cap is refused (400)' 400 "$(api GET "$topo_api/$web/blast-radius/retrieve?maxHops=11" "" "$tenant")"
check_status 'another tenant cannot see the node (404)' 404 "$(api GET "$topo_api/$web/blast-radius/retrieve" "" "X-Tenant-Id: $(uuid)")"

echo
echo "Discovery + topology smoke: $checks checks, $failed failed"
exit $((failed > 0))
