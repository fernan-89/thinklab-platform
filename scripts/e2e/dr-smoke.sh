#!/usr/bin/env bash
# Live proof of the DR registry (Journey 14, last slice; DR registry ADR-030..033): disaster recovery plans through the platform gateway.
# A plan is judged when read (never exercised, ready, overdue, an objective missed, the latest exercise partial or failed, paused), the same
# exercise reported by twenty reporters at once is one exercise, a later pass clears an earlier failure, a late report moves nothing forward, a
# plan that restores from a backup cannot promise to lose nothing, the runbook is an identifier and never a sentence, nothing a reporter says is
# repeated, two people pausing at once get one winner, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
dr="$gateway/it-dr-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
# ago MINUTES -> an instant that many minutes in the past
# Two moments from ONE reading of the clock: "START FINISH", that many minutes ago. A duration asserted to the minute must never depend on two readings
# (a loaded runner can take a second between them, and a duration is rounded up to whole minutes).
span() { python3 -c "import datetime,sys; n=datetime.datetime.now(datetime.timezone.utc); f=lambda m: (n - datetime.timedelta(minutes=float(m))).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'; print(f(sys.argv[1]), f(sys.argv[2]))" "$1" "$2"; }
ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z')" "$1"; }

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); asset=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: dr-drill-1')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$dr/exercise/initiate" "$1" "${tool[@]}"; }
# plan_json NAME STRATEGY RTO RPO EVERY RUNBOOK(or empty)
plan_json() { python3 -c "
import json,sys
n,s,rto,rpo,every,ref,asset=sys.argv[1:]
d={'name':n,'assetId':asset,'strategy':s,'rtoMinutes':int(rto),'rpoMinutes':int(rpo),'testEveryDays':int(every)}
if ref: d['runbookRef']=ref
print(json.dumps(d))" "$@" "$asset"; }
# exercise_json PLAN KIND OUTCOME STARTED FINISHED LOSS(or empty) REASON(or empty)
exercise_json() { python3 -c "
import json,sys
p,k,o,s,f,loss,reason=sys.argv[1:]
d={'planId':p,'kind':k,'outcome':o,'startedAt':s,'finishedAt':f}
if loss: d['dataLossMinutes']=int(loss)
if reason: d['failureReason']=reason
print(json.dumps(d))" "$@"; }
# judged ID -> readiness/rtoMet/rpoMet (null shown as None)
judged() { stb GET "$dr/$1/retrieve" | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('%s/%s/%s' % (d['readiness'], d.get('rtoMet'), d.get('rpoMet')))"; }

# 1. A plan: the promise, judged now, never exercised.
created=$(api POST "$dr/initiate" "$(plan_json 'Orders failover' WARM_STANDBY 120 30 30 KB-1042)" "${staff[@]}")
plan=$(api_body "$created" | json "['id']")
check_equal 'a plan is created (201) and starts ACTIVE and NEVER_TESTED' '201/ACTIVE/NEVER_TESTED' "$(api_status "$created")/$(api_body "$created" | json "['status']")/$(api_body "$created" | json "['readiness']")"
check_equal 'it keeps the strategy, the objectives, the interval and the runbook reference' 'WARM_STANDBY/120/30/30/KB-1042' \
  "$(stb GET "$dr/$plan/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s/%s' % (d['strategy'], d['rtoMinutes'], d['rpoMinutes'], d['testEveryDays'], d['runbookRef']))")"
check_equal 'the same name again in the tenant is a 409' '409/ERR-DRR-00409' \
  "$(api_status "$(api POST "$dr/initiate" "$(plan_json 'Orders failover' WARM_STANDBY 120 30 30 '')" "${staff[@]}")")/$(api_body "$(api POST "$dr/initiate" "$(plan_json 'Orders failover' WARM_STANDBY 120 30 30 '')" "${staff[@]}")" | json "['error_code']")"

# 2. What a plan may not promise.
check_equal 'a plan that restores from a backup cannot promise to lose no data (400)' 400 "$(st POST "$dr/initiate" "$(plan_json 'Backup only' BACKUP_RESTORE 120 0 30 '')")"
check_equal 'a standby plan can (201)' 201 "$(st POST "$dr/initiate" "$(plan_json 'Active active' ACTIVE_ACTIVE 5 0 30 '')")"
check_equal 'a runbook reference that is a sentence is refused (400)' 400 "$(st POST "$dr/initiate" "$(plan_json 'Sentence' WARM_STANDBY 120 30 30 'restart the database first')")"
check_equal 'an unknown strategy is a 400' 400 "$(st POST "$dr/initiate" '{"name":"x","assetId":"'"$asset"'","strategy":"MAGIC","rtoMinutes":1,"rpoMinutes":1,"testEveryDays":1}')"
check_equal 'an exercise interval of zero days is a 400' 400 "$(st POST "$dr/initiate" "$(plan_json 'Zero' WARM_STANDBY 120 30 0 '')")"

# 3. A pass inside the objectives: READY.
read -r start1 end1 < <(span 300 240)
first=$(report "$(exercise_json "$plan" FAILOVER SUCCEEDED "$start1" "$end1" 10 '')")
check_equal 'a passed exercise is stored (201) and its recovery took 60 minutes' '201/60' "$(api_status "$first")/$(api_body "$first" | json "['durationMinutes']")"
check_equal 'the plan is READY, the recovery time and point met' 'READY/True/True' "$(judged "$plan")"
again=$(report "$(exercise_json "$plan" FAILOVER SUCCEEDED "$start1" "$end1" 10 '')")
check_equal 'the same exercise reported again is the stored one (200, same id)' "200/$(api_body "$first" | json "['id']")" "$(api_status "$again")/$(api_body "$again" | json "['id']")"

# 4. Twenty reporters of one exercise.
start2=$(ago 200); end2=$(ago 180)
for i in $(seq 1 20); do ( report "$(exercise_json "$plan" TABLETOP SUCCEEDED "$start2" "$end2" '' '')" > "$(mktemp)" ) & done; wait
check_equal 'twenty simultaneous reports of one exercise leave exactly one' 1 "$(stb GET "$dr/exercise/retrieve?planId=$plan&kind=TABLETOP" | count)"

# 5. A partial exercise: the plan is not proved; a later pass clears it.
partial=$(report "$(exercise_json "$plan" FULL_RECOVERY PARTIAL "$(ago 120)" "$(ago 60)" 20 DEPENDENCY_MISSING)")
check_equal 'a partial exercise is stored with its fixed reason' '201/DEPENDENCY_MISSING' "$(api_status "$partial")/$(api_body "$partial" | json "['failureReason']")"
check_equal 'the plan is LAST_EXERCISE_FAILED whatever passed before' 'LAST_EXERCISE_FAILED/True/True' "$(judged "$plan")"
report "$(exercise_json "$plan" FAILOVER SUCCEEDED "$(ago 50)" "$(ago 20)" 5 '')" >/dev/null
check_equal 'a later pass clears it' 'READY/True/True' "$(judged "$plan")"

# 6. A late report moves nothing forward.
report "$(exercise_json "$plan" FAILOVER FAILED "$(ago 1500)" "$(ago 1400)" '' TIMEOUT)" >/dev/null
check_equal 'an old failure reported late changes nothing' 'READY/True/True' "$(judged "$plan")"
check_equal 'the last exercise is the newest one, not the one reported last' SUCCEEDED "$(stb GET "$dr/$plan/retrieve" | json "['lastOutcome']")"

# 7. An objective missed: slow, or lossy.
slow=$(api_body "$(api POST "$dr/initiate" "$(plan_json 'Slow' PILOT_LIGHT 60 30 30 '')" "${staff[@]}")" | json "['id']")
report "$(exercise_json "$slow" FAILOVER SUCCEEDED "$(ago 300)" "$(ago 150)" 5 '')" >/dev/null
check_equal 'a pass that took 150 minutes against a 60 minute objective misses it' 'OBJECTIVE_MISSED/False/True' "$(judged "$slow")"
lossy=$(api_body "$(api POST "$dr/initiate" "$(plan_json 'Lossy' PILOT_LIGHT 120 10 30 '')" "${staff[@]}")" | json "['id']")
report "$(exercise_json "$lossy" FAILOVER SUCCEEDED "$(ago 100)" "$(ago 50)" 45 '')" >/dev/null
check_equal 'a pass that lost 45 minutes of data against a 10 minute objective misses it' 'OBJECTIVE_MISSED/True/False' "$(judged "$lossy")"
quiet=$(api_body "$(api POST "$dr/initiate" "$(plan_json 'Quiet' PILOT_LIGHT 120 10 30 '')" "${staff[@]}")" | json "['id']")
report "$(exercise_json "$quiet" FAILOVER SUCCEEDED "$(ago 100)" "$(ago 50)" '' '')" >/dev/null
check_equal 'a measured pass that did not say what it lost says nothing about the recovery point' 'READY/True/None' "$(judged "$quiet")"

# 7b. A walk through the runbook counts as a pass but measures nothing.
paper=$(api_body "$(api POST "$dr/initiate" "$(plan_json 'Paper' PILOT_LIGHT 120 30 30 '')" "${staff[@]}")" | json "['id']")
report "$(exercise_json "$paper" TABLETOP SUCCEEDED "$(ago 100)" "$(ago 80)" '' '')" >/dev/null
check_equal 'a passed tabletop makes the plan READY but says nothing about the objectives' 'READY/None/None' "$(judged "$paper")"
report "$(exercise_json "$paper" FAILOVER SUCCEEDED "$(ago 60)" "$(ago 20)" 8 '')" >/dev/null
check_equal 'a failover that follows measures them' 'READY/True/True' "$(judged "$paper")"
report "$(exercise_json "$paper" TABLETOP SUCCEEDED "$(ago 15)" "$(ago 5)" '' '')" >/dev/null
check_equal 'a later tabletop leaves the measured pass alone' 'READY/True/True' "$(judged "$paper")"

# 8. What an exercise may not say.
check_equal 'a failed exercise needs a reason (400)' 400 "$(api_status "$(report "$(exercise_json "$plan" TABLETOP FAILED "$(ago 70)" "$(ago 65)" '' '')")")"
check_equal 'a passed exercise carries no reason (400)' 400 "$(api_status "$(report "$(exercise_json "$plan" TABLETOP SUCCEEDED "$(ago 70)" "$(ago 65)" '' TIMEOUT)")")"
check_equal 'an exercise that finishes before it starts is a 400' 400 "$(api_status "$(report "$(exercise_json "$plan" TABLETOP SUCCEEDED "$(ago 60)" "$(ago 65)" '' '')")")"
check_equal 'an exercise that finishes in the future is a 400' 400 "$(api_status "$(report "$(exercise_json "$plan" TABLETOP SUCCEEDED "$(ago 60)" "$(ago -60)" '' '')")")"
check_equal 'a reason outside the fixed list is a 400, and is not repeated' '400/False' \
  "$(api_status "$(report "$(exercise_json "$plan" TABLETOP FAILED "$(ago 70)" "$(ago 65)" '' 'secret-hostname-db01')")")/$(python3 -c "import sys; print('secret-hostname' in sys.argv[1])" "$(api_body "$(report "$(exercise_json "$plan" TABLETOP FAILED "$(ago 70)" "$(ago 65)" '' 'secret-hostname-db01')")")")"
check_equal 'an exercise for a plan that does not exist is a 404' 404 "$(api_status "$(report "$(exercise_json "$(uuid)" TABLETOP SUCCEEDED "$(ago 70)" "$(ago 65)" '' '')")")"

# 9. Lists and filters.
check_equal 'the plans of the tenant are listed oldest first' 'Orders failover' "$(stb GET "$dr/retrieve" | json "[0]['name']")"
check_equal 'the list filters on readiness' '2/OBJECTIVE_MISSED' \
  "$(stb GET "$dr/retrieve?readiness=OBJECTIVE_MISSED" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%d/%s' % (len(d), '/'.join(sorted(set(p['readiness'] for p in d)))))")"
check_equal 'exercises are filtered by kind and outcome' '1' "$(stb GET "$dr/exercise/retrieve?planId=$plan&outcome=PARTIAL" | count)"
check_equal 'the exercise list asks for 1 to 200 and refuses 0 (400)' 400 "$(st GET "$dr/exercise/retrieve?limit=0")"
check_equal 'the limit is honoured' 1 "$(stb GET "$dr/exercise/retrieve?limit=1" | count)"

# 10. Pause, resume, update.
check_equal 'a plan is paused (204) and no longer judged' '204/PAUSED' "$(st PUT "$dr/$plan/control/pause")/$(judged "$plan" | cut -d/ -f1)"
check_equal 'pausing a paused plan is a 409' 409 "$(st PUT "$dr/$plan/control/pause")"
check_equal 'resuming it brings the judgment back' '204/READY' "$(st PUT "$dr/$plan/control/resume")/$(judged "$plan" | cut -d/ -f1)"
check_equal 'update replaces the whole definition and leaves the exercises alone: the last measured pass took 30 minutes, so 15 is missed (204)' '204/ACTIVE_ACTIVE/OBJECTIVE_MISSED' \
  "$(st PUT "$dr/$plan/update" "$(plan_json 'Orders failover' ACTIVE_ACTIVE 15 5 14 '')")/$(stb GET "$dr/$plan/retrieve" | json "['strategy']")/$(judged "$plan" | cut -d/ -f1)"
pause_one=$(mktemp); pause_two=$(mktemp)
( st PUT "$dr/$lossy/control/pause" > "$pause_one" ) & ( st PUT "$dr/$lossy/control/pause" > "$pause_two" ) & wait
check_equal 'and an objective of 45 minutes is met by the same pass' 'READY/True/True' \
  "$(st PUT "$dr/$plan/update" "$(plan_json 'Orders failover' ACTIVE_ACTIVE 45 10 14 '')" >/dev/null; judged "$plan")"
check_equal 'two people pausing at once get one winner (one 204, one 409)' '1/1' \
  "$(python3 -c "import sys; v=[open(f).read().strip() for f in sys.argv[1:]]; print('%d/%d' % (v.count('204'), v.count('409')))" "$pause_one" "$pause_two")"
rm -f "$pause_one" "$pause_two"
check_equal 'the audit trail is initiated, paused, resumed and updated twice, in order' 'INITIATED,PAUSED,RESUMED,UPDATED,UPDATED' "$(stb GET "$dr/$plan/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 11. Staff only, the tenant.
check_equal 'a REQUESTER cannot create a plan (403 ERR-DRR-00403)' '403/ERR-DRR-00403' \
  "$(api_status "$(rq POST "$dr/initiate" "$(plan_json 'r' WARM_STANDBY 120 30 30 '')")")/$(api_body "$(rq POST "$dr/initiate" "$(plan_json 'r' WARM_STANDBY 120 30 30 '')")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a plan (403)' 403 "$(api_status "$(rq GET "$dr/$plan/retrieve")")"
check_equal 'a REQUESTER cannot report an exercise (403)' 403 "$(api_status "$(rq POST "$dr/exercise/initiate" "$(exercise_json "$plan" TABLETOP SUCCEEDED "$(ago 70)" "$(ago 65)" '' '')")")"
check_equal 'another tenant gets a 404 for the plan and finds no exercise' '404/0' \
  "$(api_status "$(api GET "$dr/$plan/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$dr/exercise/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$dr/$plan")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 12. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-dr-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-dr-registry'))" <<<"$entries")"
check_equal 'nothing a reporter said is on the ledger' False "$(python3 -c "import sys; print('secret-hostname' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "DR smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
