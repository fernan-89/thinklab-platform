#!/usr/bin/env bash
# Live proof of Journey 12, third service (bash port of problem-smoke.ps1; problem ADR-030..033): problem management through the
# platform gateway - a problem linked to a real incident, the lifecycle with the known error (which needs both a root cause and a
# workaround), staff only, a race between two people, and every mutation (the refused ones too) recorded on the ledger.
# Needs the stack up (docker-compose.yml starts it, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
prb="$gateway/it-problem-management/v1"
inc="$gateway/it-incident-management/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

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

tenant_id=$(uuid)
staff_user=$(uuid); staff_user2=$(uuid); requester=$(uuid)
assignee=$(uuid); asset_id=$(uuid); change_id=$(uuid); filed_for=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")

# st METHOD URL [BODY] -> staff call; status / body of it
st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
# rq METHOD URL [BODY] -> as a REQUESTER (response "<status>\n<body>")
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
get_problem() { stb GET "$prb/$1/retrieve"; }
field() { json "$1" <<<"$(get_problem "$2")"; }
ids() { python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))"; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }

# 1. A problem that explains a real incident.
incident=$(api POST "$inc/initiate" "{\"title\":\"Packet loss on floor 3\",\"description\":\"Calls drop every hour\",\"impact\":\"MEDIUM\",\"urgency\":\"MEDIUM\",\"requesterId\":\"$filed_for\",\"affectedAssetIds\":[\"$asset_id\"]}" "${staff[@]}")
incident_id=$(api_body "$incident" | json "['id']")
check_equal 'an incident is opened on the incident service' 201 "$(api_status "$incident")"
opened=$(api POST "$prb/initiate" "{\"title\":\"Switch drops packets\",\"description\":\"Intermittent loss on floor 3\",\"priority\":\"P2\",\"relatedIncidentIds\":[\"$incident_id\"],\"affectedAssetIds\":[\"$asset_id\"]}" "${staff[@]}")
id=$(api_body "$opened" | json "['id']")
check_equal 'staff open a problem: 201, NEW, the priority they chose' '201/NEW/P2' "$(api_status "$opened")/$(api_body "$opened" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['priority']))")"
check_equal 'the links are kept as references' '1/1' "$(api_body "$opened" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%d/%d' % (len(d['relatedIncidentIds']), len(d['affectedAssetIds'])))")"
check_equal 'a blank title is refused (400)' 400 "$(st POST "$prb/initiate" '{"title":"","description":"d","priority":"P3"}')"
check_equal 'a missing priority is refused (400)' 400 "$(st POST "$prb/initiate" '{"title":"t","description":"d"}')"
check_equal 'the tenant is mandatory on every route (400)' 400 "$(api_status "$(api GET "$prb/$id/retrieve" "" "X-Executor: $staff_user")")"
check_equal 'the problems that explain the incident are found from the problem side' "$id" "$(stb GET "$prb/retrieve?incidentId=$incident_id" | ids)"
check_equal 'and the ones that involve the asset' "$id" "$(stb GET "$prb/retrieve?assetId=$asset_id&openOnly=true" | ids)"
check_equal 'the incident itself is untouched by the link (still NEW)' NEW "$(stb GET "$inc/$incident_id/retrieve" | json "['status']")"
check_equal 'update: P1 and a fixing change linked' 204 "$(st PUT "$prb/$id/update" "{\"title\":\"Switch drops packets\",\"description\":\"Now every hour\",\"priority\":\"P1\",\"relatedIncidentIds\":[\"$incident_id\"],\"relatedChangeIds\":[\"$change_id\"],\"affectedAssetIds\":[\"$asset_id\"]}")"
check_equal 'it is P1 with the change linked' 'P1/1' "$(get_problem "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%d' % (d['priority'], len(d['relatedChangeIds'])))")"

# 2. The lifecycle and the known error.
check_equal 'assign' 204 "$(st PUT "$prb/$id/assignment/update" "{\"assigneeId\":\"$assignee\"}")"
check_equal 'an analysis before investigating is an illegal transition (409)' 409 "$(st PUT "$prb/$id/analysis/update" '{"rootCause":"cause"}')"
check_equal 'investigate' 204 "$(st PUT "$prb/$id/control/investigate")"
check_equal 'a known error without a root cause is refused (400)' 400 "$(st PUT "$prb/$id/control/known-error")"
check_equal 'record the root cause' 204 "$(st PUT "$prb/$id/analysis/update" '{"rootCause":"Firmware 2.1 leaks buffers under load"}')"
check_equal 'a known error with no workaround is still refused (400)' 400 "$(st PUT "$prb/$id/control/known-error")"
check_equal 'an analysis that says nothing is refused (400)' 400 "$(st PUT "$prb/$id/analysis/update" '{}')"
check_equal 'record the workaround' 204 "$(st PUT "$prb/$id/analysis/update" '{"workaround":"Reboot the switch every Sunday"}')"
check_equal 'declare the known error' 204 "$(st PUT "$prb/$id/control/known-error")"
check_equal 'KNOWN_ERROR, with both the cause and the workaround' 'KNOWN_ERROR/Firmware 2.1 leaks buffers under load/Reboot the switch every Sunday' \
  "$(get_problem "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['rootCause'], d['workaround']))")"
check_equal 'a comment' 201 "$(st POST "$prb/$id/comment/initiate" '{"text":"Vendor confirmed the leak"}')"
check_equal 'close before resolving is an illegal transition (409)' 409 "$(st PUT "$prb/$id/control/close")"
check_equal 'resolve needs the resolution (400)' 400 "$(st PUT "$prb/$id/control/resolve" '{"resolution":""}')"
check_equal 'resolve with the permanent fix' 204 "$(st PUT "$prb/$id/control/resolve" '{"resolution":"Upgraded the fleet to firmware 2.2"}')"
check_equal 'a resolved problem takes no edit (409)' 409 "$(st PUT "$prb/$id/update" '{"title":"t","description":"d","priority":"P3"}')"
check_equal 'reopen needs a reason (400)' 400 "$(st PUT "$prb/$id/control/reopen" '{"reason":""}')"
check_equal 'reopen: the fix did not hold' 204 "$(st PUT "$prb/$id/control/reopen" '{"reason":"Still dropping packets"}')"
check_equal 'it is under investigation again, counted, the old resolution cleared' 'UNDER_INVESTIGATION/1/True' \
  "$(get_problem "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['reopenCount'], 'resolution' not in d))")"
check_equal 'resolve again' 204 "$(st PUT "$prb/$id/control/resolve" '{"resolution":"Replaced the faulty line card"}')"
check_equal 'close' 204 "$(st PUT "$prb/$id/control/close")"
check_equal 'a closed problem takes no comment (409)' 409 "$(st POST "$prb/$id/comment/initiate" '{"text":"late"}')"
check_equal 'the audit trail reads in order' 'INITIATED,UPDATED,ASSIGNED,INVESTIGATION_STARTED,ANALYSIS_RECORDED,ANALYSIS_RECORDED,KNOWN_ERROR_DECLARED,COMMENT_ADDED,RESOLVED,REOPENED,RESOLVED,CLOSED' \
  "$(stb GET "$prb/$id/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"
check_equal 'open-only leaves out the closed one' 0 "$(stb GET "$prb/retrieve?openOnly=true&incidentId=$incident_id" | count)"

# 3. Staff only, and the tenant.
denied=$(rq POST "$prb/initiate" '{"title":"t","description":"d","priority":"P4"}')
check_equal 'a REQUESTER cannot open a problem (403 ERR-PRB-00403)' '403/ERR-PRB-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'a REQUESTER cannot read one (403)' 403 "$(api_status "$(rq GET "$prb/$id/retrieve")")"
check_equal 'a REQUESTER cannot list them (403)' 403 "$(api_status "$(rq GET "$prb/retrieve")")"
check_equal 'a REQUESTER cannot work one (403)' 403 "$(api_status "$(rq PUT "$prb/$id/control/investigate")")"
check_equal 'a REQUESTER cannot read the audit trail (403)' 403 "$(api_status "$(rq GET "$prb/$id/audit-log/retrieve")")"
check_equal 'another tenant gets a 404 for the problem' 404 "$(api_status "$(api GET "$prb/$id/retrieve" "" "X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")")"
check_equal 'another tenant finds none by incident' 0 "$(api_body "$(api GET "$prb/retrieve?incidentId=$incident_id" "" "X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")" | count)"

# 4. A race: two people move the same problem at the same instant.
raced=$(stb POST "$prb/initiate" '{"title":"Race","description":"d","priority":"P4"}' | json "['id']")
tmp=$(mktemp -d)
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user" "$prb/$raced/control/investigate" > "$tmp/a" ) &
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user2" "$prb/$raced/control/cancel" > "$tmp/b" ) &
wait
code_a=$(cat "$tmp/a"); code_b=$(cat "$tmp/b")
unexpected=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 || "$c" == 409 ]] || unexpected=$((unexpected + 1)); done
check_equal 'each racer is told 204 or 409, never an error' 0 "$unexpected"
final=$(field "['status']" "$raced")
check_equal 'the problem ends in a legal state' True "$([[ "$final" == UNDER_INVESTIGATION || "$final" == CANCELLED ]] && echo True || echo False)"
accepted=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 ]] && accepted=$((accepted + 1)); done
# Cancelling an UNDER_INVESTIGATION problem is legal, so both may win one after the other; what must never happen is a lost or doubled
# move: the trail is the opening plus exactly one entry for every request that was answered 204.
check_equal 'the audit trail holds the opening plus one entry per accepted move' "$((1 + accepted))" "$(stb GET "$prb/$raced/audit-log/retrieve" | count)"
rm -rf "$tmp"
delete_status=$(st DELETE "$prb/$id")
check_equal 'a delete is not a thing (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 5. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-problem-management'))" <<<"$entries")
  [[ "$recorded" -ge 25 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 25 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-problem-management'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Problem smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
