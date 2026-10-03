#!/usr/bin/env bash
# Live proof of approval chains (bash port of approval-chain-smoke.ps1; workflow-approval ADR-033/034), through the platform gateway:
# a two-stage policy, a request that waits on one stage at a time, the approver inbox, two reviewers voting AT THE SAME TIME (no vote
# may be lost), a REJECT at stage 2, a policy edit that leaves a filed request alone, and tenant isolation.
# Needs the stack up (docker-compose.yml starts workflow-approval and routes it through the gateway).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
wf="$gateway/workflow-approval/v1"
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
tenant="X-Tenant-Id: $tenant_id"
tenant_exec="X-Executor: approval-chain-smoke"
lead=$(uuid); sec_a=$(uuid); sec_b=$(uuid); requester=$(uuid)
as() { echo "X-Executor: $1"; }

# inbox_has APPROVER REQUEST_ID [TENANT_ID] -> 1 when the approver's inbox lists the request, 0 when not
inbox_has() {
  local t=${3:-$tenant_id}
  api_body "$(api GET "$wf/retrieve?pendingFor=$1" "" "X-Tenant-Id: $t")" | python3 -c "import json,sys; print(sum(1 for r in json.load(sys.stdin) if r['id']=='$2'))"
}
inbox_size() { api_body "$(api GET "$wf/retrieve?pendingFor=$1" "" "X-Tenant-Id: $2")" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
file_request() {
  api POST "$wf/initiate" "{\"subjectType\":\"ChangeRequest\",\"subjectId\":\"$(uuid)\",\"requesterId\":\"$requester\",\"policyId\":\"$1\"}" "$tenant" "$tenant_exec"
}
decide() { api PUT "$wf/$1/decision/capture" "$3" "$(as "$2")"; }
approve='{"outcome":"APPROVE"}'

# 1. The policy: two stages, and what is refused.
policy=$(api POST "$wf/policy/initiate" "{\"name\":\"Production change\",\"stages\":[{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"]},{\"requiredApprovals\":2,\"eligibleApproverIds\":[\"$sec_a\",\"$sec_b\"]}]}" "$tenant" "$tenant_exec")
policy_id=$(api_body "$policy" | json "['id']")
check_equal 'a policy with two stages is created' 201 "$(api_status "$policy")"
check_equal 'it answers with both stages' 2 "$(api_body "$policy" | json "['stages'].__len__()")"
check_equal 'the first stage is also the top-level quorum' 1 "$(api_body "$policy" | json "['requiredApprovals']")"
ambiguous=$(api POST "$wf/policy/initiate" "{\"name\":\"Ambiguous\",\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"],\"stages\":[{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$sec_a\"]}]}" "$tenant" "$tenant_exec")
check_equal 'stages together with the single-quorum pair are refused (400)' 400 "$(api_status "$ambiguous")"
overlap=$(api POST "$wf/policy/initiate" "{\"name\":\"Same person twice\",\"stages\":[{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"]},{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\",\"$sec_a\"]}]}" "$tenant" "$tenant_exec")
check_equal 'one person in two stages is refused (400)' 400 "$(api_status "$overlap")"
check_equal 'and the refusal names segregation of duties' True "$(api_body "$overlap" | python3 -c "import json,sys; print('Segregation of duties' in json.load(sys.stdin)['detail'])")"

# 2. A request waits on stage 1 only.
filed=$(file_request "$policy_id")
request_id=$(api_body "$filed" | json "['id']")
check_equal 'a request is filed against the chain' 201 "$(api_status "$filed")"
check_equal 'it is PENDING on stage 1 of 2' 'PENDING/1/2' "$(api_body "$filed" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['currentStage'], len(d['stages'])))")"
check_equal 'the lead has it in the inbox' 1 "$(inbox_has "$lead" "$request_id")"
check_equal 'security does not have it yet' 0 "$(inbox_has "$sec_a" "$request_id")"
check_equal 'security cannot decide before its stage (409)' 409 "$(api_status "$(decide "$request_id" "$sec_a" "$approve")")"

# 3. The lead approves: stage 2, still PENDING, inboxes swap.
first=$(decide "$request_id" "$lead" '{"outcome":"APPROVE","comment":"ok from the team"}')
check_equal 'the lead approves' 200 "$(api_status "$first")"
check_equal 'the request is still PENDING, now on stage 2 needing two approvals' 'PENDING/2/2' "$(api_body "$first" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['currentStage'], d['requiredApprovals']))")"
check_equal 'the lead vote is recorded on stage 1' 1 "$(api_body "$first" | json "['decisions'][0]['stage']")"
check_equal 'the lead no longer has it' 0 "$(inbox_has "$lead" "$request_id")"
check_equal 'security has it now' 1 "$(inbox_has "$sec_a" "$request_id")"
check_equal 'the lead cannot decide a second time (409)' 409 "$(api_status "$(decide "$request_id" "$lead" "$approve")")"

# 4. Both reviewers vote at the same time: no vote may be lost.
tmp=$(mktemp -d)
for who in "$sec_a" "$sec_b"; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "X-Executor: $who" -H 'Content-Type: application/json' -d "$approve" "$wf/$request_id/decision/capture" > "$tmp/$who" ) &
done
wait
code_a=$(cat "$tmp/$sec_a"); code_b=$(cat "$tmp/$sec_b")
unexpected=0
for c in "$code_a" "$code_b"; do [[ "$c" == 200 || "$c" == 409 ]] || unexpected=$((unexpected + 1)); done
check_equal 'each simultaneous vote is accepted or told to retry (200/409), never an error' 0 "$unexpected"
retried_ok=1
for pair in "$sec_a:$code_a" "$sec_b:$code_b"; do
  who=${pair%%:*}; code=${pair##*:}
  if [[ "$code" == 409 ]]; then
    retry=$(api_status "$(decide "$request_id" "$who" "$approve")")
    [[ "$retry" == 200 || "$retry" == 409 ]] || retried_ok=0
  fi
done
check_equal 'a vote that lost the race succeeds when it retries (or was already counted)' 1 "$retried_ok"
done_body=$(api_body "$(api GET "$wf/$request_id/retrieve" "" "$tenant")")
check_equal 'the request ends APPROVED' APPROVED "$(json "['status']" <<<"$done_body")"
check_equal 'with exactly the three votes: nothing lost, nothing counted twice' 3 "$(json "['decisions'].__len__()" <<<"$done_body")"
check_equal 'two of them on stage 2' 2 "$(python3 -c "import json,sys; print(sum(1 for d in json.load(sys.stdin)['decisions'] if d['stage']==2))" <<<"$done_body")"
audit=$(api_body "$(api GET "$wf/$request_id/audit-log/retrieve" "" "$tenant")")
check_equal 'the audit trail reads INITIATED then three DECISION_CAPTURED' 'INITIATED,DECISION_CAPTURED,DECISION_CAPTURED,DECISION_CAPTURED' "$(python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))" <<<"$audit")"
check_equal 'the first decision records the stage change' True "$(python3 -c "import json,sys; print('Stage 1 of 2 complete; now waiting on stage 2.' in json.load(sys.stdin)[1]['detail'])" <<<"$audit")"

# 5. A REJECT at stage 2 ends everything.
second=$(file_request "$policy_id")
second_id=$(api_body "$second" | json "['id']")
check_equal 'the lead approves the second request' 200 "$(api_status "$(decide "$second_id" "$lead" "$approve")")"
rejected=$(decide "$second_id" "$sec_a" '{"outcome":"REJECT","comment":"not now"}')
check_equal 'a security reviewer rejects at stage 2' 200 "$(api_status "$rejected")"
check_equal 'the whole request is REJECTED at once' REJECTED "$(api_body "$rejected" | json "['status']")"
check_equal 'the other reviewer is then refused (409)' 409 "$(api_status "$(decide "$second_id" "$sec_b" "$approve")")"
check_equal 'a resolved request leaves the inbox' 0 "$(inbox_has "$sec_b" "$second_id")"

# 6. Editing the policy leaves a filed request alone; the original shape still works; tenants are isolated.
third=$(file_request "$policy_id")
third_id=$(api_body "$third" | json "['id']")
check_equal 'edit the policy to a single stage' 204 "$(api_status "$(api PUT "$wf/policy/$policy_id/update" "{\"name\":\"Production change v2\",\"stages\":[{\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"]}]}" "$tenant" "$tenant_exec")")"
check_equal 'a request filed before the edit keeps its two stages' 2 "$(api_body "$(api GET "$wf/$third_id/retrieve" "" "$tenant")" | json "['stages'].__len__()")"
flat=$(api POST "$wf/policy/initiate" "{\"name\":\"CAB\",\"requiredApprovals\":1,\"eligibleApproverIds\":[\"$lead\"]}" "$tenant" "$tenant_exec")
check_equal 'the original single-quorum shape is still accepted' 201 "$(api_status "$flat")"
check_equal 'and is a one-stage chain' 1 "$(api_body "$flat" | json "['stages'].__len__()")"
single=$(file_request "$(api_body "$flat" | json "['id']")")
check_equal 'its request resolves APPROVED with one vote' APPROVED "$(api_body "$(decide "$(api_body "$single" | json "['id']")" "$lead" "$approve")" | json "['status']")"
check_equal 'another tenant sees an empty inbox for the same approver' 0 "$(inbox_size "$lead" "$(uuid)")"

rm -rf "$tmp"
echo "Approval chain smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
