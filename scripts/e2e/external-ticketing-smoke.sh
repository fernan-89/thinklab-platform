#!/usr/bin/env bash
# Live proof of Journey 12, fifth service (bash port of external-ticketing-smoke.ps1; connector ADR-030..033): the ServiceNow and Jira
# connector through the platform gateway, against the ticketing double (docker compose --profile ticketing-test): a connection that names
# its secrets, a real incident linked to a Jira ticket, both directions of the sync, the echo of its own pushes ignored, the platform
# winning a conflict, the webhook proving its caller, a ServiceNow connection with a real problem, a provider that is down or refuses,
# disabled connections and detached links, staff only, a race, no secret in any answer, and every mutation on the ledger.
# The service reaches the double as TICKETING_INTERNAL_URL (http://mock-ticketing:9100), this script as TICKETING_URL
# (http://localhost:9190, the compose mapping of 9100); the double reaches the webhook through the gateway as WEBHOOK_BASE_URL (http://gateway:8080).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
ticketing_url="${TICKETING_URL:-http://localhost:9190}"
ticketing_internal="${TICKETING_INTERNAL_URL:-$ticketing_url}"
webhook_base="${WEBHOOK_BASE_URL:-$gateway}"
ext="$gateway/it-external-ticketing/v1"
inc="$gateway/it-incident-management/v1"
prb="$gateway/it-problem-management/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
jira_auth_value='bW9jay1qaXJhOm1vY2s='; jira_hook_value='mock-jira-webhook-token'
snow_auth_value='bW9jay1zbm93Om1vY2s='; snow_hook_value='mock-snow-webhook-token'
checks=0
failed=0
tmp=$(mktemp -d)
: > "$tmp/all"
mock_pid=""
trap '[[ -n "$mock_pid" ]] && kill "$mock_pid" 2>/dev/null; rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
merge() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); d.update(json.loads(sys.argv[2])); print(json.dumps(d))" "$1" "$2"; }
# lower-case truth of a shell test, as python prints it
truth() { if "$@"; then echo True; else echo False; fi; }

# api METHOD URL BODY HEADER... -> prints "<status>\n<body>", never exits on a non-2xx; every body is kept to look for secrets.
api() {
  local method=$1 url=$2 body=${3:-}; shift 3 || shift $#
  local args=(-sS -X "$method" -w '\n%{http_code}')
  for h in "$@"; do args+=(-H "$h"); done
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out; out=$(curl "${args[@]}" "$url")
  local code=${out##*$'\n'}; local content=${out%$'\n'*}
  printf '%s\n' "$content" >> "$tmp/all"
  printf '%s\n%s' "$code" "$content"
}
api_status() { head -1 <<<"$1"; }
api_body() { tail -n +2 <<<"$1"; }

check_equal() {
  local name=$1 expected=$2 actual=$3
  checks=$((checks + 1))
  if [[ "$actual" == "$expected" ]]; then echo "PASS  $name"; else failed=$((failed + 1)); echo "FAIL  $name -> expected [$expected], got [$actual]"; fi
}

# The ticketing double.
mock() { curl -sS -X "$1" -H 'Content-Type: application/json' ${3:+-d "$3"} "$ticketing_url$2"; }
mock_up() { curl -sS -o /dev/null -m 2 "$ticketing_url/__mock/state" 2>/dev/null; }
if ! mock_up; then
  node_bin="${NODE_EXE:-node}"
  MOCK_TICKETING_PORT="${ticketing_url##*:}" MOCK_TICKETING_JIRA_AUTH="Basic $jira_auth_value" MOCK_TICKETING_SNOW_AUTH="Basic $snow_auth_value" \
    "$node_bin" "$(dirname "${BASH_SOURCE[0]}")/mock-ticketing.mjs" > "$tmp/mock.log" 2>&1 &
  mock_pid=$!
  for _ in $(seq 1 30); do mock_up && break; sleep 0.5; done
  mock_up || { echo "the ticketing double did not start"; exit 1; }
fi
mock POST /__mock/reset > /dev/null

tenant_id=$(uuid); staff_user=$(uuid); staff_user2=$(uuid); filed_for=$(uuid); asset_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")
requester_hdr=("$tenant" "X-Executor: $filed_for" 'X-Role: REQUESTER')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "${requester_hdr[@]}"; }
new_incident() { stb POST "$inc/initiate" "{\"title\":\"${1:-Printer on floor 3 is down}\",\"description\":\"Nothing prints since morning\",\"impact\":\"MEDIUM\",\"urgency\":\"MEDIUM\",\"requesterId\":\"$filed_for\",\"affectedAssetIds\":[\"$asset_id\"]}" | json "['id']"; }
incident_field() { stb GET "$inc/$1/retrieve" | json "$2"; }
link_field() { stb GET "$ext/$1/retrieve" | json "$2"; }
link_actions() { stb GET "$ext/$1/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))"; }
# link CONNECTION TYPE SUBJECT -> "<status>\n<body>"
link() { api POST "$ext/initiate" "{\"connectionId\":\"$1\",\"subjectType\":\"$2\",\"subjectId\":\"$3\"}" "${staff[@]}"; }
# fire PRODUCT ID STATUS COMMENT ACTOR [REPEAT] -> the deliveries of the double, as JSON
fire() {
  local body; body=$(python3 -c "
import json,sys
b={'product':sys.argv[1],'id':sys.argv[2],'actor':sys.argv[5],'repeat':int(sys.argv[6])}
if sys.argv[3]: b['status']=sys.argv[3]
if sys.argv[4]: b['comment']=sys.argv[4]
print(json.dumps(b))" "$1" "$2" "$3" "$4" "$5" "${6:-1}")
  mock POST /__mock/event "$body"
}
outcomes() { python3 -c "import json,sys; print(','.join(str(d['outcome']) for d in json.load(sys.stdin)['deliveries']))"; }
first_outcome() { python3 -c "import json,sys; print(json.load(sys.stdin)['deliveries'][0]['outcome'])"; }
mock_issue() { mock GET /__mock/state | json "['jira']['issues']['$1']$2"; }
mock_record() { mock GET /__mock/state | json "['snow']['records']['$1']$2"; }
wait_for() { for _ in $(seq 1 50); do "$@" && return 0; sleep 0.3; done; "$@"; }
deliveries_all_ignored() {
  mock GET /__mock/state | python3 -c "
import json,sys
d=[x for x in json.load(sys.stdin)['deliveries'] if x['product']=='jira']
sys.exit(0 if len(d)>=2 and all(x['outcome']=='IGNORED_OWN_EVENT' for x in d) else 1)"
}

# 1. A connection that names its secrets.
jira_body="{\"name\":\"Jira prod\",\"provider\":\"JIRA\",\"baseUrl\":\"$ticketing_internal/jira\",\"secretRef\":\"THINKLAB_MOCK_JIRA_AUTH\",\"webhookSecretRef\":\"THINKLAB_MOCK_JIRA_HOOK\",\"integrationActor\":\"svc-thinklab\",\"projectKey\":\"ITSM\"}"
made=$(api POST "$ext/connection/initiate" "$jira_body" "${staff[@]}")
jira=$(api_body "$made" | json "['id']")
check_equal 'staff register a Jira connection: 201, ACTIVE, project ITSM' '201/ACTIVE/ITSM' "$(api_status "$made")/$(api_body "$made" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['projectKey']))")"
check_equal 'it names the variables and says they are set, and holds no secret' 'THINKLAB_MOCK_JIRA_AUTH/True/True' \
  "$(api_body "$made" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['secretRef'], d['secretConfigured'], d['webhookSecretConfigured']))")"
check_equal 'the default maps were filled in' 'Done/RESOLVE' "$(api_body "$made" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['outboundStatus']['RESOLVED'], d['inboundActions']['Done']))")"
check_equal 'the same name again is a duplicate (409)' 409 "$(st POST "$ext/connection/initiate" "$jira_body")"
check_equal 'a plain http address that is not on the test list is refused (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x1","baseUrl":"http://example.com"}')")"
check_equal 'a link-local address is refused (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x2","baseUrl":"https://169.254.169.254"}')")"
check_equal 'a private address is refused (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x3","baseUrl":"https://10.0.0.5"}')")"
check_equal 'a secret name that is not a variable name is refused (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x4","secretRef":"Basic abc123"}')")"
check_equal 'the two variables must differ (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x5","webhookSecretRef":"THINKLAB_MOCK_JIRA_AUTH"}')")"
check_equal 'a Jira connection needs its project key (400)' 400 "$(st POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"x6","projectKey":""}')")"
check_equal 'the tenant is mandatory (400)' 400 "$(api_status "$(api GET "$ext/connection/$jira/retrieve" "" "X-Executor: $staff_user")")"
check_equal 'the check proves the credentials work against the provider' 'True/True' \
  "$(stb PUT "$ext/connection/$jira/check/execute" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['reachable'], d['secretConfigured']))")"
unset_id=$(stb POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"Unset secret","secretRef":"THINKLAB_NOT_SET_ANYWHERE"}')" | json "['id']")
check_equal 'a variable that is not set is reported, and the provider is not called' 'False/False' \
  "$(stb PUT "$ext/connection/$unset_id/check/execute" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['secretConfigured'], d['reachable']))")"
mock POST /__mock/register "{\"product\":\"jira\",\"webhookUrl\":\"$webhook_base/it-external-ticketing/v1/webhook/$jira/receive\",\"token\":\"$jira_hook_value\",\"actor\":\"svc-thinklab\"}" > /dev/null

# 2. A real incident linked to a Jira ticket.
incident_id=$(new_incident)
linked=$(link "$jira" INCIDENT "$incident_id")
link_id=$(api_body "$linked" | json "['id']")
key=$(api_body "$linked" | json "['externalId']")
check_equal 'linking creates the ticket: 201, LINKED, with its key' '201/LINKED/True' "$(api_status "$linked")/$(api_body "$linked" | json "['status']")/$(truth test -n "$key")"
check_equal 'the ticket was created from the incident (its title, in the project, typed Incident)' 'Printer on floor 3 is down/ITSM/Incident' \
  "$(mock_issue "$key" "['summary']")/$(mock_issue "$key" "['project']")/$(mock_issue "$key" "['type']")"
check_equal 'the ticket starts To Do, as the incident is NEW' 'To Do' "$(mock_issue "$key" "['status']")"
check_equal 'linking the same item to the same connection again is a duplicate (409)' 409 "$(api_status "$(link "$jira" INCIDENT "$incident_id")")"
check_equal 'an incident that does not exist is a 404' 404 "$(api_status "$(link "$jira" INCIDENT "$(uuid)")")"
check_equal 'a link is found from the item side' 1 "$(stb GET "$ext/retrieve?subjectId=$incident_id&subjectType=INCIDENT" | count)"

# 3. Platform -> provider.
check_equal 'acknowledge the incident' 204 "$(st PUT "$inc/$incident_id/control/acknowledge")"
synced=$(api PUT "$ext/$link_id/sync/execute" "" "${staff[@]}")
check_equal 'sync records the status as pushed' '200/ACKNOWLEDGED/OUTBOUND' "$(api_status "$synced")/$(api_body "$synced" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['lastPushedStatus'], d['lastDirection']))")"
check_equal 'the ticket needed no move (To Do is where it is)' 0 "$(mock_issue "$key" "['transitions']")"
st POST "$inc/$incident_id/comment/initiate" '{"text":"We are looking into it","internal":false}' > /dev/null
st POST "$inc/$incident_id/comment/initiate" '{"text":"Internal: the vendor is slow","internal":true}' > /dev/null
st PUT "$ext/$link_id/sync/execute" > /dev/null
check_equal 'only the PUBLIC comment reached the ticket' 'We are looking into it' "$(mock GET /__mock/state | python3 -c "import json,sys; print('|'.join(c['body'] for c in json.load(sys.stdin)['jira']['issues']['$key']['comments']))")"
st PUT "$ext/$link_id/sync/execute" > /dev/null
check_equal 'a second sync sends nothing twice' 1 "$(mock_issue "$key" "['comments']" | python3 -c "import sys,ast; print(len(ast.literal_eval(sys.stdin.read())))")"
check_equal 'the link remembers the pushed comment' 1 "$(link_field "$link_id" "['syncedComments']")"
check_equal 'start work' 204 "$(st PUT "$inc/$incident_id/control/start")"
check_equal 'the incident is resolved' 204 "$(st PUT "$inc/$incident_id/control/resolve" '{"resolutionCode":"REPLACED_TONER","notes":"Toner replaced"}')"
st PUT "$ext/$link_id/sync/execute" > /dev/null
check_equal 'the ticket moved to Done through its transition' Done "$(mock_issue "$key" "['status']")"
check_equal 'the provider called the webhook for what the integration did, and every one was recognised as its own and ignored' True "$(truth wait_for deliveries_all_ignored)"
check_equal 'the incident was not touched by those echoes (still RESOLVED)' RESOLVED "$(incident_field "$incident_id" "['status']")"

# 4. Provider -> platform.
second=$(new_incident 'VPN drops every hour')
second_link=$(api_body "$(link "$jira" INCIDENT "$second")")
second_link_id=$(json "['id']" <<<"$second_link"); second_key=$(json "['externalId']" <<<"$second_link")
st PUT "$inc/$second/control/acknowledge" > /dev/null
moved=$(fire jira "$second_key" 'In Progress' '' alice)
check_equal 'a person moves the ticket to In Progress: the webhook is applied' '200/APPLIED' "$(python3 -c "import json,sys; d=json.load(sys.stdin)['deliveries'][0]; print('%s/%s' % (d['status'], d['outcome']))" <<<"$moved")"
check_equal 'the incident followed: IN_PROGRESS' IN_PROGRESS "$(incident_field "$second" "['status']")"
check_equal 'the move is attributed to the integration identity in the incident audit trail' "external-ticketing:$jira" \
  "$(stb GET "$inc/$second/audit-log/retrieve" | python3 -c "import json,sys; print([e['executor'] for e in json.load(sys.stdin) if e['action']=='WORK_STARTED'][0])")"
check_equal 'the link remembers it as the last status, and that it came in' 'IN_PROGRESS/INBOUND' "$(link_field "$second_link_id" "['lastPushedStatus']")/$(link_field "$second_link_id" "['lastDirection']")"
st PUT "$ext/$second_link_id/sync/execute" > /dev/null
check_equal 'a sync right after pushes nothing back (no echo of the provider status)' 0 "$(mock_issue "$second_key" "['transitions']")"
comment_out=$(fire jira "$second_key" '' 'Please send the logs' alice 5)
check_equal 'the same event delivered 5 times: applied once, the other four are duplicates' 'APPLIED,DUPLICATE,DUPLICATE,DUPLICATE,DUPLICATE' "$(outcomes <<<"$comment_out")"
check_equal 'the comment is on the incident exactly once, as an INTERNAL note naming its origin' "1/True/[Jira $second_key] Please send the logs" \
  "$(stb GET "$inc/$second/retrieve" | python3 -c "
import json,sys
n=[c for c in json.load(sys.stdin)['comments'] if 'Please send the logs' in c['text']]
print('%d/%s/%s' % (len(n), n[0]['internal'], n[0]['text']))")"
check_equal 'the requester cannot read it' 0 "$(api_body "$(rq GET "$inc/$second/retrieve")" | python3 -c "import json,sys; print(sum(1 for c in json.load(sys.stdin)['comments'] if 'Please send the logs' in c['text']))")"
check_equal 'a status nobody mapped, with no comment, has nothing to apply' NOTHING_TO_APPLY "$(fire jira "$second_key" 'Waiting for customer' '' alice | first_outcome)"
check_equal 'the ticket moved by the person, then Done: the incident resolves' APPLIED "$(fire jira "$second_key" Done '' alice | first_outcome)"
check_equal 'RESOLVED, with the code the integration chose' 'RESOLVED/RESOLVED_EXTERNALLY' "$(incident_field "$second" "['status']")/$(incident_field "$second" "['resolutionCode']")"
check_equal 'the audit trail of the link tells the story in order' 'INITIATED,TICKET_CREATED,SYNCED_IN,SYNCED_IN,SYNCED_IN' "$(link_actions "$second_link_id")"

# 5. The platform wins.
conflict=$(fire jira "$key" Cancelled '' alice)
check_equal 'a cancel the resolved incident refuses is a conflict the platform wins, still answered 200' '200/CONFLICT_PLATFORM_WINS' \
  "$(python3 -c "import json,sys; d=json.load(sys.stdin)['deliveries'][0]; print('%s/%s' % (d['status'], d['outcome']))" <<<"$conflict")"
check_equal 'the incident is untouched (still RESOLVED)' RESOLVED "$(incident_field "$incident_id" "['status']")"
check_equal 'the conflict is recorded on the link, which stays LINKED' 'LINKED/True' "$(link_field "$link_id" "['status']")/$(stb GET "$ext/$link_id/retrieve" | python3 -c "import json,sys; print(bool(json.load(sys.stdin).get('lastError')))")"
check_equal 'and in its audit trail' True "$(truth bash -c '[[ "$1" == *INBOUND_CONFLICT* ]]' _ "$(link_actions "$link_id")")"

# 6. The webhook proves its caller.
hook="$ext/webhook/$jira/receive"
payload="{\"webhookEvent\":\"jira:issue_updated\",\"timestamp\":1,\"issue\":{\"key\":\"$key\"},\"user\":{\"accountId\":\"mallory\"},\"changelog\":{\"items\":[{\"field\":\"status\",\"toString\":\"Cancelled\"}]}}"
no_token=$(api POST "$hook" "$payload")
check_equal 'no token: 401 ERR-ETK-00401' '401/ERR-ETK-00401' "$(api_status "$no_token")/$(api_body "$no_token" | json "['error_code']")"
check_equal 'a wrong token: 401' 401 "$(api_status "$(api POST "$hook" "$payload" 'X-Webhook-Token: guess')")"
check_equal 'an unknown connection: 404' 404 "$(api_status "$(api POST "$ext/webhook/$(uuid)/receive" "$payload" "X-Webhook-Token: $jira_hook_value")")"
check_equal 'a payload that is not a Jira one is refused (400)' 400 "$(api_status "$(api POST "$hook" '{"nothing":"here"}' "X-Webhook-Token: $jira_hook_value")")"
check_equal 'the right token needs no tenant and no role' 200 "$(api_status "$(api POST "$hook" "$payload" "X-Webhook-Token: $jira_hook_value")")"

# 7. ServiceNow and a real problem.
snow_body="{\"name\":\"ServiceNow prod\",\"provider\":\"SERVICENOW\",\"baseUrl\":\"$ticketing_internal/snow\",\"secretRef\":\"THINKLAB_MOCK_SNOW_AUTH\",\"webhookSecretRef\":\"THINKLAB_MOCK_SNOW_HOOK\",\"integrationActor\":\"svc.thinklab\"}"
snow=$(stb POST "$ext/connection/initiate" "$snow_body" | json "['id']")
mock POST /__mock/register "{\"product\":\"snow\",\"webhookUrl\":\"$webhook_base/it-external-ticketing/v1/webhook/$snow/receive\",\"token\":\"$snow_hook_value\",\"actor\":\"svc.thinklab\"}" > /dev/null
problem=$(stb POST "$prb/initiate" "{\"title\":\"Switch drops packets\",\"description\":\"Intermittent\",\"priority\":\"P2\",\"relatedIncidentIds\":[\"$incident_id\"],\"affectedAssetIds\":[\"$asset_id\"]}" | json "['id']")
problem_link=$(api_body "$(link "$snow" PROBLEM "$problem")")
problem_link_id=$(json "['id']" <<<"$problem_link"); problem_ext=$(json "['externalId']" <<<"$problem_link")
check_equal 'a ServiceNow row of the problem table was created, with the platform item as its correlation id' "LINKED/problem/$problem/1" \
  "$(json "['status']" <<<"$problem_link")/$(mock_record "$problem_ext" "['table']")/$(mock_record "$problem_ext" "['correlation_id']")/$(mock_record "$problem_ext" "['state']")"
st PUT "$prb/$problem/control/investigate" > /dev/null
st PUT "$ext/$problem_link_id/sync/execute" > /dev/null
check_equal 'investigating moved the row to state 2' 2 "$(mock_record "$problem_ext" "['state']")"
early=$(fire snow "$problem_ext" 6 '' bob)
check_equal 'ServiceNow says resolved but the problem has no root cause: the platform refuses, a recorded conflict' '200/CONFLICT_PLATFORM_WINS' \
  "$(python3 -c "import json,sys; d=json.load(sys.stdin)['deliveries'][0]; print('%s/%s' % (d['status'], d['outcome']))" <<<"$early")"
check_equal 'the problem is still under investigation' UNDER_INVESTIGATION "$(stb GET "$prb/$problem/retrieve" | json "['status']")"
st PUT "$prb/$problem/analysis/update" '{"rootCause":"Firmware 2.1 leaks buffers"}' > /dev/null
check_equal 'with the root cause on record the same state is applied, comment included' APPLIED "$(fire snow "$problem_ext" 6 'Fixed it' bob | first_outcome)"
check_equal 'the problem is RESOLVED, with the resolution the integration wrote' "RESOLVED/Resolved in ServiceNow ($problem_ext)" \
  "$(stb GET "$prb/$problem/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['resolution']))")"
check_equal 'a problem has no public comments: the one from the provider is an internal staff note' 1 \
  "$(stb GET "$prb/$problem/retrieve" | python3 -c "import json,sys; print(sum(1 for c in json.load(sys.stdin)['comments'] if c['text'].startswith('[ServiceNow')))")"
snow_update="{\"name\":\"ServiceNow prod\",\"baseUrl\":\"$ticketing_internal/snow\",\"secretRef\":\"THINKLAB_MOCK_SNOW_AUTH\",\"webhookSecretRef\":\"THINKLAB_MOCK_SNOW_HOOK\",\"integrationActor\":\"svc.thinklab\",\"inboundActions\":{\"9\":\"ACKNOWLEDGE\",\"6\":\"RESOLVE\"}}"
check_equal 'staff change the inbound map of the connection' 204 "$(st PUT "$ext/connection/$snow/update" "$snow_update")"
other_problem=$(stb POST "$prb/initiate" '{"title":"Second problem","description":"d","priority":"P3"}' | json "['id']")
other_link=$(api_body "$(link "$snow" PROBLEM "$other_problem")")
other_ext=$(json "['externalId']" <<<"$other_link")
unsupported=$(fire snow "$other_ext" 9 '' bob)
check_equal 'an action a problem does not model is a conflict, never forced' CONFLICT_PLATFORM_WINS "$(first_outcome <<<"$unsupported")"
check_equal 'and says why' True "$(python3 -c "import json,sys; print('PROBLEM' in json.load(sys.stdin)['deliveries'][0]['detail'])" <<<"$unsupported")"

# 8. A provider that is down or refuses.
dead_body=$(merge "$jira_body" "{\"name\":\"Jira, nobody home\",\"baseUrl\":\"${ticketing_internal%:*}:9199/jira\"}")
dead=$(stb POST "$ext/connection/initiate" "$dead_body" | json "['id']")
down=$(new_incident 'Provider is down')
failed_link=$(link "$dead" INCIDENT "$down")
check_equal 'an unreachable provider is a 502 ERR-ETK-00502' '502/ERR-ETK-00502' "$(api_status "$failed_link")/$(api_body "$failed_link" | json "['error_code']")"
failures=$(stb GET "$ext/retrieve?connectionId=$dead&status=FAILED")
check_equal 'the link is saved FAILED, with a short error and no ticket' '1/True/False' \
  "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%d/%s/%s' % (len(d), bool(d[0].get('lastError')), bool(d[0].get('externalId'))))" <<<"$failures")"
failed_id=$(json "[0]['id']" <<<"$failures")
check_equal 'the address is fixed (an update), then a sync creates the ticket' 204 "$(st PUT "$ext/connection/$dead/update" "$(merge "$dead_body" "{\"baseUrl\":\"$ticketing_internal/jira\"}")")"
retried=$(api PUT "$ext/$failed_id/sync/execute" "" "${staff[@]}")
check_equal 'the retry made the ticket and the link is LINKED' '200/LINKED/True' "$(api_status "$retried")/$(api_body "$retried" | json "['status']")/$(api_body "$retried" | python3 -c "import json,sys; print(bool(json.load(sys.stdin).get('externalId')))")"
mock POST /__mock/fail '{"count":1,"status":500,"echo":true}' > /dev/null
refused=$(link "$jira" INCIDENT "$(new_incident 'The provider refuses')")
check_equal 'a provider that refuses is a 502, and its answer (which echoed our credentials) is not relayed' '502/True' \
  "$(api_status "$refused")/$(truth bash -c '[[ "$1" != *echoed* && "$1" != *'"$jira_auth_value"'* ]]' _ "$(api_body "$refused")")"
check_equal 'the message names the operation and the status' True "$(truth bash -c '[[ "$1" == *"HTTP 500"* ]]' _ "$(api_body "$refused")")"

# 9. Disabled connections and detached links.
toggle=$(stb POST "$ext/connection/initiate" "$(merge "$jira_body" '{"name":"Toggle"}')" | json "['id']")
check_equal 'disable' 204 "$(st PUT "$ext/connection/$toggle/control/disable")"
check_equal 'disabling twice is an illegal transition (409)' 409 "$(st PUT "$ext/connection/$toggle/control/disable")"
check_equal 'a disabled connection links nothing (409)' 409 "$(api_status "$(link "$toggle" INCIDENT "$(new_incident 'Disabled')")")"
check_equal 'a disabled connection accepts no webhook (409)' 409 "$(api_status "$(api POST "$ext/webhook/$toggle/receive" "$payload" "X-Webhook-Token: $jira_hook_value")")"
check_equal 'enable' 204 "$(st PUT "$ext/connection/$toggle/control/enable")"
check_equal 'and it links again' 201 "$(api_status "$(link "$toggle" INCIDENT "$(new_incident 'Enabled again')")")"
check_equal 'detach the first link' 204 "$(st PUT "$ext/$link_id/control/detach")"
check_equal 'a detached link is no longer synced (409)' 409 "$(st PUT "$ext/$link_id/sync/execute")"
check_equal 'nor followed: its ticket is now unknown to the platform' IGNORED_UNKNOWN_TICKET "$(fire jira "$key" Done '' alice | first_outcome)"
check_equal 'and the item is not linked again (409, the history is kept)' 409 "$(api_status "$(link "$jira" INCIDENT "$incident_id")")"
check_equal 'detaching twice is an illegal transition (409)' 409 "$(st PUT "$ext/$link_id/control/detach")"

# 10. Staff only, the tenant, and a race.
denied=$(rq POST "$ext/connection/initiate" "$jira_body")
check_equal 'a REQUESTER cannot register a connection (403 ERR-ETK-00403)' '403/ERR-ETK-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'a REQUESTER cannot list connections (403)' 403 "$(api_status "$(rq GET "$ext/connection/retrieve")")"
check_equal 'a REQUESTER cannot link (403)' 403 "$(api_status "$(rq POST "$ext/initiate" "{\"connectionId\":\"$jira\",\"subjectType\":\"INCIDENT\",\"subjectId\":\"$incident_id\"}")")"
check_equal 'a REQUESTER cannot read a link (403)' 403 "$(api_status "$(rq GET "$ext/$second_link_id/retrieve")")"
check_equal 'a REQUESTER cannot sync (403)' 403 "$(api_status "$(rq PUT "$ext/$second_link_id/sync/execute")")"
check_equal 'a REQUESTER cannot read the audit trail (403)' 403 "$(api_status "$(rq GET "$ext/$second_link_id/audit-log/retrieve")")"
check_equal 'another tenant gets a 404 for the link' 404 "$(api_status "$(api GET "$ext/$second_link_id/retrieve" "" "${other_tenant[@]}")")"
check_equal 'and for the connection' 404 "$(api_status "$(api GET "$ext/connection/$jira/retrieve" "" "${other_tenant[@]}")")"
check_equal 'and finds no links' 0 "$(api_body "$(api GET "$ext/retrieve" "" "${other_tenant[@]}")" | count)"
raced=$(new_incident 'Two people link me at once')
issues_before=$(mock GET /__mock/state | python3 -c "import json,sys; print(len(json.load(sys.stdin)['jira']['issues']))")
race_body="{\"connectionId\":\"$jira\",\"subjectType\":\"INCIDENT\",\"subjectId\":\"$raced\"}"
( curl -sS -o /dev/null -w '%{http_code}' -X POST -H "$tenant" -H "X-Executor: $staff_user" -H 'Content-Type: application/json' -d "$race_body" "$ext/initiate" > "$tmp/a" ) &
( curl -sS -o /dev/null -w '%{http_code}' -X POST -H "$tenant" -H "X-Executor: $staff_user2" -H 'Content-Type: application/json' -d "$race_body" "$ext/initiate" > "$tmp/b" ) &
wait
check_equal 'two people linking the same incident at the same instant: one 201 and one 409' '201,409' "$(printf '%s\n%s\n' "$(cat "$tmp/a")" "$(cat "$tmp/b")" | sort | paste -sd, -)"
issues_after=$(mock GET /__mock/state | python3 -c "import json,sys; print(len(json.load(sys.stdin)['jira']['issues']))")
check_equal 'and exactly one ticket was created for it' 1 "$((issues_after - issues_before))"

# 11. No secret anywhere, and the ledger.
check_equal 'no credential or webhook token appears in any answer' True \
  "$(truth bash -c '! grep -qF -e "$1" -e "$2" -e "$3" -e "$4" "$5"' _ "$jira_auth_value" "$snow_auth_value" "$jira_hook_value" "$snow_hook_value" "$tmp/all")"
trail=$(stb GET "$ext/connection/$jira/audit-log/retrieve")
check_equal 'nor in the audit trail of a connection' True "$(truth bash -c '[[ "$1" != *"$2"* && "$1" != *"$3"* ]]' _ "$trail" "$jira_auth_value" "$jira_hook_value")"
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-external-ticketing'))" <<<"$entries")
  [[ "$recorded" -ge 40 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 40 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-external-ticketing'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "External ticketing smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
