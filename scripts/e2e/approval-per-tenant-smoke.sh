#!/usr/bin/env bash
# Live proof of ADR-039 of it-change-management: the CAB and ECAB policies belong to the tenant.
#
# Runs against the stack's change-management (8086), which has the per-tenant switch on by default (THINKLAB_CHANGE_APPROVAL_POLICY_PER_TENANT) and workflow-approval
# the tenant-scoped policy lookup (THINKLAB_APPROVAL_POLICY_TENANT_SCOPED).
#
#   1. a tenant without settings: reading them and routing a NORMAL change are both a 422 (ERR-CHG-00422), never another tenant's policy;
#   2. the settings are set from two real policies of the tenant at workflow-approval; an unknown policy is a 400; below ADMIN it is a 403;
#   3. the NORMAL change now routes to CAB_REVIEW against the tenant's own CAB and ONE approval of its approver resolves it APPROVED
#      (the shared pair needs two, so this is not the shared policy);
#   4. an EMERGENCY change routes to ECAB_REVIEW against the tenant's own ECAB;
#   5. another tenant, with no settings of its own, is still refused (422) while the first one works.
set -uo pipefail
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
asset_api="${ASSET_URL:-http://localhost:8083}/it-asset-registry/v1"
approval_api="${WORKFLOW_APPROVAL_URL:-http://localhost:8090}/workflow-approval/v1"
chg_api="${CHANGE_MANAGEMENT_URL:-http://localhost:8086}/it-change-management/v1"
executor='X-Executor: approval-per-tenant-smoke'
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# api METHOD URL [BODY] [HEADER...] -> prints "<status>\n<body>", never exits on a non-2xx.
api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}')
  local has_executor=0
  for h in "$@"; do
    args+=(-H "$h")
    [[ "$h" == X-Executor:* ]] && has_executor=1
  done
  # a caller-supplied X-Executor (an approver's own id) replaces the default: two of them on one request make the server pick the first
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
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected $expected, got $actual: $(api_body "$response")"; fi
}
check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

make_org() {
  local tax; tax=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
  api POST "$org_api/initiate" "{\"corporateName\":\"Per-tenant $1\",\"tradeName\":\"PT $1\",\"taxIdentifier\":\"$tax\",\"billing\":{\"billingEmail\":\"b@pt.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" | tail -n +2 | json "['id']"
}

# a NORMAL or EMERGENCY change taken to ASSESSED, so it can be routed. Prints its id.
assessed_change() {
  local tenant_header=$1 type=$2 asset=$3
  local created id
  created=$(api POST "$chg_api/initiate" "{\"requesterId\":\"$(uuid)\",\"title\":\"Per-tenant $type\",\"description\":\"d\",\"changeType\":\"$type\",\"targetAssetIds\":[\"$asset\"]}" "$tenant_header")
  id=$(api_body "$created" | json "['id']")
  api PUT "$chg_api/$id/control/submit" "" "$tenant_header" >/dev/null
  api PUT "$chg_api/$id/assess" '{"riskLevel":"MEDIUM","impactLevel":"MEDIUM"}' "$tenant_header" >/dev/null
  echo "$id"
}

tenant_a=$(make_org A); tenant_b=$(make_org B)
check_equal 'two organisations created' 2 "$(printf '%s\n%s\n' "$tenant_a" "$tenant_b" | grep -c .)"
header_a="X-Tenant-Id: $tenant_a"; header_b="X-Tenant-Id: $tenant_b"

asset_response=$(api POST "$asset_api/initiate" "{\"name\":\"Per-tenant switch\",\"category\":\"NETWORK_DEVICE\",\"serialNumber\":\"SN-PT-$(uuid | cut -c1-8)\",\"specifications\":{\"model\":\"SW-1\"}}" "$header_a")
check_status 'asset of tenant A created' 201 "$asset_response"
asset_a=$(api_body "$asset_response" | json "['id']")
asset_response=$(api POST "$asset_api/initiate" "{\"name\":\"Per-tenant switch B\",\"category\":\"NETWORK_DEVICE\",\"serialNumber\":\"SN-PT-$(uuid | cut -c1-8)\",\"specifications\":{\"model\":\"SW-1\"}}" "$header_b")
asset_b=$(api_body "$asset_response" | json "['id']")

# 1. Nothing configured yet.
check_status 'a tenant without settings has none (422)' 422 "$(api GET "$chg_api/approval-settings/retrieve" "" "$header_a")"
change_a=$(assessed_change "$header_a" NORMAL "$asset_a")
check_status 'routing a NORMAL change without settings is refused (422)' 422 "$(api PUT "$chg_api/$change_a/route-for-approval" "" "$header_a")"

# 2. The tenant's own policies at workflow-approval: the CAB needs ONE approval, so a single decision resolves the change.
cab_approver=$(uuid); ecab_approver=$(uuid)
cab=$(api POST "$approval_api/policy/initiate" "{\"name\":\"CAB\",\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$cab_approver\"]}" "$header_a")
check_status 'CAB policy of tenant A created' 201 "$cab"
cab_id=$(api_body "$cab" | json "['id']")
ecab=$(api POST "$approval_api/policy/initiate" "{\"name\":\"ECAB\",\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$ecab_approver\"]}" "$header_a")
check_status 'ECAB policy of tenant A created' 201 "$ecab"
ecab_id=$(api_body "$ecab" | json "['id']")
body="{\"cabPolicyId\":\"$cab_id\",\"ecabPolicyId\":\"$ecab_id\"}"

check_status 'setting them below ADMIN is refused (403)' 403 "$(api PUT "$chg_api/approval-settings/update" "$body" "$header_a" 'X-Role: OPERATOR')"
check_status 'a policy that does not exist is refused (400)' 400 "$(api PUT "$chg_api/approval-settings/update" "{\"cabPolicyId\":\"$(uuid)\",\"ecabPolicyId\":\"$ecab_id\"}" "$header_a")"
check_status 'the settings of tenant A are stored' 200 "$(api PUT "$chg_api/approval-settings/update" "$body" "$header_a")"
read_back=$(api GET "$chg_api/approval-settings/retrieve" "" "$header_a")
check_equal 'they read back as set' "$cab_id $ecab_id" "$(api_body "$read_back" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['cabPolicyId'], d['ecabPolicyId'])")"

# 3. NORMAL: the tenant's CAB, one approval resolves it.
check_status 'route-for-approval now works (ASSESSED -> CAB_REVIEW)' 204 "$(api PUT "$chg_api/$change_a/route-for-approval" "" "$header_a")"
decision=$(api PUT "$chg_api/$change_a/approval/capture" '{"outcome":"APPROVE","comment":"own CAB"}' "$header_a" "X-Executor: $cab_approver")
check_status 'the tenant CAB approver decides' 200 "$decision"
check_equal 'one approval of the tenant CAB resolves the change (the shared pair would need two)' APPROVED "$(api_body "$decision" | json "['status']")"

# 4. EMERGENCY: the tenant's ECAB.
emergency_a=$(assessed_change "$header_a" EMERGENCY "$asset_a")
check_status 'route-for-approval of an EMERGENCY change (ASSESSED -> ECAB_REVIEW)' 204 "$(api PUT "$chg_api/$emergency_a/route-for-approval" "" "$header_a")"
check_equal 'it waits for the tenant ECAB' ECAB_REVIEW "$(api_body "$(api GET "$chg_api/$emergency_a/retrieve" "" "$header_a")" | json "['status']")"
veto=$(api PUT "$chg_api/$emergency_a/approval/capture" '{"outcome":"REJECT","comment":"own ECAB"}' "$header_a" "X-Executor: $ecab_approver")
check_equal 'a decision of the tenant ECAB approver counts' REJECTED "$(api_body "$veto" | json "['status']")"

# 5. Tenant B never borrows A's policies.
check_status 'tenant B has no settings (422)' 422 "$(api GET "$chg_api/approval-settings/retrieve" "" "$header_b")"
change_b=$(assessed_change "$header_b" NORMAL "$asset_b")
check_status 'tenant B cannot route a NORMAL change on the policy of tenant A (422)' 422 "$(api PUT "$chg_api/$change_b/route-for-approval" "" "$header_b")"
check_status 'a STANDARD change needs no policy and still routes for tenant B' 204 "$(api PUT "$chg_api/$(assessed_change "$header_b" STANDARD "$asset_b")/route-for-approval" "" "$header_b")"

echo
echo "Approval per tenant smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
