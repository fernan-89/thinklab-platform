#!/usr/bin/env bash
# Live proof of Journey 14, first service (bash port of health-monitoring-smoke.ps1; health-monitoring ADR-030..033): health monitoring
# through the platform gateway, against the target double (docker compose --profile health-test): the scheduler probing by itself, a blip
# that is not an outage, recovery, a TCP target that refuses, a slow one, a redirect that is not followed, the target policy, the summary,
# staff only, a race, and every mutation on the ledger.
# The monitor reaches the double as TARGET_INTERNAL_HOST (mock-target, ports 9200 and 9201), this script as CONTROL_URL (http://localhost:9290).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
control="${CONTROL_URL:-http://localhost:9290}"
target_host="${TARGET_INTERNAL_HOST:-mock-target}"
http_port="${TARGET_HTTP_PORT:-9200}"
tcp_port="${TARGET_TCP_PORT:-9201}"
hlm="$gateway/it-health-monitoring/v1"
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

tenant_id=$(uuid); staff_user=$(uuid); requester=$(uuid); asset_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $staff_user")
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $staff_user")
http_target="http://$target_host:$http_port/health"
tcp_target="$target_host:$tcp_port"

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
new_check() { api POST "$hlm/initiate" "$1" "${staff[@]}"; }
check_field() { stb GET "$hlm/$1/retrieve" | json "$2"; }
run_check() { stb PUT "$hlm/$1/check/execute"; }
result_count() { stb GET "$hlm/$1/results/retrieve?limit=500" | count; }
actions() { stb GET "$hlm/$1/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))"; }
is_up() { [[ "$(check_field "$1" "['health']")" == UP ]]; }
has_results() { [[ "$(result_count "$1")" -ge "$2" ]]; }
more_results_than() { [[ "$(result_count "$1")" -gt "$2" ]]; }

# 1. The scheduler probes by itself.
created=$(new_check "{\"name\":\"Intranet\",\"type\":\"HTTP\",\"target\":\"$http_target\",\"assetId\":\"$asset_id\",\"intervalSeconds\":10,\"timeoutMillis\":2000}")
s=$(api_body "$created" | json "['id']")
check_equal 'staff start watching an HTTP target: 201, ACTIVE, UNKNOWN, every 10 s' '201/ACTIVE/UNKNOWN/10' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['health'], d['intervalSeconds']))")"
check_equal 'with no one asking, the scheduler probes it and it goes UP' True "$(truth wait_for 60 is_up "$s")"
check_equal 'it knows when it was probed, how long it took and that nothing is wrong' 'True/True/False' \
  "$(stb GET "$hlm/$s/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (bool(d.get('lastCheckedAt')), d.get('lastLatencyMillis') is not None, bool(d.get('lastError'))))")"
check_equal 'and it keeps probing: a second probe arrives by itself' True "$(truth wait_for 45 has_results "$s" 2)"
check_equal 'the history holds what each probe saw (newest first)' 'True/200' \
  "$(stb GET "$hlm/$s/results/retrieve?limit=5" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print('%s/%s' % (d['ok'], d['statusCode']))")"
check_equal 'pause' 204 "$(st PUT "$hlm/$s/control/pause")"
sleep 4
paused_count=$(result_count "$s")
sleep 13
check_equal 'a paused check is no longer probed on its own' "$paused_count" "$(result_count "$s")"
check_equal 'pausing twice is an illegal transition (409)' 409 "$(st PUT "$hlm/$s/control/pause")"
check_equal 'resume' 204 "$(st PUT "$hlm/$s/control/resume")"
check_equal 'resuming makes it due at once: it is probed again without waiting an interval' True "$(truth wait_for 12 more_results_than "$s" "$paused_count")"
check_equal 'resuming an active check is an illegal transition (409)' 409 "$(st PUT "$hlm/$s/control/resume")"
st PUT "$hlm/$s/control/pause" > /dev/null

# 2. A blip is not an outage. A long interval keeps the scheduler out of the way after its first probe.
m=$(api_body "$(new_check "{\"name\":\"Portal\",\"type\":\"HTTP\",\"target\":\"$http_target\",\"intervalSeconds\":3600,\"timeoutMillis\":2000,\"failureThreshold\":2,\"successThreshold\":1}")" | json "['id']")
check_equal 'its first probe is made by the scheduler: UP' True "$(truth wait_for 60 is_up "$m")"
target /__mock/status '{"status":503}'
check_equal 'one failure: the check is still UP, one failure counted' 'UP/1/unexpected status' \
  "$(run_check "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['health'], d['consecutiveFailures'], d['lastError']))")"
check_equal 'the second failure in a row takes it DOWN' 'DOWN/2' \
  "$(run_check "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['health'], d['consecutiveFailures']))")"
target /__mock/status '{"status":200}'
check_equal 'one success brings it back UP, the error cleared' 'UP/False' \
  "$(run_check "$m" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['health'], bool(d.get('lastError'))))")"
check_equal 'the audit trail holds exactly the changes of health, not every probe' 'INITIATED,BECAME_UP,WENT_DOWN,BECAME_UP' "$(actions "$m")"

# 3. TCP.
t=$(api_body "$(new_check "{\"name\":\"Database\",\"type\":\"TCP\",\"target\":\"$tcp_target\",\"intervalSeconds\":3600,\"timeoutMillis\":1000,\"failureThreshold\":2}")" | json "['id']")
check_equal 'a TCP check is UP when the connection opens' True "$(truth wait_for 60 is_up "$t")"
target /__mock/tcp '{"open":false}'
run_check "$t" > /dev/null
check_equal 'with the listener closed: DOWN, with the fixed code "connection refused"' 'DOWN/connection refused' \
  "$(run_check "$t" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['health'], d['lastError']))")"
target /__mock/tcp '{"open":true}'
check_equal 'with the listener open again: UP' UP "$(run_check "$t" | json "['health']")"

# 4. Timeout, and a redirect that is not followed.
d=$(api_body "$(new_check "{\"name\":\"Slow\",\"type\":\"HTTP\",\"target\":\"$http_target\",\"intervalSeconds\":3600,\"timeoutMillis\":500,\"failureThreshold\":1}")" | json "['id']")
target /__mock/delay '{"ms":2500}'
check_equal 'a target that answers too slowly: DOWN, "timeout"' 'DOWN/timeout' \
  "$(run_check "$d" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['health'], d['lastError']))")"
target /__mock/delay '{"ms":0}'
e=$(api_body "$(new_check "{\"name\":\"Redirecting\",\"type\":\"HTTP\",\"target\":\"http://$target_host:$http_port/redirect\",\"intervalSeconds\":3600,\"timeoutMillis\":2000,\"expectedStatus\":200,\"failureThreshold\":1}")" | json "['id']")
run_check "$e" > /dev/null
check_equal 'a redirect is an answer, not followed: DOWN with the 302 and "unexpected status"' 'DOWN/302/unexpected status' \
  "$(check_field "$e" "['health']")/$(stb GET "$hlm/$e/results/retrieve?limit=1" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print('%s/%s' % (d['statusCode'], d['error']))")"

# 5. The target policy.
check_equal 'the cloud metadata address is refused (400)' 400 "$(api_status "$(new_check '{"name":"p1","type":"HTTP","target":"http://169.254.169.254/latest/meta-data"}')")"
check_equal 'a link-local address over TCP is refused (400)' 400 "$(api_status "$(new_check '{"name":"p2","type":"TCP","target":"169.254.0.7:80"}')")"
check_equal 'the decimal spelling of the metadata address is refused (400)' 400 "$(api_status "$(new_check '{"name":"p3","type":"HTTP","target":"http://2852039166/"}')")"
check_equal 'credentials in the URL are refused (400)' 400 "$(api_status "$(new_check '{"name":"p4","type":"HTTP","target":"https://bot:secret@intranet.acme.test/"}')")"
check_equal 'a query string, where tokens end up, is refused (400)' 400 "$(api_status "$(new_check '{"name":"p5","type":"HTTP","target":"https://intranet.acme.test/health?token=abc"}')")"
check_equal 'a name already in use is refused (409)' 409 "$(api_status "$(new_check '{"name":"Intranet","type":"TCP","target":"db.internal:5432"}')")"
check_equal 'an update to a forbidden target is refused too (400)' 400 "$(st PUT "$hlm/$m/update" '{"name":"Portal","target":"http://169.254.169.254/"}')"
check_equal 'a timeout longer than the interval is refused (400)' 400 "$(api_status "$(new_check '{"name":"p6","type":"TCP","target":"db.internal:5432","intervalSeconds":10,"timeoutMillis":20000}')")"

# 6. Summary and filters.
check_equal 'the summary counts the active checks by health, and the paused apart (5 checks: 2 up, 2 down, 1 paused)' '5/2/2/0/1' \
  "$(stb GET "$hlm/summary/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s/%s' % (d['total'], d['up'], d['down'], d['unknown'], d['paused']))")"
check_equal 'the DOWN checks are found by health' 2 "$(stb GET "$hlm/retrieve?health=DOWN" | count)"
check_equal 'the paused one is found by status' "$s" "$(stb GET "$hlm/retrieve?status=PAUSED" | python3 -c "import json,sys; print(','.join(c['id'] for c in json.load(sys.stdin)))")"
check_equal 'and the check that watches an asset is found by asset' "$s" "$(stb GET "$hlm/retrieve?assetId=$asset_id" | python3 -c "import json,sys; print(','.join(c['id'] for c in json.load(sys.stdin)))")"

# 7. Staff only, the tenant, and a race.
denied=$(rq POST "$hlm/initiate" '{"name":"r","type":"TCP","target":"db.internal:5432"}')
check_equal 'a REQUESTER cannot start monitoring (403 ERR-HLM-00403)' '403/ERR-HLM-00403' "$(api_status "$denied")/$(api_body "$denied" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a check (403)' 403 "$(api_status "$(rq GET "$hlm/$m/retrieve")")"
check_equal 'a REQUESTER cannot list the checks (403)' 403 "$(api_status "$(rq GET "$hlm/retrieve")")"
check_equal 'a REQUESTER cannot read the summary (403)' 403 "$(api_status "$(rq GET "$hlm/summary/retrieve")")"
check_equal 'a REQUESTER cannot run a check (403)' 403 "$(api_status "$(rq PUT "$hlm/$m/check/execute")")"
check_equal 'a REQUESTER cannot read the results (403)' 403 "$(api_status "$(rq GET "$hlm/$m/results/retrieve")")"
check_equal 'another tenant gets a 404 for the check' 404 "$(api_status "$(api GET "$hlm/$m/retrieve" "" "${other_tenant[@]}")")"
check_equal 'nor can it run it' 404 "$(api_status "$(api PUT "$hlm/$m/check/execute" "" "${other_tenant[@]}")")"
check_equal 'and finds none in the list' 0 "$(api_body "$(api GET "$hlm/retrieve" "" "${other_tenant[@]}")" | count)"
check_equal 'the tenant is mandatory (400)' 400 "$(api_status "$(api GET "$hlm/$m/retrieve" "" "X-Executor: $staff_user")")"
target /__mock/status '{"status":503}'
for i in 1 2 3 4; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$hlm/$m/check/execute" > "$tmp/r$i" ) &
done
wait
others=0
for i in 1 2 3 4; do [[ "$(cat "$tmp/r$i")" == 200 ]] || others=$((others + 1)); done
check_equal 'four people running the same failing check at once: every one is answered 200' 0 "$others"
run_check "$m" > /dev/null
check_equal 'the check is DOWN and the trail holds exactly one more change of health: none was lost or doubled' 'DOWN/INITIATED,BECAME_UP,WENT_DOWN,BECAME_UP,WENT_DOWN' "$(check_field "$m" "['health']")/$(actions "$m")"
target /__mock/status '{"status":200}'
delete_status=$(st DELETE "$hlm/$m")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 8. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-health-monitoring'))" <<<"$entries")
  [[ "$recorded" -ge 25 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 25 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-health-monitoring'))" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Health monitoring smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
