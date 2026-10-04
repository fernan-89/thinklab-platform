#!/usr/bin/env bash
# Live proof of Journey 12, second service (bash port of service-request-smoke.ps1; service-request ADR-030..034): the service catalog
# and requests through the platform gateway - the catalog lifecycle, a request with no approval, a request whose approval is a chain on
# workflow-approval (released by the last stage, ended by a rejection, withdrawn by a cancel), requester self-service, a race between
# two people, and every mutation (the refused ones too) recorded on the ledger.
# Needs the stack up (docker-compose.yml starts it, routes it through the gateway and turns the ledger recording on).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
srq="$gateway/it-service-request/v1"
cat_api="$srq/catalog"
wf="$gateway/workflow-approval/v1"
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
is_true() { [[ "$1" == "$2" ]] && echo True || echo False; }

tenant_id=$(uuid)
staff_user=$(uuid); staff_user2=$(uuid); requester_a=$(uuid); requester_b=$(uuid); requester_c=$(uuid)
assignee=$(uuid); filed_for=$(uuid)
lead=$(uuid); sec_a=$(uuid); sec_b=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")

# st METHOD URL [BODY] -> staff call; status / body of it
st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
# rq USER METHOD URL [BODY] -> as a REQUESTER (response "<status>\n<body>")
rq() { local user=$1 method=$2 url=$3 body=${4:-}; api "$method" "$url" "$body" "$tenant" "X-Executor: $user" 'X-Role: REQUESTER'; }
get_request() { stb GET "$srq/$1/retrieve"; }
field() { json "$1" <<<"$(get_request "$2")"; }
# decide REQUEST_ID APPROVER OUTCOME -> "<status>\n<body>"
decide() { api PUT "$srq/$1/approval/capture" "{\"outcome\":\"$3\"}" "$tenant" "X-Executor: $2"; }
new_request() { stb POST "$srq/initiate" "{\"catalogItemId\":\"$1\",\"answers\":$2,\"requesterId\":\"$filed_for\"}"; }
actions() { python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))"; }

# 1. The catalog.
laptop=$(api POST "$cat_api/initiate" '{"code":"laptop","name":"New laptop","category":"HARDWARE","fulfilmentTargetHours":72,"fields":[{"key":"model","label":"Which model?","required":true},{"key":"notes","label":"Anything else?","required":false}]}' "${staff[@]}")
laptop_id=$(api_body "$laptop" | json "['id']")
check_equal 'a draft item is created (201), DRAFT, code upper-cased' '201/DRAFT/LAPTOP' "$(api_status "$laptop")/$(api_body "$laptop" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['code']))")"
check_equal 'the same code again, in another case, is refused (409)' 409 "$(st POST "$cat_api/initiate" '{"code":"Laptop","name":"Other","fields":[],"fulfilmentTargetHours":8}')"
check_equal 'a DRAFT item cannot be requested (409)' 409 "$(st POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\"},\"requesterId\":\"$filed_for\"}")"
check_equal 'a REQUESTER does not see a DRAFT item (404)' 404 "$(api_status "$(rq "$requester_a" GET "$cat_api/$laptop_id/retrieve")")"
check_equal 'the draft is edited (204)' 204 "$(st PUT "$cat_api/$laptop_id/update" '{"name":"New laptop (standard)","category":"HARDWARE","fulfilmentTargetHours":72,"fields":[{"key":"model","label":"Which model?","required":true},{"key":"notes","label":"Anything else?","required":false}]}')"
check_equal 'publish' 204 "$(st PUT "$cat_api/$laptop_id/control/publish")"
check_equal 'a PUBLISHED item can no longer be edited (409)' 409 "$(st PUT "$cat_api/$laptop_id/update" '{"name":"x","fields":[],"fulfilmentTargetHours":8}')"
check_equal 'a REQUESTER sees it now' PUBLISHED "$(api_body "$(rq "$requester_a" GET "$cat_api/$laptop_id/retrieve")" | json "['status']")"
check_equal 'a REQUESTER lists only PUBLISHED items, even asking for DRAFT' "$laptop_id" "$(api_body "$(rq "$requester_a" GET "$cat_api/retrieve?status=DRAFT")" | python3 -c "import json,sys; print(','.join(i['id'] for i in json.load(sys.stdin)))")"
check_equal 'a REQUESTER cannot manage the catalog (403)' 403 "$(api_status "$(rq "$requester_a" POST "$cat_api/initiate" '{"code":"SNEAKY","name":"s","fields":[],"fulfilmentTargetHours":1}')")"

# 2. A request with no approval.
check_equal 'a missing mandatory answer is refused (400)' 400 "$(st POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"notes\":\"n\"},\"requesterId\":\"$filed_for\"}")"
check_equal 'an unknown question is refused (400)' 400 "$(st POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\",\"size\":\"XL\"},\"requesterId\":\"$filed_for\"}")"
check_equal 'staff must name the requester (400)' 400 "$(st POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\"}}")"
opened=$(new_request "$laptop_id" '{"model":"X1"}')
id=$(json "['id']" <<<"$opened")
check_equal 'staff order on someone behalf: SUBMITTED, SLA PENDING' 'SUBMITTED/PENDING' "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['fulfilment']['state']))" <<<"$opened")"
check_equal 'it snapshots the item' 'LAPTOP/New laptop (standard)' "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['catalogItemCode'], d['catalogItemName']))" <<<"$opened")"
check_equal 'the tenant is mandatory on every route (400)' 400 "$(api_status "$(api GET "$srq/$id/retrieve" "" "X-Executor: $staff_user")")"
check_equal 'fulfil before starting is an illegal transition (409)' 409 "$(st PUT "$srq/$id/control/fulfil" '{"notes":"done"}')"
check_equal 'assign' 204 "$(st PUT "$srq/$id/assignment/update" "{\"assigneeId\":\"$assignee\"}")"
check_equal 'a public comment' 201 "$(st POST "$srq/$id/comment/initiate" '{"text":"Stock is on its way","internal":false}')"
check_equal 'an internal note' 201 "$(st POST "$srq/$id/comment/initiate" '{"text":"Supplier says Thursday","internal":true}')"
check_equal 'start fulfilment' 204 "$(st PUT "$srq/$id/control/start-fulfilment")"
check_equal 'fulfil needs notes (400)' 400 "$(st PUT "$srq/$id/control/fulfil" '{"notes":""}')"
check_equal 'fulfil with notes' 204 "$(st PUT "$srq/$id/control/fulfil" '{"notes":"Laptop handed over"}')"
check_equal 'FULFILLED, the SLA is MET, staff see both comments' 'FULFILLED/MET/2' "$(get_request "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['fulfilment']['state'], len(d['comments'])))")"
check_equal 'close' 204 "$(st PUT "$srq/$id/control/close")"
check_equal 'a closed request takes no comment (409)' 409 "$(st POST "$srq/$id/comment/initiate" '{"text":"late"}')"
check_equal 'a closed request cannot be cancelled (409)' 409 "$(st PUT "$srq/$id/control/cancel")"
check_equal 'the audit trail reads in order' 'INITIATED,ASSIGNED,COMMENT_ADDED,COMMENT_ADDED,FULFILMENT_STARTED,FULFILLED,CLOSED' "$(stb GET "$srq/$id/audit-log/retrieve" | actions)"

# 3. A request whose approval is a chain on workflow-approval: team lead first, then security (either of two).
wf_tenant=("$tenant" 'X-Executor: service-request-smoke')
policy=$(api POST "$wf/policy/initiate" "{\"name\":\"Software seat\",\"stages\":[{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"]},{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$sec_a\",\"$sec_b\"]}]}" "${wf_tenant[@]}")
policy_id=$(api_body "$policy" | json "['id']")
check_equal 'the approval chain exists on workflow-approval' '201/2' "$(api_status "$policy")/$(api_body "$policy" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['stages']))")"
seat=$(api POST "$cat_api/initiate" "{\"code\":\"SEAT\",\"name\":\"Software seat\",\"fulfilmentTargetHours\":24,\"approvalPolicyId\":\"$policy_id\",\"fields\":[{\"key\":\"product\",\"label\":\"Which product?\",\"required\":true}]}" "${staff[@]}")
seat_id=$(api_body "$seat" | json "['id']")
check_equal 'an item naming the policy is created' 201 "$(api_status "$seat")"
check_equal 'publish it' 204 "$(st PUT "$cat_api/$seat_id/control/publish")"
waiting=$(new_request "$seat_id" '{"product":"IDE"}')
wid=$(json "['id']" <<<"$waiting")
approval_id=$(json "['approvalRequestId']" <<<"$waiting")
check_equal 'the request waits for approval and carries the approval request id' 'PENDING_APPROVAL/True' "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], bool(d.get('approvalRequestId'))))" <<<"$waiting")"
check_equal 'the first approver has it in their inbox on workflow-approval' 1 "$(api_body "$(api GET "$wf/retrieve?pendingFor=$lead" "" "$tenant")" | python3 -c "import json,sys; print(sum(1 for a in json.load(sys.stdin) if a['id']=='$approval_id'))")"
check_equal 'fulfilment cannot start before approval (409)' 409 "$(st PUT "$srq/$wid/control/start-fulfilment")"
stranger=$(decide "$wid" "$(uuid)" APPROVE)
check_equal 'an approver who is not eligible is told why (409 ERR-SRQ-00409, not a generic 500)' '409/ERR-SRQ-00409' "$(api_status "$stranger")/$(api_body "$stranger" | json "['error_code']")"
check_equal 'and the request is still waiting' PENDING_APPROVAL "$(field "['status']" "$wid")"
first=$(decide "$wid" "$lead" APPROVE)
check_equal 'the first stage approving leaves the request waiting (the chain has a stage left)' '200/PENDING_APPROVAL' "$(api_status "$first")/$(api_body "$first" | json "['status']")"
last=$(decide "$wid" "$sec_a" APPROVE)
check_equal 'the last stage approving releases it: APPROVED' '200/APPROVED' "$(api_status "$last")/$(api_body "$last" | json "['status']")"
check_equal 'a decision on a request that is no longer waiting is refused (409)' 409 "$(api_status "$(decide "$wid" "$sec_b" APPROVE)")"
check_equal 'the approved request can start fulfilment' 204 "$(st PUT "$srq/$wid/control/start-fulfilment")"
check_equal 'and be fulfilled' 204 "$(st PUT "$srq/$wid/control/fulfil" '{"notes":"Seat assigned"}')"
check_equal 'its trail records the approval' 'INITIATED,APPROVED,FULFILMENT_STARTED,FULFILLED' "$(stb GET "$srq/$wid/audit-log/retrieve" | actions)"
rid=$(new_request "$seat_id" '{"product":"CAD"}' | json "['id']")
rejection=$(decide "$rid" "$lead" REJECT)
check_equal 'a rejection ends it: REJECTED' '200/REJECTED' "$(api_status "$rejection")/$(api_body "$rejection" | json "['status']")"
check_equal 'a rejected request cannot start fulfilment (409)' 409 "$(st PUT "$srq/$rid/control/start-fulfilment")"
check_equal 'a rejected request owes no SLA' True "$(get_request "$rid" | python3 -c "import json,sys; print('fulfilment' not in json.load(sys.stdin))")"
cancelled=$(new_request "$seat_id" '{"product":"VM"}')
cid=$(json "['id']" <<<"$cancelled")
cancelled_approval=$(json "['approvalRequestId']" <<<"$cancelled")
check_equal 'cancel a request that waits for approval' 204 "$(st PUT "$srq/$cid/control/cancel")"
check_equal 'its approval request was withdrawn on workflow-approval' CANCELLED "$(api_body "$(api GET "$wf/$cancelled_approval/retrieve" "" "${wf_tenant[@]}")" | json "['status']")"
check_equal 'and it left the approver inbox' 0 "$(api_body "$(api GET "$wf/retrieve?pendingFor=$lead" "" "$tenant")" | python3 -c "import json,sys; print(sum(1 for a in json.load(sys.stdin) if a['id']=='$cancelled_approval'))")"

# 3b. An approver sends a request back with what to fix; the requester edits it and it goes through a NEW approval.
ret=$(rq "$requester_c" POST "$srq/initiate" "{\"catalogItemId\":\"$seat_id\",\"answers\":{\"product\":\"IDE\"}}")
ret_id=$(api_body "$ret" | json "['id']")
first_approval=$(api_body "$ret" | json "['approvalRequestId']")
check_equal 'a REQUESTER orders the item that needs approval: it waits' '201/PENDING_APPROVAL' "$(api_status "$ret")/$(api_body "$ret" | json "['status']")"
check_equal 'a RETURN needs a comment saying what to fix (400)' 400 "$(api_status "$(decide "$ret_id" "$lead" RETURN)")"
check_equal 'and the request is still waiting' PENDING_APPROVAL "$(field "['status']" "$ret_id")"
returned=$(api PUT "$srq/$ret_id/approval/capture" '{"outcome":"RETURN","comment":"Say which product and why you need it"}' "$tenant" "X-Executor: $lead")
check_equal 'RETURN sends it back: RETURNED, with the approver comment as the reason' '200/RETURNED/Say which product and why you need it' "$(api_status "$returned")/$(api_body "$returned" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['returnReason']))")"
check_equal 'the approval on workflow-approval is RETURNED and left the inbox' 'RETURNED/0' "$(api_body "$(api GET "$wf/$first_approval/retrieve" "" "${wf_tenant[@]}")" | json "['status']")/$(api_body "$(api GET "$wf/retrieve?pendingFor=$lead" "" "$tenant")" | python3 -c "import json,sys; print(sum(1 for a in json.load(sys.stdin) if a['id']=='$first_approval'))")"
check_equal 'a decision on a returned request is refused (409)' 409 "$(api_status "$(decide "$ret_id" "$sec_a" APPROVE)")"
check_equal 'the REQUESTER sees the reason on their own request' 'Say which product and why you need it' "$(api_body "$(rq "$requester_c" GET "$srq/$ret_id/retrieve")" | json "['returnReason']")"
check_equal 'another requester cannot resubmit it (404)' 404 "$(api_status "$(rq "$requester_b" PUT "$srq/$ret_id/control/resubmit" '{"answers":{"product":"CAD"}}')")"
check_equal 'answers the item does not ask are refused (400), nothing is filed' 400 "$(api_status "$(rq "$requester_c" PUT "$srq/$ret_id/control/resubmit" '{"answers":{"colour":"red"}}')")"
check_equal 'a request that was not returned cannot be resubmitted (409)' 409 "$(st PUT "$srq/$wid/control/resubmit" '{"answers":{"product":"IDE"}}')"
resubmitted=$(rq "$requester_c" PUT "$srq/$ret_id/control/resubmit" '{"answers":{"product":"IDE for the data team"}}')
check_equal 'the REQUESTER edits and resubmits: waiting again, the new answers, a NEW approval request' '200/PENDING_APPROVAL/IDE for the data team/True' \
  "$(api_status "$resubmitted")/$(api_body "$resubmitted" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['answers']['product'], d['approvalRequestId'] != '$first_approval'))")"
new_approval=$(api_body "$resubmitted" | json "['approvalRequestId']")
check_equal 'it is back in the first approver inbox, from stage one' 1 "$(api_body "$(api GET "$wf/retrieve?pendingFor=$lead" "" "$tenant")" | python3 -c "import json,sys; print(sum(1 for a in json.load(sys.stdin) if a['id']=='$new_approval'))")"
check_equal 'the first stage approves' PENDING_APPROVAL "$(api_body "$(decide "$ret_id" "$lead" APPROVE)" | json "['status']")"
check_equal 'the second stage approves: APPROVED' APPROVED "$(api_body "$(decide "$ret_id" "$sec_b" APPROVE)" | json "['status']")"
check_equal 'its trail tells the story' 'INITIATED,RETURNED,RESUBMITTED,APPROVED' "$(stb GET "$srq/$ret_id/audit-log/retrieve" | actions)"
ret_cancel_id=$(api_body "$(rq "$requester_c" POST "$srq/initiate" "{\"catalogItemId\":\"$seat_id\",\"answers\":{\"product\":\"VM\"}}")" | json "['id']")
api PUT "$srq/$ret_cancel_id/approval/capture" '{"outcome":"RETURN","comment":"Not enough detail"}' "$tenant" "X-Executor: $lead" > /dev/null
check_equal 'staff return another one, which the REQUESTER cancels instead of resubmitting' RETURNED "$(field "['status']" "$ret_cancel_id")"
check_equal 'a returned request can be cancelled by its REQUESTER' 204 "$(api_status "$(rq "$requester_c" PUT "$srq/$ret_cancel_id/control/cancel")")"

# 4. Self-service.
mine=$(rq "$requester_a" POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\"},\"requesterId\":\"$filed_for\"}")
mine_id=$(api_body "$mine" | json "['id']")
check_equal 'a REQUESTER orders for themselves, whatever the body says' "201/$requester_a" "$(api_status "$mine")/$(api_body "$mine" | json "['requesterId']")"
check_equal 'staff add an internal note to it' 201 "$(st POST "$srq/$mine_id/comment/initiate" '{"text":"Check the budget","internal":true}')"
check_equal 'the REQUESTER comments (an internal flag is ignored)' 201 "$(api_status "$(rq "$requester_a" POST "$srq/$mine_id/comment/initiate" '{"text":"Needed by Monday","internal":true}')")"
check_equal 'the REQUESTER sees only the public comment' '1/False' "$(api_body "$(rq "$requester_a" GET "$srq/$mine_id/retrieve")" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%d/%s' % (len(d['comments']), d['comments'][0]['internal']))")"
check_equal 'the REQUESTER lists only their own requests' "$mine_id" "$(api_body "$(rq "$requester_a" GET "$srq/retrieve")" | python3 -c "import json,sys; print(','.join(r['id'] for r in json.load(sys.stdin)))")"
check_equal 'staff list sees them all' 3 "$(stb GET "$srq/retrieve" | python3 -c "import json,sys; print(sum(1 for r in json.load(sys.stdin) if r['id'] in ('$id', '$mine_id', '$wid')))")"
check_equal 'open-only leaves out the finished ones' 0 "$(stb GET "$srq/retrieve?openOnly=true" | python3 -c "import json,sys; print(sum(1 for r in json.load(sys.stdin) if r['id'] in ('$id', '$rid', '$cid')))")"
check_equal 'another requester gets a 404 for it' 404 "$(api_status "$(rq "$requester_b" GET "$srq/$mine_id/retrieve")")"
check_equal 'another requester cannot comment on it (404)' 404 "$(api_status "$(rq "$requester_b" POST "$srq/$mine_id/comment/initiate" '{"text":"hi"}')")"
denied=$(rq "$requester_a" PUT "$srq/$mine_id/control/start-fulfilment")
check_equal 'a REQUESTER cannot start fulfilment (403 ERR-SRQ-00403)' '403/ERR-SRQ-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'another requester cannot cancel it (404)' 404 "$(api_status "$(rq "$requester_b" PUT "$srq/$mine_id/control/cancel")")"
check_equal 'a REQUESTER cancels their own request (204)' 204 "$(api_status "$(rq "$requester_a" PUT "$srq/$mine_id/control/cancel")")"
check_equal 'it is CANCELLED and owes no SLA' 'CANCELLED/True' "$(get_request "$mine_id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], 'fulfilment' not in d))")"
check_equal 'a REQUESTER cannot decide an approval (403)' 403 "$(api_status "$(rq "$requester_a" PUT "$srq/$mine_id/approval/capture" '{"outcome":"APPROVE"}')")"
check_equal 'a REQUESTER cannot read the audit trail (403)' 403 "$(api_status "$(rq "$requester_a" GET "$srq/$mine_id/audit-log/retrieve")")"
check_equal 'another tenant gets a 404 for the request' 404 "$(api_status "$(api GET "$srq/$mine_id/retrieve" "" "X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")")"
check_equal 'another tenant cannot order this tenant item (404)' 404 "$(api_status "$(api POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\"},\"requesterId\":\"$filed_for\"}" "X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")")"

# 5. A race: two people move the same request at the same instant.
raced=$(new_request "$laptop_id" '{"model":"X2"}' | json "['id']")
tmp=$(mktemp -d)
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user" "$srq/$raced/control/start-fulfilment" > "$tmp/a" ) &
( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $staff_user2" "$srq/$raced/control/cancel" > "$tmp/b" ) &
wait
code_a=$(cat "$tmp/a"); code_b=$(cat "$tmp/b")
unexpected=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 || "$c" == 409 ]] || unexpected=$((unexpected + 1)); done
check_equal 'each racer is told 204 or 409, never an error' 0 "$unexpected"
final=$(field "['status']" "$raced")
check_equal 'the request ends in a legal state' True "$([[ "$final" == IN_FULFILMENT || "$final" == CANCELLED ]] && echo True || echo False)"
accepted=0
for c in "$code_a" "$code_b"; do [[ "$c" == 204 ]] && accepted=$((accepted + 1)); done
# Cancelling an IN_FULFILMENT request is legal, so both may win one after the other; what must never happen is a lost or doubled move:
# the trail is the opening plus exactly one entry for every request that was answered 204.
check_equal 'the audit trail holds the opening plus one entry per accepted move' "$((1 + accepted))" "$(stb GET "$srq/$raced/audit-log/retrieve" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
rm -rf "$tmp"

# 6. Retire, and the ledger.
check_equal 'retire the item' 204 "$(st PUT "$cat_api/$laptop_id/control/retire")"
check_equal 'a RETIRED item can no longer be requested (409)' 409 "$(st POST "$srq/initiate" "{\"catalogItemId\":\"$laptop_id\",\"answers\":{\"model\":\"X1\"},\"requesterId\":\"$filed_for\"}")"
check_equal 'a request made before stays as it was (snapshot intact)' 'CLOSED/New laptop (standard)' "$(get_request "$id" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['catalogItemName']))")"
delete_status=$(st DELETE "$srq/$id")
check_equal 'a delete is not a thing (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-service-request'))" <<<"$entries")
  [[ "$recorded" -ge 40 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 40 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-service-request'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Service request smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
