#!/usr/bin/env bash
# Live proof of Journey 14, third service (bash port of backup-smoke.ps1; backup-registry ADR-030..033): the backup registry through the
# platform gateway. A policy is judged when read, a run is a fact, twenty simultaneous reports of one run make one run, the summary only moves
# forward whatever the order of the reports, a failure reason is never free text, two people pausing at once get one winner, staff only, the
# tenant, and every mutation on the ledger without anything a tool said.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
bkp="$gateway/it-backup-registry/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
minutes_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); asset_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: backup-agent-1')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$bkp/run/initiate" "$1" "${tool[@]}"; }
field() { stb GET "$bkp/$policy/retrieve" | json "$1"; }
run_json() { printf '{"policyId":"%s","kind":"%s","outcome":"%s","startedAt":"%s","finishedAt":"%s"%s}' "$policy" "$1" "$2" "$3" "$4" "${5:-}"; }
policy_json() { printf '{"name":"%s","assetId":"%s","frequencyHours":24,"rpoHours":48,"rtoMinutes":%s,"retentionDays":30,"restoreTestEveryDays":30}' "$1" "$asset_id" "$2"; }

# 1. A policy is a promise, judged when read.
created=$(api POST "$bkp/initiate" "$(policy_json 'Database nightly' 120)" "${staff[@]}")
policy=$(api_body "$created" | json "['id']")
check_equal 'staff promise a backup every 24 h with at most 48 h lost: 201, ACTIVE, NEVER backed up yet' '201/ACTIVE/NEVER' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['status'], d['protection']))")"
check_equal 'the list finds it by protection NEVER and by asset' "$policy/$policy" \
  "$(stb GET "$bkp/retrieve?protection=NEVER&assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")/$(stb GET "$bkp/retrieve?assetId=$asset_id" | python3 -c "import json,sys; print(','.join(p['id'] for p in json.load(sys.stdin)))")"

# 2. A tool reports; the same run twenty times at once is one run.
start=$(minutes_ago 300); finish=$(minutes_ago 280)
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: backup-agent-$i" \
      -d "$(run_json BACKUP SUCCEEDED "$start" "$finish" ',"sizeBytes":1048576')" "$bkp/run/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same backup reported by twenty agents at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other"
check_equal 'every answer is the same run' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'and the list holds exactly one run for the policy' 1 "$(stb GET "$bkp/run/retrieve?policyId=$policy" | count)"
check_equal 'the policy is OK, protected 48 h after that backup finished, 20 minutes long' 'OK/True' \
  "$(field "['protection']")/$(stb GET "$bkp/run/retrieve?policyId=$policy" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['durationMinutes'] == 20)")"

# 3. The summary only moves forward.
newer_start=$(minutes_ago 120); newer_finish=$(minutes_ago 100)
older_start=$(minutes_ago 200); older_finish=$(minutes_ago 180)
check_equal 'a newer backup is reported (201)' 201 "$(api_status "$(report "$(run_json BACKUP SUCCEEDED "$newer_start" "$newer_finish")")")"
check_equal 'an older backup reported late is stored too (201)' 201 "$(api_status "$(report "$(run_json BACKUP SUCCEEDED "$older_start" "$older_finish")")")"
check_equal 'but the last success is still the newer one: a late report moves nothing back' "$newer_finish" "$(field "['lastSuccessAt']")"
failed_start=$(minutes_ago 60); failed_finish=$(minutes_ago 55)
check_equal 'a failed backup names one reason from the list (201)' '201/STORAGE_FULL' \
  "$(api_status "$(report "$(run_json BACKUP FAILED "$failed_start" "$failed_finish" ',"failureReason":"STORAGE_FULL"')")")/$(stb GET "$bkp/run/retrieve?policyId=$policy&outcome=FAILED" | json "[0]['failureReason']")"
check_equal 'it moves the last run, not the last success' "$failed_finish/$newer_finish" "$(field "['lastRunAt']")/$(field "['lastSuccessAt']")"
check_equal 'the runs are listed newest start first, and limited' 'FAILED/1' \
  "$(stb GET "$bkp/run/retrieve?policyId=$policy" | json "[0]['outcome']")/$(stb GET "$bkp/run/retrieve?policyId=$policy&limit=1" | count)"

# 4. A failure reason is never what the tool said.
secret='password=hunter2'
denied=$(report "$(run_json BACKUP FAILED "$(minutes_ago 40)" "$(minutes_ago 35)" ",\"failureReason\":\"$secret\"")")
check_equal 'a failure reason in the tool'"'"'s own words is refused (400)' 400 "$(api_status "$denied")"
check_equal 'and the answer does not repeat it' False "$(api_body "$denied" | python3 -c "import sys; print('hunter2' in sys.stdin.read())")"
check_equal 'a failed run without a reason is refused (400)' 400 "$(api_status "$(report "$(run_json BACKUP FAILED "$(minutes_ago 40)" "$(minutes_ago 35)")")")"
check_equal 'a run that finishes in the future is refused (400)' 400 "$(api_status "$(report "$(run_json BACKUP SUCCEEDED "$(minutes_ago -60)" "$(minutes_ago -90)")")")"

# 5. The recovery is proved by a restore test.
check_equal 'before a restore test, the recovery time is unknown (the field is left out)' None "$(field ".get('rtoMet')")"
check_equal 'a restore test that took 20 minutes is reported (201)' 201 "$(api_status "$(report "$(run_json RESTORE_TEST SUCCEEDED "$(minutes_ago 30)" "$(minutes_ago 10)")")")"
check_equal 'it meets the 120 minute objective, took 20, and left the last success alone' "True/20/$newer_finish" "$(field "['rtoMet']")/$(field "['lastRestoreMinutes']")/$(field "['lastSuccessAt']")"
check_equal 'a tighter objective of 10 minutes (update, 204)' 204 "$(st PUT "$bkp/$policy/update" "$(policy_json 'Database nightly' 10)")"
check_equal 'the same restore test now misses it, and the summary was kept' 'False/20' "$(field "['rtoMet']")/$(field "['lastRestoreMinutes']")"
check_equal 'an RPO shorter than the frequency is refused (400)' 400 "$(st PUT "$bkp/$policy/update" "{\"name\":\"n\",\"assetId\":\"$asset_id\",\"frequencyHours\":24,\"rpoHours\":12,\"rtoMinutes\":10,\"retentionDays\":30}")"

# 6. Two people pause at once: one wins.
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$bkp/$policy/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused policy is not judged' 'PAUSED/PAUSED' "$(field "['status']")/$(field "['protection']")"
check_equal 'resume' 204 "$(st PUT "$bkp/$policy/control/resume")"
check_equal 'the trail holds each real change once, in order' 'INITIATED,UPDATED,PAUSED,RESUMED' \
  "$(stb GET "$bkp/$policy/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 7. Staff only, the tenant.
check_equal 'a REQUESTER cannot promise a backup (403 ERR-BKP-00403)' '403/ERR-BKP-00403' \
  "$(api_status "$(rq POST "$bkp/initiate" "$(policy_json 'r' 120)")")/$(api_body "$(rq POST "$bkp/initiate" "$(policy_json 'r' 120)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read a policy (403)' 403 "$(api_status "$(rq GET "$bkp/$policy/retrieve")")"
check_equal 'a REQUESTER cannot report a run (403)' 403 "$(api_status "$(rq POST "$bkp/run/initiate" "$(run_json BACKUP SUCCEEDED "$(minutes_ago 500)" "$(minutes_ago 490)")")")"
check_equal 'a REQUESTER cannot list the runs (403)' 403 "$(api_status "$(rq GET "$bkp/run/retrieve")")"
check_equal 'another tenant gets a 404 for the policy' 404 "$(api_status "$(api GET "$bkp/$policy/retrieve" "" "${other_tenant[@]}")")"
check_equal 'another tenant cannot report a run for it (404)' 404 "$(api_status "$(api POST "$bkp/run/initiate" "$(run_json BACKUP SUCCEEDED "$(minutes_ago 500)" "$(minutes_ago 490)")" "${other_tenant[@]}")")"
check_equal 'and finds no runs' 0 "$(api_body "$(api GET "$bkp/run/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$bkp/$policy")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 8. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-backup-registry'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-backup-registry'))" <<<"$entries")"
check_equal 'nothing a tool said is on the ledger' False "$(python3 -c "import sys; print('hunter2' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Backup smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
