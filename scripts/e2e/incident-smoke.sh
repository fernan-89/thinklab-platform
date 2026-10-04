#!/usr/bin/env bash
# Live proof of Journey 12, first service (bash port of incident-smoke.ps1; incident ADR-030..033): incident management through the
# platform gateway - the derived priority, the lifecycle and SLA, requester self-service, a race between two people, links and filters,
# and every mutation (the refused ones too) recorded on the ledger.
# Needs the stack up (docker-compose.yml starts it, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
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
staff_user=$(uuid); staff_user2=$(uuid); requester_a=$(uuid); requester_b=$(uuid)
assignee=$(uuid); asset_id=$(uuid); filed_for=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")
as_requester() { echo "X-Executor: $1"; }
req_headers() { printf '%s\n' "X-Tenant-Id: ${2:-$tenant_id}" "X-Executor: $1" 'X-Role: REQUESTER'; }

# st METHOD URL [BODY] -> staff call; status of it
st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
# rq USER METHOD URL [BODY] -> as a REQUESTER (response "<status>\n<body>")
rq() { local user=$1 method=$2 url=$3 body=${4:-}; api "$method" "$url" "$body" "$tenant" "X-Executor: $user" 'X-Role: REQUESTER'; }
get_incident() { stb GET "$inc/$1/retrieve"; }
field() { json "$1" <<<"$(get_incident "$2")"; }

# 1. Opening an incident: the priority is derived, never typed.
opened=$(api POST "$inc/initiate" "{\"title\":\"Core switch down\",\"description\":\"No link on floor 3\",\"impact\":\"HIGH\",\"urgency\":\"MEDIUM\",\"requesterId\":\"$filed_for\",\"affectedAssetIds\":[\"$asset_id\"]}" "${staff[@]}")
id=$(api_body "$opened" | json "['id']")
check_equal 'staff open an incident (201)' 201 "$(api_status "$opened")"
check_equal 'HIGH x MEDIUM is P2, NEW, both SLA targets running' 'P2/NEW/PENDING/PENDING' "$(api_body "$opened" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s' % (d['priority'], d['status'], d['response']['state'], d['resolution']['state']))")"
check_equal 'a priority in the body is not a thing: it is ignored' P4 "$(stb POST "$inc/initiate" "{\"title\":\"t\",\"description\":\"d\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\",\"priority\":\"P1\"}" | json "['priority']")"
check_equal 'staff must name the requester (400)' 400 "$(st POST "$inc/initiate" '{"title":"t","description":"d","impact":"LOW","urgency":"LOW"}')"
check_equal 'a blank title is refused (400)' 400 "$(st POST "$inc/initiate" "{\"title\":\"\",\"description\":\"d\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\"}")"
check_equal 'the tenant is mandatory on every route (400)' 400 "$(api_status "$(api GET "$inc/$id/retrieve" "" "X-Executor: $staff_user")")"
check_equal 'update to HIGH x HIGH re-derives the priority' 204 "$(st PUT "$inc/$id/update" "{\"title\":\"Core switch down\",\"description\":\"The whole site is offline\",\"impact\":\"HIGH\",\"urgency\":\"HIGH\",\"affectedAssetIds\":[\"$asset_id\"]}")"
check_equal 'it is now P1' P1 "$(field "['priority']" "$id")"

# 2. The lifecycle.
check_equal 'start before acknowledging is an illegal transition (409)' 409 "$(st PUT "$inc/$id/control/start")"
check_equal 'assign' 204 "$(st PUT "$inc/$id/assignment/update" "{\"assigneeId\":\"$assignee\"}")"
check_equal 'acknowledge' 204 "$(st PUT "$inc/$id/control/acknowledge")"
check_equal 'ACKNOWLEDGED, the response SLA is MET, the assignee is set' "ACKNOWLEDGED/MET/$assignee" "$(get_incident "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['response']['state'], d['assigneeId']))")"
check_equal 'start' 204 "$(st PUT "$inc/$id/control/start")"
check_equal 'hold needs a reason (400)' 400 "$(st PUT "$inc/$id/control/hold" '{"reason":""}')"
check_equal 'hold with a reason' 204 "$(st PUT "$inc/$id/control/hold" '{"reason":"Waiting for the vendor"}')"
check_equal 'ON_HOLD keeps its reason' 'Waiting for the vendor' "$(field "['holdReason']" "$id")"
check_equal 'resume' 204 "$(st PUT "$inc/$id/control/resume")"
check_equal 'a public comment' 201 "$(st POST "$inc/$id/comment/initiate" '{"text":"We are on it","internal":false}')"
check_equal 'an internal note' 201 "$(st POST "$inc/$id/comment/initiate" '{"text":"The vendor contact is on leave","internal":true}')"
check_equal 'resolve needs notes (400)' 400 "$(st PUT "$inc/$id/control/resolve" '{"resolutionCode":"REPLACED","notes":""}')"
check_equal 'resolve with a code and notes' 204 "$(st PUT "$inc/$id/control/resolve" '{"resolutionCode":"REPLACED","notes":"Swapped the faulty switch"}')"
check_equal 'RESOLVED, the resolution SLA is MET, staff see both comments' 'RESOLVED/MET/2' "$(get_incident "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['resolution']['state'], len(d['comments'])))")"
check_equal 'update after resolution is refused (409)' 409 "$(st PUT "$inc/$id/update" '{"title":"t","description":"d","impact":"LOW","urgency":"LOW"}')"
check_equal 'reopen needs a reason (400)' 400 "$(st PUT "$inc/$id/control/reopen" '{"reason":""}')"
check_equal 'reopen' 204 "$(st PUT "$inc/$id/control/reopen" '{"reason":"Still failing after the swap"}')"
check_equal 'it is IN_PROGRESS again and counted as reopened' 'IN_PROGRESS/1' "$(get_incident "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['reopenCount']))")"
check_equal 'resolve again' 204 "$(st PUT "$inc/$id/control/resolve" '{"resolutionCode":"REPLACED","notes":"Swapped the cable too"}')"
check_equal 'close' 204 "$(st PUT "$inc/$id/control/close")"
check_equal 'a closed incident takes no comment (409)' 409 "$(st POST "$inc/$id/comment/initiate" '{"text":"late"}')"
check_equal 'the audit trail reads in order' 'INITIATED,UPDATED,ASSIGNED,ACKNOWLEDGED,WORK_STARTED,PUT_ON_HOLD,WORK_RESUMED,COMMENT_ADDED,COMMENT_ADDED,RESOLVED,REOPENED,RESOLVED,CLOSED' \
  "$(stb GET "$inc/$id/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 3. Self-service.
mine=$(rq "$requester_a" POST "$inc/initiate" "{\"title\":\"My laptop will not boot\",\"description\":\"Black screen\",\"impact\":\"LOW\",\"urgency\":\"MEDIUM\",\"requesterId\":\"$filed_for\"}")
mine_id=$(api_body "$mine" | json "['id']")
check_equal 'a REQUESTER files on their own behalf, whatever the body says' "201/$requester_a" "$(api_status "$mine")/$(api_body "$mine" | json "['requesterId']")"
check_equal 'staff add an internal note to it' 201 "$(st POST "$inc/$mine_id/comment/initiate" '{"text":"Probably the drive","internal":true}')"
check_equal 'the REQUESTER comments (an internal flag is ignored)' 201 "$(api_status "$(rq "$requester_a" POST "$inc/$mine_id/comment/initiate" '{"text":"It also beeps twice","internal":true}')")"
check_equal 'the REQUESTER sees only the public comment' '1/False' "$(api_body "$(rq "$requester_a" GET "$inc/$mine_id/retrieve")" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%d/%s' % (len(d['comments']), d['comments'][0]['internal']))")"
check_equal 'the REQUESTER lists only their own incidents' "$mine_id" "$(api_body "$(rq "$requester_a" GET "$inc/retrieve")" | python3 -c "import json,sys; print(','.join(i['id'] for i in json.load(sys.stdin)))")"
check_equal 'staff list sees both incidents of the tenant' 2 "$(stb GET "$inc/retrieve" | python3 -c "import json,sys; print(sum(1 for i in json.load(sys.stdin) if i['id'] in ('$id', '$mine_id')))")"
check_equal 'another requester gets a 404 for it' 404 "$(api_status "$(rq "$requester_b" GET "$inc/$mine_id/retrieve")")"
check_equal 'another requester cannot comment on it (404)' 404 "$(api_status "$(rq "$requester_b" POST "$inc/$mine_id/comment/initiate" '{"text":"hi"}')")"
denied=$(rq "$requester_a" PUT "$inc/$mine_id/control/acknowledge")
check_equal 'a REQUESTER cannot acknowledge (403 ERR-INC-00403)' '403/ERR-INC-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'a REQUESTER cannot cancel (403)' 403 "$(api_status "$(rq "$requester_a" PUT "$inc/$mine_id/control/cancel")")"
check_equal 'a REQUESTER cannot read the audit trail (403)' 403 "$(api_status "$(rq "$requester_a" GET "$inc/$mine_id/audit-log/retrieve")")"
check_equal 'another tenant gets a 404 for the incident' 404 "$(api_status "$(api GET "$inc/$mine_id/retrieve" "" "X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")")"

# 4. A race: two people move the same incident at the same instant.
raced=$(stb POST "$inc/initiate" "{\"title\":\"Race\",\"description\":\"d\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\"}" | json "['id']")
tmp=$(mktemp -d)
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user" "$inc/$raced/control/acknowledge" > "$tmp/a" ) &
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user2" "$inc/$raced/control/cancel" > "$tmp/b" ) &
wait
code_a=$(cat "$tmp/a"); code_b=$(cat "$tmp/b")
unexpected=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 || "$c" == 409 ]] || unexpected=$((unexpected + 1)); done
check_equal 'each racer is told 204 or 409, never an error' 0 "$unexpected"
final=$(field "['status']" "$raced")
check_equal 'the incident ends in a legal state' True "$([[ "$final" == ACKNOWLEDGED || "$final" == CANCELLED ]] && echo True || echo False)"
accepted=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 ]] && accepted=$((accepted + 1)); done
# Cancelling an ACKNOWLEDGED incident is legal, so both may win one after the other; what must never happen is a lost or doubled move:
# the trail is the opening plus exactly one entry for every request that was answered 204.
check_equal 'the audit trail holds the opening plus one entry per accepted move' "$((1 + accepted))" "$(stb GET "$inc/$raced/audit-log/retrieve" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
rm -rf "$tmp"

# 5. Links, filters, and the ledger.
check_equal 'the collection filters by priority, asset and open-only' "$id" "$(stb GET "$inc/retrieve?assetId=$asset_id&priority=P1" | python3 -c "import json,sys; print(','.join(i['id'] for i in json.load(sys.stdin)))")"
check_equal 'open-only leaves out the closed one' 0 "$(stb GET "$inc/retrieve?openOnly=true&assetId=$asset_id" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
delete_status=$(st DELETE "$inc/$id")
check_equal 'a delete is not a thing (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-incident-management'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-incident-management'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Incident smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
