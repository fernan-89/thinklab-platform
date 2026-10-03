#!/usr/bin/env bash
# Live proof of Journey 9 (bash port of billing-smoke.ps1): plans, subscriptions and the entitlement lookup through the platform
# gateway, with the gateway recording every subscription mutation on the compliance ledger.
# Needs the stack up (docker-compose.yml starts subscription-billing, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
billing="$gateway/subscription-billing/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
executor='X-Executor: billing-smoke'
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
team_code="SMT$stamp"
pro_code="SMP$stamp"

evaluate() { api_body "$(api GET "$billing/entitlement/evaluate?feature=$1" "" "$tenant")"; }

# 1. A plan: drafted, edited, activated. Plans are platform-wide, so there is no tenant on these calls.
plan=$(api POST "$billing/plan/initiate" "{\"code\":\"$team_code\",\"name\":\"Team\",\"entitlements\":{\"assets\":500,\"sites\":-1,\"sso\":0}}")
check_status 'plan drafted through the gateway' 201 "$plan"
plan_id=$(api_body "$plan" | json "['id']")
check_equal 'a new plan is DRAFT' DRAFT "$(api_body "$plan" | json "['status']")"
check_status 'a DRAFT plan can be edited' 204 "$(api PUT "$billing/plan/$plan_id/update" '{"name":"Team edition","entitlements":{"assets":500,"sites":-1,"sso":0,"discovery":1}}')"
check_status 'plan activated' 204 "$(api PUT "$billing/plan/$plan_id/control/activate" "")"
check_status 'an ACTIVE plan cannot be edited (409)' 409 "$(api PUT "$billing/plan/$plan_id/update" '{"name":"x","entitlements":{}}')"
second=$(api POST "$billing/plan/initiate" "{\"code\":\"$pro_code\",\"name\":\"Pro\",\"entitlements\":{\"assets\":5000,\"sso\":1}}")
check_status 'a second plan drafted' 201 "$second"
check_status 'second plan activated' 204 "$(api PUT "$billing/plan/$(api_body "$second" | json "['id']")/control/activate" "")"

# 2. No subscription yet: the default plan (if one is configured and ACTIVE) or nobody-is-managing-this (allowed).
source_before=$(evaluate assets | json "['source']")
if [[ "$source_before" == "DEFAULT_PLAN" || "$source_before" == "UNMANAGED" ]]; then ok=true; else ok=false; fi
check_equal 'without a subscription the default plan or UNMANAGED decides' true "$ok"

# 3. A subscription, and the entitlements it brings.
sub=$(api POST "$billing/initiate" "{\"planCode\":\"$team_code\"}" "$tenant")
check_status 'subscription started through the gateway' 201 "$sub"
sub_id=$(api_body "$sub" | json "['id']")
check_equal 'a new subscription is TRIALING' TRIALING "$(api_body "$sub" | json "['status']")"
check_equal 'assets are decided by the subscription plan' SUBSCRIPTION "$(evaluate assets | json "['source']")"
check_equal 'assets are limited to 500' 500 "$(evaluate assets | json "['limit']")"
check_equal 'sites are unlimited: allowed, no limit' 'True/None' "$(evaluate sites | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['allowed']}/{d['limit']}\")")"
check_equal 'a feature set to 0 is not included' False "$(evaluate sso | json "['allowed']")"
check_equal 'a feature the plan never mentions is not included' False "$(evaluate nonexistent.feature | json "['allowed']")"
check_status 'activate the subscription' 204 "$(api PUT "$billing/$sub_id/control/activate" "" "$tenant")"
check_status 'move it to the Pro plan (plan/update)' 204 "$(api PUT "$billing/$sub_id/plan/update" "{\"planCode\":\"$pro_code\"}" "$tenant")"
check_equal 'SSO is now allowed, decided by the new plan' "True/$pro_code" "$(evaluate sso | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['allowed']}/{d['planCode']}\")")"
check_status 'mark it past due' 204 "$(api PUT "$billing/$sub_id/control/mark-past-due" "" "$tenant")"
check_equal 'PAST_DUE is a grace period: still allowed' True "$(evaluate sso | json "['allowed']")"
check_status 'suspend it' 204 "$(api PUT "$billing/$sub_id/control/suspend" "" "$tenant")"
check_equal 'SUSPENDED allows nothing' False "$(evaluate sso | json "['allowed']")"
check_equal 'and says why' SUSPENDED "$(evaluate sso | json "['source']")"
check_status 're-activate it' 204 "$(api PUT "$billing/$sub_id/control/activate" "" "$tenant")"

# 4. The rules: one current subscription per organisation, tenant isolation, a RETIRED plan is off sale.
other="X-Tenant-Id: $(uuid)"
check_status 'a second subscription for the same organisation is refused (409)' 409 "$(api POST "$billing/initiate" "{\"planCode\":\"$team_code\"}" "$tenant")"
check_status 'another tenant cannot read it (404)' 404 "$(api GET "$billing/$sub_id/retrieve" "" "$other")"
check_status 'another tenant cannot cancel it (404)' 404 "$(api PUT "$billing/$sub_id/control/cancel" "" "$other")"
check_status 'retire the Team plan' 204 "$(api PUT "$billing/plan/$plan_id/control/retire" "")"
check_status 'cancel the subscription' 204 "$(api PUT "$billing/$sub_id/control/cancel" "" "$tenant")"
check_status 'a RETIRED plan is not on sale (409)' 409 "$(api POST "$billing/initiate" "{\"planCode\":\"$team_code\"}" "$tenant")"
check_status 'a cancelled subscription is terminal (409)' 409 "$(api PUT "$billing/$sub_id/control/activate" "" "$tenant")"
audit=$(api_body "$(api GET "$billing/$sub_id/audit-log/retrieve" "" "$tenant")" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")
check_equal 'the subscription ledger reads in order' 'INITIATED,STATUS_CHANGED,PLAN_CHANGED,STATUS_CHANGED,STATUS_CHANGED,STATUS_CHANGED,STATUS_CHANGED' "$audit"

# 5. The gateway put every subscription mutation on the compliance ledger (the refused ones too); reads are not recorded.
expected=10
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
check_equal 'the first recorded call is the subscription initiate' 'POST /subscription-billing/v1/initiate' "$(summary "print(e[0]['action'])")"
check_equal 'the resource type is the Service Domain' subscription-billing "$(summary "print(e[0]['resourceType'])")"
check_equal 'a control call is recorded with a masked path' 'PUT /subscription-billing/v1/{id}/control/activate' "$(summary "print(e[1]['action'])")"
check_equal 'its resource id is the subscription' "$sub_id" "$(summary "print(e[1]['resourceId'])")"
check_equal 'the actor is the caller' billing-smoke "$(summary "print(e[1]['actor'])")"
check_equal 'the refused initiates are recorded with their status' 2 "$(summary "print(len([x for x in e if x['detail']=='status=409' and x['action']=='POST /subscription-billing/v1/initiate']))")"
check_equal 'no read and no plan call (platform-wide, no tenant) is recorded' 0 "$(summary "print(len([x for x in e if x['action'].startswith('GET ') or '/v1/plan/' in x['action']]))")"
integrity=$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")")
check_equal 'the tenant chain is valid' True "$(json "['valid']" <<<"$integrity")"
check_equal 'with every entry checked' "$expected" "$(json "['entriesChecked']" <<<"$integrity")"

echo
echo "Billing smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
