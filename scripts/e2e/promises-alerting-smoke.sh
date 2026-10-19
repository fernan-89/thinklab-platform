#!/usr/bin/env bash
# Live proof of alerting on broken promises (bash port of promises-alerting-smoke.ps1; alerting ADR-037): alerting through the platform gateway
# against the REAL patch, capacity and backup registries and the REAL incident service. A rule watches a registry; an overdue patch and a CRITICAL
# disk each open ONE alert and ONE incident that says a promise is not being kept, with a fixed error code; a second evaluation opens nothing; a
# registry no active rule watches is not judged (a backup that never ran opens nothing); a rule for one policy covers only that policy; the promise
# kept again (a waiver, a newer sample) resolves the alert and puts an internal note on the incident; rules keep their source; staff only. Then
# (ADR-038) a vendor agreement about to end opens one alert and a renewal resolves it, and (ADR-039) a licence over its limit opens one alert
# and freed seats resolve it.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
alr="$gateway/it-alerting/v1"
pch="$gateway/it-patch-registry/v1"
cap="$gateway/it-capacity-registry/v1"
bkp="$gateway/it-backup-registry/v1"
vnd="$gateway/it-vendor-registry/v1"
lic="$gateway/it-license-registry/v1"
inc="$gateway/it-incident-management/v1"
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
minutes() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

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

tenant_id=$(uuid); user=$(uuid); filed_for=$(uuid); patch_asset=$(uuid); disk_asset=$(uuid); backup_asset=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: scanner-1')
as_requester=("$tenant" "X-Executor: $filed_for" 'X-Role: REQUESTER')

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
# The alerting scheduler also evaluates every few seconds, so a check never relies on what one evaluation did: it evaluates, then waits for the state.
wait_for() { local seconds=$1; shift; local end=$((SECONDS + seconds)); while (( SECONDS < end )); do "$@" && return 0; sleep 0.5; done; "$@"; }
truth() { if "$@"; then echo True; else echo False; fi; }
alerts_are() { [[ "$(stb GET "$alr/retrieve" | count)/$(stb GET "$inc/retrieve" | count)" == "$1" ]]; }
status_is() { [[ "$(stb GET "$alr/retrieve?checkId=$1" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a[0]['status'] if a else 'NONE')")" == "$2" ]]; }
linked() { [[ "$(stb GET "$alr/retrieve?checkId=$1" | python3 -c "import json,sys; a=json.load(sys.stdin); print(bool(a and a[0].get('incidentId')))")" == True ]]; }
evaluate() { stb PUT "$alr/evaluation/execute" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['opened'], d['resolved'], d['incidentsOpened']))"; }
alert_of() { stb GET "$alr/retrieve?checkId=$1" | json "[0]$2"; }
rule_json() { printf '{"name":"%s","source":"%s","impact":"HIGH","urgency":"MEDIUM","requesterId":"%s"%s}' "$1" "$2" "$filed_for" "${3:-}"; }

# 1. Three promises: an overdue patch, a disk at 96 of 100, a backup that never ran (not yet judged).
patch=$(api_body "$(api POST "$pch/initiate" "{\"name\":\"Servers\",\"assetId\":\"$patch_asset\",\"criticalDays\":2,\"highDays\":7,\"mediumDays\":30,\"lowDays\":90}" "${staff[@]}")" | json "['id']")
finding=$(api_body "$(api POST "$pch/finding/initiate" "{\"policyId\":\"$patch\",\"patchRef\":\"CVE-2026-1234\",\"severity\":\"CRITICAL\",\"announcedAt\":\"$(minutes -7200)\"}" "${tool[@]}")" | json "['id']")
disk=$(api_body "$(api POST "$cap/initiate" "{\"name\":\"Orders disk\",\"assetId\":\"$disk_asset\",\"metric\":\"DISK\",\"limit\":100,\"warnPercent\":70,\"criticalPercent\":90,\"windowDays\":30,\"horizonDays\":30,\"reportEveryHours\":24}" "${staff[@]}")" | json "['id']")
sample=$(api POST "$cap/sample/initiate" "{\"policyId\":\"$disk\",\"value\":96,\"measuredAt\":\"$(minutes -5)\"}" "${tool[@]}")
backup=$(api_body "$(api POST "$bkp/initiate" "{\"name\":\"Database nightly\",\"assetId\":\"$backup_asset\",\"frequencyHours\":24,\"rpoHours\":48,\"rtoMinutes\":120,\"retentionDays\":30}" "${staff[@]}")" | json "['id']")
check_equal 'the patch is OVERDUE, the disk CRITICAL and the backup, which never ran, NEVER' 'OVERDUE/CRITICAL/NEVER' \
  "$(stb GET "$pch/$patch/retrieve" | json "['compliance']")/$(stb GET "$cap/$disk/retrieve" | json "['level']")/$(stb GET "$bkp/$backup/retrieve" | json "['protection']")"

# 2. Rules keep their source; staff only; an unknown source is refused.
check_equal 'no rule yet: an evaluation opens nothing' '0/0/0' "$(evaluate)"
check_equal 'a rule with an unknown source is refused (400)' 400 "$(st POST "$alr/rule/initiate" "$(rule_json 'Printers' PRINTERS)")"
check_equal 'a REQUESTER cannot set a rule for the registries (403)' 403 "$(api_status "$(api POST "$alr/rule/initiate" "$(rule_json 'Patches' PATCH)" "${as_requester[@]}")")"
patch_rule=$(stb POST "$alr/rule/initiate" "$(rule_json 'Patches' PATCH)")
check_equal 'a rule for the patch registry keeps its source and covers every policy' 'PATCH/None' "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s' % (d['source'], d.get('checkId')))" <<<"$patch_rule")"
check_equal 'a rule for one disk policy keeps its source and its policy (201)' '201' "$(st POST "$alr/rule/initiate" "$(rule_json 'Orders disk only' CAPACITY ",\"checkId\":\"$disk\"")")"
check_equal 'a rule for a policy that is not the disk (a stranger id) watches nothing (201)' '201' "$(st POST "$alr/rule/initiate" "$(rule_json 'Stranger' CAPACITY ",\"checkId\":\"$(uuid)\"")")"
check_equal 'and a rule with no source is a health check rule' HEALTH_CHECK "$(stb POST "$alr/rule/initiate" "$(printf '{"name":"Checks","impact":"LOW","urgency":"LOW","requesterId":"%s"}' "$filed_for")" | json "['source']")"

# 3. One alert and one incident per broken promise; the backup, which no rule watches, is not judged.
evaluate > /dev/null
check_equal 'the patch and the disk each get one alert and one incident (by an evaluation or by the scheduler)' True "$(truth wait_for 20 alerts_are 2/2)"
evaluate > /dev/null
check_equal 'more evaluations open nothing more' True "$(truth alerts_are 2/2)"
check_equal 'two alerts and two incidents, and none for the backup' '2/2/0' "$(stb GET "$alr/retrieve" | count)/$(stb GET "$inc/retrieve" | count)/$(stb GET "$alr/retrieve?checkId=$backup" | count)"
check_equal 'the patch alert is OPEN, names the policy and the fixed code, and has its incident' 'OPEN/Servers/PATCH_OVERDUE/True' \
  "$(alert_of "$patch" "['status']")/$(alert_of "$patch" "['checkName']")/$(alert_of "$patch" "['lastError']")/$(alert_of "$patch" "['incidentId']" | python3 -c "import sys; print(sys.stdin.read().strip() not in ('None',''))")"
check_equal 'the disk alert says CAPACITY_CRITICAL' 'Orders disk/CAPACITY_CRITICAL' "$(alert_of "$disk" "['checkName']")/$(alert_of "$disk" "['lastError']")"
incident=$(stb GET "$inc/$(alert_of "$patch" "['incidentId']")/retrieve")
check_equal 'the incident says a promise is not being kept, for the asset of the policy' "Promise broken: Servers/True/$patch_asset" \
  "$(python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['title'], 'is not being kept (PATCH_OVERDUE)' in d['description'], ','.join(d['affectedAssetIds'])))" <<<"$incident")"

# 4. A rule for the backup registry: a backup that has never run is not judged, so it opens nothing.
check_equal 'a rule for the backup registry is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Backups' BACKUP)")"
evaluate > /dev/null
check_equal 'a backup that never ran is not a broken promise: nothing opens' True "$(truth alerts_are 2/2)"

# 5. Kept again: a waiver and a newer sample resolve the alerts and leave an internal note.
check_equal 'the patch is waived for ten minutes, accepted risk (204)' 204 "$(st PUT "$pch/finding/$finding/control/waive" "{\"reason\":\"ACCEPTED_RISK\",\"until\":\"$(minutes 10)\"}")"
check_equal 'a newer sample at 40 is reported (201)' 201 "$(api_status "$(api POST "$cap/sample/initiate" "{\"policyId\":\"$disk\",\"value\":40,\"measuredAt\":\"$(minutes -1)\"}" "${tool[@]}")")"
both_kept_again() { wait_for 20 status_is "$patch" RESOLVED && wait_for 20 status_is "$disk" RESOLVED && alerts_are 2/2; }
evaluate > /dev/null
check_equal 'both promises are kept again: both alerts are resolved, nothing opened' True "$(truth both_kept_again)"
check_equal 'the alerts are RESOLVED and the incidents were not closed' 'RESOLVED/RESOLVED/NEW' \
  "$(alert_of "$patch" "['status']")/$(alert_of "$disk" "['status']")/$(stb GET "$inc/$(alert_of "$patch" "['incidentId']")/retrieve" | json "['status']")"
evaluate > /dev/null
check_equal 'and a further evaluation changes nothing' True "$(truth alerts_are 2/2)"

# 6. A vendor agreement about to end (ADR-038): one alert and one incident; a renewal resolves it.
day() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }
vendor=$(stb POST "$vnd/initiate" '{"name":"Dell","category":"HARDWARE"}' | json "['id']")
agreement=$(stb POST "$vnd/agreement/initiate" "{\"vendorId\":\"$vendor\",\"kind\":\"WARRANTY\",\"reference\":\"WTY-77\",\"assetId\":\"$patch_asset\",\"startsOn\":\"$(day -300)\",\"endsOn\":\"$(day 10)\",\"noticeDays\":30,\"autoRenew\":false}" | json "['id']")
check_equal 'a warranty ending in 10 days with 30 days of notice is EXPIRING' EXPIRING "$(stb GET "$vnd/agreement/$agreement/retrieve" | json "['standing']")"
check_equal 'a rule for the vendor registry is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Agreements' VENDOR)")"
evaluate > /dev/null
check_equal 'the agreement about to end gets one alert and one incident' True "$(truth wait_for 20 linked "$agreement")"
check_equal 'the alert names the reference and AGREEMENT_EXPIRING, and the incident says so' 'WTY-77/AGREEMENT_EXPIRING/Promise broken: WTY-77' \
  "$(alert_of "$agreement" "['checkName']")/$(alert_of "$agreement" "['lastError']")/$(stb GET "$inc/$(alert_of "$agreement" "['incidentId']")/retrieve" | json "['title']")"
check_equal 'the warranty is renewed for two years (204)' 204 "$(st PUT "$vnd/agreement/$agreement/update" "{\"kind\":\"WARRANTY\",\"assetId\":\"$patch_asset\",\"startsOn\":\"$(day -300)\",\"endsOn\":\"$(day 730)\",\"noticeDays\":30,\"autoRenew\":false}")"
evaluate > /dev/null
check_equal 'the renewal resolves the alert' True "$(truth wait_for 20 status_is "$agreement" RESOLVED)"
check_equal 'the alert is RESOLVED' RESOLVED "$(alert_of "$agreement" "['status']")"

# 7. A licence over its limit (ADR-039): one alert and one incident; seats freed resolve it.
license=$(stb POST "$lic/initiate" '{"product":"Office 365 E3","unit":"USER","entitled":10,"warnPercent":90,"reportEveryHours":24}' | json "['id']")
count_at() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
check_equal '12 seats in use of 10 bought is OVER_LIMIT' '201/OVER_LIMIT' \
  "$(api_status "$(api POST "$lic/usage/initiate" "{\"licenseId\":\"$license\",\"inUse\":12,\"measuredAt\":\"$(count_at 10)\"}" "${tool[@]}")")/$(stb GET "$lic/$license/retrieve" | json "['level']")"
check_equal 'a rule for the licence registry is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Licences' LICENSE)")"
evaluate > /dev/null
check_equal 'the licence over its limit gets one alert and one incident' True "$(truth wait_for 20 linked "$license")"
check_equal 'the alert names the product and LICENSE_OVER_LIMIT' 'Office 365 E3/LICENSE_OVER_LIMIT' "$(alert_of "$license" "['checkName']")/$(alert_of "$license" "['lastError']")"
check_equal 'seats are freed: 9 in use is reported (201)' 201 "$(api_status "$(api POST "$lic/usage/initiate" "{\"licenseId\":\"$license\",\"inUse\":9,\"measuredAt\":\"$(count_at 1)\"}" "${tool[@]}")")"
evaluate > /dev/null
check_equal 'back within the limit (NEAR_LIMIT is not an incident): the alert is resolved' True "$(truth wait_for 20 status_is "$license" RESOLVED)"

echo "Promises alerting smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
