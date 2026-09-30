#!/usr/bin/env bash
# Live proof of it-change-management's two synchronous cross-service integrations (bash port of
# change-management-smoke.ps1, ADR-032 of that service): a NORMAL change routed to CAB and resolved
# APPROVED by a real quorum on workflow-approval-service, an EMERGENCY change vetoed REJECTED by a
# single ECAB decision, and a real scheduling collision surfaced by operation-window-service's existing
# collision detection (ADR-033).
#
# Needs the CAB/ECAB ApprovalPolicy ids provision-change-management.sh writes to
# thinklab-platform/.e2e/change-management-policies.json, and it-change-management restarted with
# THINKLAB_CAB_POLICY_ID/THINKLAB_ECAB_POLICY_ID already set from them - see that script and
# .github/workflows/e2e.yml for the two-phase docker-compose sequence this depends on.
set -uo pipefail
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
asset_api="${ASSET_URL:-http://localhost:8083}/it-asset-registry/v1"
chg_api="${CHANGE_MANAGEMENT_URL:-http://localhost:8086}/it-change-management/v1"
policies_file="${POLICIES_FILE:-$(dirname "$0")/../../.e2e/change-management-policies.json}"
executor='X-Executor: change-management-smoke'
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# api METHOD URL [BODY] [HEADER...] -> prints "<status>\n<body>", never exits on a non-2xx (some checks
# expect one, e.g. the 409 collision) - the caller decides with check_status/check_equal. A caller-
# supplied X-Executor header (approval/capture needs the approver's own id, not this script's default)
# replaces the default rather than being sent alongside it - two X-Executor headers on the same request
# has the server pick the first one, silently ignoring the override.
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

[[ -f "$policies_file" ]] || { echo "Missing $policies_file - run provision-change-management.sh first." >&2; exit 1; }
cab_approver_1=$(json "['cabApproverIds'][0]" <"$policies_file")
cab_approver_2=$(json "['cabApproverIds'][1]" <"$policies_file")
ecab_approver_1=$(json "['ecabApproverIds'][0]" <"$policies_file")

# 1. A real Organisation and a real Asset to be the change's target.
tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
org_response=$(api POST "$org_api/initiate" "{\"corporateName\":\"GMUD Corp\",\"tradeName\":\"GMUD\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@gmud.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}")
check_status 'organisation created' 201 "$org_response"
org_id=$(api_body "$org_response" | json "['id']")
tenant="X-Tenant-Id: $org_id"

serial="SN-GMUD-$(uuid | cut -c1-8)"
asset_response=$(api POST "$asset_api/initiate" "{\"name\":\"Core switch\",\"category\":\"NETWORK_DEVICE\",\"serialNumber\":\"$serial\",\"specifications\":{\"model\":\"SW-9000\"}}" "$tenant")
check_status 'asset created' 201 "$asset_response"
asset_id=$(api_body "$asset_response" | json "['id']")
requester_id=$(uuid)

# 2. NORMAL change -> CAB_REVIEW -> quorum-reached APPROVED -> scheduled -> implemented -> closed.
normal_response=$(api POST "$chg_api/initiate" "{\"requesterId\":\"$requester_id\",\"title\":\"Upgrade switch firmware\",\"description\":\"Routine firmware bump\",\"changeType\":\"NORMAL\",\"targetAssetIds\":[\"$asset_id\"]}" "$tenant")
check_status 'NORMAL change initiated (DRAFT)' 201 "$normal_response"
normal_id=$(api_body "$normal_response" | json "['id']")

check_status 'control/submit (DRAFT -> SUBMITTED)' 204 "$(api PUT "$chg_api/$normal_id/control/submit")"
check_status 'assess (SUBMITTED -> ASSESSED)' 204 "$(api PUT "$chg_api/$normal_id/assess" '{"riskLevel":"MEDIUM","impactLevel":"MEDIUM"}')"
check_status 'route-for-approval (ASSESSED -> CAB_REVIEW)' 204 "$(api PUT "$chg_api/$normal_id/route-for-approval")"

after_routing=$(api GET "$chg_api/$normal_id/retrieve")
check_equal 'status after routing is CAB_REVIEW' CAB_REVIEW "$(api_body "$after_routing" | json "['status']")"

decision_1=$(api PUT "$chg_api/$normal_id/approval/capture" '{"outcome":"APPROVE","comment":"Looks fine"}' "X-Executor: $cab_approver_1")
check_status 'decision 1/2 captured (still CAB_REVIEW)' 200 "$decision_1"
check_equal 'decision 1/2 leaves the change in CAB_REVIEW' CAB_REVIEW "$(api_body "$decision_1" | json "['status']")"

decision_2=$(api PUT "$chg_api/$normal_id/approval/capture" '{"outcome":"APPROVE","comment":"Agreed"}' "X-Executor: $cab_approver_2")
check_status 'decision 2/2 captured (quorum reached)' 200 "$decision_2"
check_equal 'quorum reached: change is now APPROVED' APPROVED "$(api_body "$decision_2" | json "['status']")"

planned_start=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=2)).isoformat())')
planned_end=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=4)).isoformat())')
schedule_response=$(api PUT "$chg_api/$normal_id/schedule" "{\"plannedStart\":\"$planned_start\",\"plannedEnd\":\"$planned_end\"}")
check_status 'schedule (APPROVED -> SCHEDULED, reserves a real operation-window)' 204 "$schedule_response"

after_scheduling=$(api GET "$chg_api/$normal_id/retrieve")
check_equal 'status after scheduling is SCHEDULED' SCHEDULED "$(api_body "$after_scheduling" | json "['status']")"

check_status 'control/start (SCHEDULED -> IN_PROGRESS)' 204 "$(api PUT "$chg_api/$normal_id/control/start")"
check_status 'complete (IN_PROGRESS -> IMPLEMENTED)' 204 "$(api PUT "$chg_api/$normal_id/complete" '{"implementationNotes":"Firmware updated, verified"}')"
check_status 'control/close (IMPLEMENTED -> CLOSED)' 204 "$(api PUT "$chg_api/$normal_id/control/close" '{"closeNotes":"No incidents"}')"

# 3. EMERGENCY change -> ECAB_REVIEW -> a single REJECT vetoes it immediately.
emergency_response=$(api POST "$chg_api/initiate" "{\"requesterId\":\"$requester_id\",\"title\":\"Emergency patch\",\"description\":\"CVE fix\",\"changeType\":\"EMERGENCY\",\"targetAssetIds\":[\"$asset_id\"]}" "$tenant")
check_status 'EMERGENCY change initiated (DRAFT)' 201 "$emergency_response"
emergency_id=$(api_body "$emergency_response" | json "['id']")

check_status 'control/submit' 204 "$(api PUT "$chg_api/$emergency_id/control/submit")"
check_status 'assess' 204 "$(api PUT "$chg_api/$emergency_id/assess" '{"riskLevel":"HIGH","impactLevel":"HIGH"}')"
check_status 'route-for-approval (ASSESSED -> ECAB_REVIEW)' 204 "$(api PUT "$chg_api/$emergency_id/route-for-approval")"

veto_decision=$(api PUT "$chg_api/$emergency_id/approval/capture" '{"outcome":"REJECT","comment":"Needs more testing"}' "X-Executor: $ecab_approver_1")
check_status 'single ECAB decision captured' 200 "$veto_decision"
check_equal 'single REJECT resolves the change to REJECTED' REJECTED "$(api_body "$veto_decision" | json "['status']")"

# 4. Scheduling collision: a second change against the same asset, overlapping the first (already-
#    scheduled, now CLOSED) window's time range, must be rejected by operation-window-service's own
#    collision check and surface here as ERR-CHG-00409.
collision_response=$(api POST "$chg_api/initiate" "{\"requesterId\":\"$requester_id\",\"title\":\"Conflicting change\",\"description\":\"d\",\"changeType\":\"STANDARD\",\"targetAssetIds\":[\"$asset_id\"]}" "$tenant")
check_status 'second change initiated for the collision check' 201 "$collision_response"
collision_id=$(api_body "$collision_response" | json "['id']")
check_status 'control/submit' 204 "$(api PUT "$chg_api/$collision_id/control/submit")"
check_status 'assess' 204 "$(api PUT "$chg_api/$collision_id/assess" '{"riskLevel":"LOW","impactLevel":"LOW"}')"
check_status 'route-for-approval (STANDARD, pre-approved)' 204 "$(api PUT "$chg_api/$collision_id/route-for-approval")"

collision_schedule=$(api PUT "$chg_api/$collision_id/schedule" "{\"plannedStart\":\"$planned_start\",\"plannedEnd\":\"$planned_end\"}")
check_status "schedule collides with the first change's window (409)" 409 "$collision_schedule"
check_equal 'collision error_code is ERR-CHG-00409' ERR-CHG-00409 "$(api_body "$collision_schedule" | json "['error_code']")"

echo
echo "Change management smoke: $checks checks, $failed failed"
exit $((failed > 0))
