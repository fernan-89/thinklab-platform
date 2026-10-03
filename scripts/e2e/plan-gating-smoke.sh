#!/usr/bin/env bash
# Live proof of plan-based feature gating (bash port of plan-gating-smoke.ps1, gateway ADR-026): a request for a Service Domain whose
# feature the tenant's plan does not include is turned away with 403 at the gateway, and a plan change or a suspension is felt within
# the cache time. Needs the stack up WITH the plan-gating profile (docker compose --profile plan-gating): a second gateway on 8188 with
# gating on and a 1 second cache. The ordinary gateway (8088) has gating off, so every other smoke is unaffected.
set -uo pipefail
gated="${GATED_URL:-http://localhost:8188}"
plain="${GATEWAY_URL:-http://localhost:8088}"
billing="$gated/subscription-billing/v1"
executor='X-Executor: plan-gating-smoke'
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

# check_not_refused NAME RESPONSE: the plan did not turn the request away (the upstream may answer anything else).
check_not_refused() {
  local name=$1 response=$2
  local code; code=$(api_status "$response")
  checks=$((checks + 1))
  if [[ "$code" != "403" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> got 403: $(api_body "$response")"; fi
}

# The second gateway may still be starting when the stack was just brought up.
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$gated/health/liveness" && break; sleep 2; done

tenant_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
stamp=$(date +%s%3N)
basic_code="PGB$stamp"
full_code="PGF$stamp"
ledger_path='/compliance-audit-ledger/v1/retrieve?limit=1'
federation_path='/identity-federation/v1/retrieve'
discovery_path='/it-discovery/v1/retrieve'
asset_path='/it-asset-registry/v1/retrieve'

get_gated() { api GET "$gated$1" "" "$tenant"; }

# Two plans: one that leaves audit and sso out, one that includes them.
basic=$(api POST "$billing/plan/initiate" "{\"code\":\"$basic_code\",\"name\":\"Basic\",\"entitlements\":{\"discovery\":1,\"audit\":0,\"sso\":0}}")
check_status 'basic plan drafted' 201 "$basic"
check_status 'basic plan activated' 204 "$(api PUT "$billing/plan/$(api_body "$basic" | json "['id']")/control/activate" "")"
full=$(api POST "$billing/plan/initiate" "{\"code\":\"$full_code\",\"name\":\"Full\",\"entitlements\":{\"discovery\":1,\"audit\":1,\"sso\":1}}")
check_status 'full plan drafted' 201 "$full"
check_status 'full plan activated' 204 "$(api PUT "$billing/plan/$(api_body "$full" | json "['id']")/control/activate" "")"

# Without a subscription the default plan decides, or nothing does (UNMANAGED, allowed): the gateway must agree with billing either way.
verdict=$(api_body "$(api GET "$billing/entitlement/evaluate?feature=audit" "" "$tenant")" | json "['allowed']")
no_subscription=$(api_status "$(get_gated "$ledger_path")")
if [[ "$verdict" == "True" ]]; then expected_refused=no; else expected_refused=yes; fi
if [[ "$no_subscription" == "403" ]]; then refused=yes; else refused=no; fi
check_equal 'without a subscription the gateway agrees with billing (default plan, or fail-open when unmanaged)' "$expected_refused" "$refused"

sub=$(api POST "$billing/initiate" "{\"planCode\":\"$basic_code\"}" "$tenant")
check_status 'subscription started on the basic plan' 201 "$sub"
sub_id=$(api_body "$sub" | json "['id']")
check_status 'subscription activated' 204 "$(api PUT "$billing/$sub_id/control/activate" "" "$tenant")"
sleep 2   # let a cached "no subscription" answer expire

# 1. The basic plan: ledger and federation refused, discovery and the asset registry open.
ledger=$(get_gated "$ledger_path")
check_status 'the ledger is refused: 403' 403 "$ledger"
check_equal 'with the gateway error code' ERR-GTW-00403 "$(api_body "$ledger" | json "['error_code']")"
check_equal 'saying which feature the plan lacks' "Your plan does not include 'audit'." "$(api_body "$ledger" | json "['detail']")"
check_status 'identity federation is refused: 403' 403 "$(get_gated "$federation_path")"
check_not_refused 'discovery (included in the plan) is not refused by the plan' "$(get_gated "$discovery_path")"
check_not_refused 'the asset registry (not gated) is not refused by the plan' "$(get_gated "$asset_path")"

# 2. Sign-in routes carry no tenant, so a plan never blocks them.
check_not_refused 'sign-in is not blocked by a plan (no tenant on it)' "$(api GET "$gated/identity-federation/v1/login/initiate?organisationId=$tenant_id" "")"

# The ordinary gateway has gating off: the same call is never refused by a plan.
check_not_refused 'the ordinary gateway (gating off) does not refuse the ledger' "$(api GET "$plain$ledger_path" "" "$tenant")"

# 3. A plan that includes audit: opens within the cache time.
check_status 'move the subscription to the full plan' 204 "$(api PUT "$billing/$sub_id/plan/update" "{\"planCode\":\"$full_code\"}" "$tenant")"
sleep 2
check_not_refused 'the ledger now opens (plan change felt within the cache time)' "$(get_gated "$ledger_path")"
check_not_refused 'federation now opens too' "$(get_gated "$federation_path")"

# 4. Suspended: every gated domain is refused, ungated ones still answer.
check_status 'suspend the subscription' 204 "$(api PUT "$billing/$sub_id/control/suspend" "" "$tenant")"
sleep 2
check_status 'suspended: the ledger is refused' 403 "$(get_gated "$ledger_path")"
check_status 'suspended: discovery is refused too' 403 "$(get_gated "$discovery_path")"
check_not_refused 'suspended: the asset registry (not gated) still answers' "$(get_gated "$asset_path")"
check_status 're-activate the subscription' 204 "$(api PUT "$billing/$sub_id/control/activate" "" "$tenant")"
sleep 2
check_not_refused 're-activated: the ledger opens again' "$(get_gated "$ledger_path")"

# Tidy: cancel so the tenant leaves nothing active behind.
check_status 'cancel the subscription' 204 "$(api PUT "$billing/$sub_id/control/cancel" "" "$tenant")"

echo "Plan gating smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
