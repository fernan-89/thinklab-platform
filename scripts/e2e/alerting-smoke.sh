#!/usr/bin/env bash
# Live proof of Journey 14, second service (bash port of alerting-smoke.ps1; alerting ADR-030..033): alerting through the platform gateway,
# against the target double (docker compose --profile health-test), the REAL health monitor and the REAL incident service: an alert and one
# real incident per outage (decided by the oldest active rule), nothing more however many evaluations run (four at once included), recovery
# that resolves the alert and adds an INTERNAL note without closing the incident, a new outage as a new alert, paused rules, staff only,
# the tenant, and every mutation on the ledger.
# The monitor reaches the double as TARGET_INTERNAL_HOST (mock-target, ports 9200 and 9201), this script as CONTROL_URL (http://localhost:9290).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
control="${CONTROL_URL:-http://localhost:9290}"
target_host="${TARGET_INTERNAL_HOST:-mock-target}"
http_port="${TARGET_HTTP_PORT:-9200}"
tcp_port="${TARGET_TCP_PORT:-9201}"
hlm="$gateway/it-health-monitoring/v1"
alr="$gateway/it-alerting/v1"
inc="$gateway/it-incident-management/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }

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
truth() { if "$@"; then echo True; else echo False; fi; }
wait_for() { local seconds=$1; shift; local end=$((SECONDS + seconds)); while (( SECONDS < end )); do "$@" && return 0; sleep 0.5; done; "$@"; }

target() { curl -sS -o /dev/null -X POST -H 'Content-Type: application/json' -d "$2" "$control$1"; }
curl -sS -o /dev/null -m 5 "$control/__mock/state" || { echo "the target double is not reachable at $control (docker compose --profile health-test)"; exit 1; }
target /__mock/status '{"status":200}'; target /__mock/delay '{"ms":0}'; target /__mock/tcp '{"open":true}'

tenant_id=$(uuid); staff_user=$(uuid); filed_for=$(uuid); asset_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")
as_requester=("$tenant" "X-Executor: $filed_for" 'X-Role: REQUESTER')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")
http_target="http://$target_host:$http_port/health"
tcp_target="$target_host:$tcp_port"

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "${as_requester[@]}"; }
run_check() { stb PUT "$hlm/$1/check/execute" | json "['health']"; }
check_health() { stb GET "$hlm/$1/retrieve" | json "['health']"; }
evaluate() { stb PUT "$alr/evaluation/execute"; }
alerts() { stb GET "$alr/retrieve$1"; }
alert_count() { alerts "$1" | count; }
incident_count() { stb GET "$inc/retrieve" | count; }
incident() { stb GET "$inc/$1/retrieve"; }
newest_field() { alerts "?checkId=$1" | json "[0]$2"; }
trail() { stb GET "$1/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))"; }
both_up() { [[ "$(check_health "$web")" == UP && "$(check_health "$db")" == UP ]]; }
has_alerts() { [[ "$(alert_count '')" -ge "$1" ]]; }
has_web_alerts() { [[ "$(alert_count "?checkId=$web")" -ge "$1" ]]; }
web_resolved() { [[ "$(newest_field "$web" "['status']")" == RESOLVED ]]; }
db_resolved() { [[ "$(newest_field "$db" "['status']")" == RESOLVED ]]; }

# 0. Two checks to watch, probed once by the monitor's own scheduler, then left alone (a long interval).
web=$(stb POST "$hlm/initiate" "{\"name\":\"Intranet\",\"type\":\"HTTP\",\"target\":\"$http_target\",\"assetId\":\"$asset_id\",\"intervalSeconds\":3600,\"timeoutMillis\":2000,\"failureThreshold\":1}" | json "['id']")
db=$(stb POST "$hlm/initiate" "{\"name\":\"Database\",\"type\":\"TCP\",\"target\":\"$tcp_target\",\"intervalSeconds\":3600,\"timeoutMillis\":1000,\"failureThreshold\":1}" | json "['id']")
check_equal 'both checks are probed by the monitor and go UP' True "$(truth wait_for 60 both_up)"

# 1. Rules, and nothing down.
rule_all=$(api POST "$alr/rule/initiate" "{\"name\":\"Everything\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\"}" "${staff[@]}")
rule_web=$(api POST "$alr/rule/initiate" "{\"name\":\"Intranet\",\"checkId\":\"$web\",\"impact\":\"HIGH\",\"urgency\":\"HIGH\",\"requesterId\":\"$filed_for\"}" "${staff[@]}")
rule_all_id=$(api_body "$rule_all" | json "['id']")
rule_web_id=$(api_body "$rule_web" | json "['id']")
check_equal 'a rule for every check: 201, ACTIVE' '201/ACTIVE/None' "$(api_status "$rule_all")/$(api_body "$rule_all" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d.get('checkId')))")"
check_equal 'a rule for one check: 201, tied to it' "201/$web" "$(api_status "$rule_web")/$(api_body "$rule_web" | json "['checkId']")"
dup=$(api POST "$alr/rule/initiate" "{\"name\":\"Everything\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\"}" "${staff[@]}")
check_equal 'a rule name already in use is refused (409 ERR-ALR-00409)' '409/ERR-ALR-00409' "$(api_status "$dup")/$(api_body "$dup" | json "['error_code']")"
check_equal 'a rule must name the requester the incident is filed for (400)' 400 "$(st POST "$alr/rule/initiate" '{"name":"No requester","impact":"LOW","urgency":"LOW"}')"
check_equal 'the rules are listed oldest first' 'Everything,Intranet' "$(stb GET "$alr/rule/retrieve" | python3 -c "import json,sys; print(','.join(r['name'] for r in json.load(sys.stdin)))")"
check_equal 'nothing is down: an evaluation opens nothing' '0/0/0' "$(evaluate | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['opened'], d['resolved'], d['incidentsOpened']))")"
check_equal 'no alert and no incident' '0/0' "$(alert_count '')/$(incident_count)"

# 2. A check goes down: an alert and a real incident, decided by the OLDEST active rule that covers it.
target /__mock/status '{"status":503}'
check_equal 'the monitor sees the check DOWN' DOWN "$(run_check "$web")"
evaluate > /dev/null
check_equal 'an alert is opened for it (by an evaluation or by the scheduler)' True "$(truth wait_for 20 has_alerts 1)"
first_id=$(alerts '' | json "[0]['id']")
first_incident=$(alerts '' | json "[0]['incidentId']")
check_equal 'it is OPEN, names the check and the fixed error, and has its incident' 'OPEN/Intranet/unexpected status/True' \
  "$(alerts '' | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print('%s/%s/%s/%s' % (d['status'], d['checkName'], d['lastError'], bool(d.get('incidentId'))))")"
check_equal 'the incident is filed: title, NEW, requester and the asset the check watches' "Health check down: Intranet/NEW/$filed_for/$asset_id" \
  "$(incident "$first_incident" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s' % (d['title'], d['status'], d['requesterId'], ','.join(d['affectedAssetIds'])))")"
check_equal 'the OLDEST rule decided (LOW x LOW is P4), not the newer rule made for this very check' 'LOW/LOW/P4' \
  "$(incident "$first_incident" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['impact'], d['urgency'], d['priority']))")"
check_equal 'the incident names the service identity that opened it' 'system:alerting' "$(stb GET "$inc/$first_incident/audit-log/retrieve" | json "[0]['executor']")"
check_equal 'the alert trail says it opened and its incident did' 'OPENED,INCIDENT_OPENED' "$(trail "$alr/$first_id")"

# 3. ONE incident per outage.
for _ in 1 2 3; do evaluate > /dev/null; done
sleep 12
check_equal 'more evaluations and the scheduler own rounds open nothing more: still one alert and one incident' '1/1' "$(alert_count '')/$(incident_count)"
check_equal 'an evaluation says so: nothing opened' '0/0' "$(evaluate | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['opened'], d['incidentsOpened']))")"
target /__mock/tcp '{"open":false}'
check_equal 'a second outage: the database check is DOWN' DOWN "$(run_check "$db")"
for i in 1 2 3 4; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$alr/evaluation/execute" > "$tmp/e$i" ) &
done
wait
others=0
for i in 1 2 3 4; do [[ "$(cat "$tmp/e$i")" == 200 ]] || others=$((others + 1)); done
check_equal 'four evaluations at once: every one is answered 200' 0 "$others"
sleep 6
check_equal 'and they opened exactly ONE alert and ONE incident for the second outage' '1/2/2' "$(alert_count "?checkId=$db")/$(alert_count '')/$(incident_count)"
check_equal 'it has its incident too' True "$(alerts "?checkId=$db" | python3 -c "import json,sys; print(bool(json.load(sys.stdin)[0].get('incidentId')))")"

# 4. Recovery: resolved, an INTERNAL note, the incident is not closed.
target /__mock/status '{"status":200}'
check_equal 'the check is UP again' UP "$(run_check "$web")"
evaluate > /dev/null
check_equal 'its alert is RESOLVED' True "$(truth wait_for 20 web_resolved)"
check_equal 'it knows when it resolved and keeps its incident' "True/$first_incident" \
  "$(alerts "?checkId=$web" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print('%s/%s' % (bool(d.get('resolvedAt')), d['incidentId']))")"
check_equal 'the alert trail reads in order' 'OPENED,INCIDENT_OPENED,RESOLVED' "$(trail "$alr/$first_id")"
check_equal 'only the status filter shows it: one resolved, one open' '1/1' "$(alert_count '?status=RESOLVED')/$(alert_count '?status=OPEN')"
check_equal 'the incident got exactly one note, INTERNAL, from the service identity' '1/True/system:alerting' \
  "$(incident "$first_incident" | python3 -c "import json,sys; c=json.load(sys.stdin)['comments']; print('%s/%s/%s' % (len(c), c[0]['internal'], c[0]['author']))")"
check_equal 'and it was NOT closed or resolved: a person decides that' NEW "$(incident "$first_incident" | json "['status']")"
check_equal 'the person it was filed for does not see the internal note' 0 "$(api_body "$(rq GET "$inc/$first_incident/retrieve")" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['comments']))")"
evaluate > /dev/null
check_equal 'a resolved alert is not touched again: still one note' 1 "$(incident "$first_incident" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['comments']))")"

# 5. A new outage is a new alert; a paused rule is skipped; no active rule opens nothing; an open alert is still resolved.
check_equal 'pause the oldest rule' 204 "$(st PUT "$alr/rule/$rule_all_id/control/pause")"
check_equal 'pausing it twice is an illegal transition (409)' 409 "$(st PUT "$alr/rule/$rule_all_id/control/pause")"
target /__mock/status '{"status":503}'
check_equal 'the check goes DOWN again' DOWN "$(run_check "$web")"
evaluate > /dev/null
check_equal 'a NEW alert is opened: the first one is history' True "$(truth wait_for 20 has_web_alerts 2)"
second_incident=$(newest_field "$web" "['incidentId']")
check_equal 'the newest first: OPEN, a different alert, with an incident' 'OPEN/True/True' \
  "$(alerts "?checkId=$web" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print('%s/%s/%s' % (d['status'], d['id'] != '$first_id', bool(d.get('incidentId'))))")"
check_equal 'the paused rule was skipped: the next rule decided (HIGH x HIGH is P1)' 'HIGH/HIGH/P1' \
  "$(incident "$second_incident" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['impact'], d['urgency'], d['priority']))")"
check_equal 'three incidents so far: one per outage' 3 "$(incident_count)"
check_equal 'pause the other rule too: no rule is active' 204 "$(st PUT "$alr/rule/$rule_web_id/control/pause")"
target /__mock/status '{"status":200}'
check_equal 'with no active rule the open alert is still resolved when its check recovers' UP "$(run_check "$web")"
evaluate > /dev/null
check_equal 'it is RESOLVED' True "$(truth wait_for 20 web_resolved)"
target /__mock/status '{"status":503}'
run_check "$web" > /dev/null
evaluate > /dev/null
sleep 7
check_equal 'a third outage with no active rule opens nothing: no new alert, no new incident' '2/3' "$(alert_count "?checkId=$web")/$(incident_count)"
target /__mock/status '{"status":200}'
run_check "$web" > /dev/null
target /__mock/tcp '{"open":true}'
check_equal 'the database is back too' UP "$(run_check "$db")"
evaluate > /dev/null
check_equal 'its alert is RESOLVED although every rule is paused' True "$(truth wait_for 20 db_resolved)"
check_equal 'nothing is left open' 0 "$(alert_count '?status=OPEN')"
check_equal 'resume a rule' 204 "$(st PUT "$alr/rule/$rule_web_id/control/resume")"
check_equal 'the rule trail reads in order' 'INITIATED,PAUSED,RESUMED' "$(trail "$alr/rule/$rule_web_id")"
check_equal 'update a rule (204)' 204 "$(st PUT "$alr/rule/$rule_web_id/update" "{\"name\":\"Intranet\",\"checkId\":\"$web\",\"impact\":\"MEDIUM\",\"urgency\":\"HIGH\",\"requesterId\":\"$filed_for\"}")"
check_equal 'and it reads back as updated' MEDIUM "$(stb GET "$alr/rule/$rule_web_id/retrieve" | json "['impact']")"

# 6. Staff only, the tenant, and no hand-written alerts.
denied=$(rq POST "$alr/rule/initiate" "{\"name\":\"r\",\"impact\":\"LOW\",\"urgency\":\"LOW\",\"requesterId\":\"$filed_for\"}")
check_equal 'a REQUESTER cannot create a rule (403 ERR-ALR-00403)' '403/ERR-ALR-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'a REQUESTER cannot list the rules (403)' 403 "$(api_status "$(rq GET "$alr/rule/retrieve")")"
check_equal 'a REQUESTER cannot list the alerts (403)' 403 "$(api_status "$(rq GET "$alr/retrieve")")"
check_equal 'a REQUESTER cannot read an alert (403)' 403 "$(api_status "$(rq GET "$alr/$first_id/retrieve")")"
check_equal 'a REQUESTER cannot evaluate (403)' 403 "$(api_status "$(rq PUT "$alr/evaluation/execute")")"
check_equal 'a REQUESTER cannot pause a rule (403)' 403 "$(api_status "$(rq PUT "$alr/rule/$rule_web_id/control/pause")")"
check_equal 'another tenant gets a 404 for the alert' 404 "$(api_status "$(api GET "$alr/$first_id/retrieve" "" "${other_tenant[@]}")")"
check_equal 'and for the rule' 404 "$(api_status "$(api GET "$alr/rule/$rule_web_id/retrieve" "" "${other_tenant[@]}")")"
check_equal 'and finds no alert in the list' 0 "$(api_body "$(api GET "$alr/retrieve" "" "${other_tenant[@]}")" | count)"
check_equal 'its evaluation finds nothing to do' 0 "$(api_body "$(api PUT "$alr/evaluation/execute" "" "${other_tenant[@]}")" | json "['opened']")"
check_equal 'the tenant is mandatory (400)' 400 "$(api_status "$(api GET "$alr/retrieve" "" "X-Executor: $staff_user")")"
post_status=$(st POST "$alr/initiate" "{\"checkId\":\"$web\"}")
check_equal 'an alert cannot be written by hand (404 or 405)' True "$([[ "$post_status" == 404 || "$post_status" == 405 ]] && echo True || echo False)"
delete_status=$(st DELETE "$alr/rule/$rule_web_id")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 7. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-alerting'))" <<<"$entries")
  [[ "$recorded" -ge 20 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 20 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-alerting'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Alerting smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
