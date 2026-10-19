#!/usr/bin/env bash
# Live proof of alerting on broken promises (bash port of promises-alerting-smoke.ps1; alerting ADR-037): alerting through the platform gateway
# against the REAL patch, capacity and backup registries and the REAL incident service. A rule watches a registry; an overdue patch and a CRITICAL
# disk each open ONE alert and ONE incident that says a promise is not being kept, with a fixed error code; a second evaluation opens nothing; a
# registry no active rule watches is not judged (a backup that never ran opens nothing); a rule for one policy covers only that policy; the promise
# kept again (a waiver, a newer sample) resolves the alert and puts an internal note on the incident; rules keep their source; staff only. Then
# (ADR-038) a vendor agreement about to end opens one alert and a renewal resolves it, and (ADR-039) a licence over its limit opens one alert
# and freed seats resolve it, (ADR-041) a recovery plan that stops being ready, and (ADR-042) a cloud resource the tool has not seen for days (the smoke moves
# the moment the tool last saw it back in the store with docker exec on the MongoDB container, MONGO_CONTAINER) opens one alert and seeing it again resolves it.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
alr="$gateway/it-alerting/v1"
pch="$gateway/it-patch-registry/v1"
cap="$gateway/it-capacity-registry/v1"
bkp="$gateway/it-backup-registry/v1"
vnd="$gateway/it-vendor-registry/v1"
lic="$gateway/it-license-registry/v1"
dr="$gateway/it-dr-registry/v1"
inv_reg="$gateway/it-cloud-inventory/v1"
mongo_container="${MONGO_CONTAINER:-thinklab-mongo-1}"
po="$gateway/it-procurement/v1"
policy_file="${POLICY_FILE:-$(dirname "$0")/../../.e2e/procurement-policy.json}"
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

# 8. A recovery plan that stops being ready (ADR-041): a failed exercise opens one alert and one incident, a later pass resolves it.
plan=$(stb POST "$dr/initiate" "{\"name\":\"Orders failover\",\"assetId\":\"$patch_asset\",\"strategy\":\"WARM_STANDBY\",\"rtoMinutes\":120,\"rpoMinutes\":30,\"testEveryDays\":30}" | json "['id']")
check_equal 'a plan never exercised is NEVER_TESTED' NEVER_TESTED "$(stb GET "$dr/$plan/retrieve" | json "['readiness']")"
check_equal 'a rule for the DR registry is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Recovery plans' DR)")"
evaluate > /dev/null
check_equal 'a plan never exercised is not judged: nothing opens' 0 "$(stb GET "$alr/retrieve?checkId=$plan" | count)"
check_equal 'a failover that failed is reported with its fixed reason (201)' 201 "$(api_status "$(api POST "$dr/exercise/initiate" "{\"planId\":\"$plan\",\"kind\":\"FAILOVER\",\"outcome\":\"FAILED\",\"startedAt\":\"$(minutes -120)\",\"finishedAt\":\"$(minutes -100)\",\"failureReason\":\"DEPENDENCY_MISSING\"}" "${tool[@]}")")"
check_equal 'the plan is LAST_EXERCISE_FAILED' LAST_EXERCISE_FAILED "$(stb GET "$dr/$plan/retrieve" | json "['readiness']")"
evaluate > /dev/null
check_equal 'the plan gets one alert and one incident' True "$(truth wait_for 20 linked "$plan")"
check_equal 'the alert names the plan and the fixed code DR_EXERCISE_FAILED, and the incident says a promise is not being kept' 'Orders failover/DR_EXERCISE_FAILED/Promise broken: Orders failover/True' \
  "$(alert_of "$plan" "['checkName']")/$(alert_of "$plan" "['lastError']")/$(stb GET "$inc/$(alert_of "$plan" "['incidentId']")/retrieve" | json "['title']")/$(stb GET "$inc/$(alert_of "$plan" "['incidentId']")/retrieve" | python3 -c "import json,sys; print('is not being kept (DR_EXERCISE_FAILED)' in json.load(sys.stdin)['description'])")"
evaluate > /dev/null
check_equal 'more evaluations open nothing more for the plan' 1 "$(stb GET "$alr/retrieve?checkId=$plan" | count)"
check_equal 'a later failover that passed inside the objectives is reported (201)' 201 "$(api_status "$(api POST "$dr/exercise/initiate" "{\"planId\":\"$plan\",\"kind\":\"FAILOVER\",\"outcome\":\"SUCCEEDED\",\"startedAt\":\"$(minutes -60)\",\"finishedAt\":\"$(minutes -30)\",\"dataLossMinutes\":5}" "${tool[@]}")")"
check_equal 'the plan is READY again' READY "$(stb GET "$dr/$plan/retrieve" | json "['readiness']")"
evaluate > /dev/null
check_equal 'the pass resolves the alert' True "$(truth wait_for 20 status_is "$plan" RESOLVED)"

# 9. A cloud resource that goes missing (ADR-042). The inventory judges a resource missing after 48 hours of silence, so the smoke moves the moment the tool last
# saw it back in the store, the way two days passing would; everything else goes through the gateway.
account=$(uuid)
resource_json() { printf '{"accountId":"%s","provider":"AWS","externalId":"%s","name":"%s","kind":"COMPUTE","region":"us-east-1","state":"%s","tags":{}}' "$account" "$1" "$2" "$3"; }
report_resource() { api POST "$inv_reg/initiate" "$(resource_json "$1" "$2" "$3")" "${tool[@]}"; }
age() { docker exec "$mongo_container" mongosh --quiet --eval "db.getSiblingDB('thinklab_it_cloud_inventory_db').cloud_resources.updateOne({_id: UUID('$1')}, {\$set: {lastSeenAt: new Date(Date.now() - 5 * 24 * 3600 * 1000)}})" > /dev/null; }
vm=$(api_body "$(report_resource i-0missing web-1 RUNNING)" | json "['id']")
check_equal 'a resource the tool saw just now is PRESENT' PRESENT "$(stb GET "$inv_reg/$vm/retrieve" | json "['presence']")"
check_equal 'a rule for the cloud inventory is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Cloud resources' CLOUD_INVENTORY)")"
evaluate > /dev/null
check_equal 'a resource seen lately opens nothing' 0 "$(stb GET "$alr/retrieve?checkId=$vm" | count)"
age "$vm"
check_equal 'five days of silence: the inventory says MISSING' MISSING "$(stb GET "$inv_reg/$vm/retrieve" | json "['presence']")"
evaluate > /dev/null
check_equal 'the resource gets one alert and one incident' True "$(truth wait_for 20 linked "$vm")"
check_equal 'the alert names the resource and the fixed code CLOUD_RESOURCE_MISSING, and carries no provider id' 'web-1/CLOUD_RESOURCE_MISSING/False' \
  "$(alert_of "$vm" "['checkName']")/$(alert_of "$vm" "['lastError']")/$(stb GET "$alr/retrieve?checkId=$vm" | python3 -c "import sys; print('i-0missing' in sys.stdin.read())")"
evaluate > /dev/null
check_equal 'more evaluations open nothing more for the resource' 1 "$(stb GET "$alr/retrieve?checkId=$vm" | count)"
report_resource i-0missing web-1 RUNNING > /dev/null
check_equal 'the tool sees it again: PRESENT' PRESENT "$(stb GET "$inv_reg/$vm/retrieve" | json "['presence']")"
evaluate > /dev/null
check_equal 'seeing it again resolves the alert' True "$(truth wait_for 20 status_is "$vm" RESOLVED)"
gone=$(api_body "$(report_resource i-0gone old-1 RUNNING)" | json "['id']")
age "$gone"
report_resource i-0gone old-1 TERMINATED > /dev/null
check_equal 'a resource the tool said is terminated is GONE' GONE "$(stb GET "$inv_reg/$gone/retrieve" | json "['presence']")"
evaluate > /dev/null
check_equal 'a terminated resource opens nothing, however long ago it was seen' 0 "$(stb GET "$alr/retrieve?checkId=$gone" | count)"

# 10. A purchase order that is late (ADR-043). An order cannot be drafted with an expected day in the past, so the smoke moves the expected day of a placed order
# back in the store (docker exec, as for section 9); the approval goes through the REAL approval service with the purchase-order policy.
[[ -f "$policy_file" ]] || { echo "Missing $policy_file - run provision-change-management.sh first." >&2; exit 1; }
approver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['approverIds'][0])" "$policy_file")
order_body() { printf '{"reference":"%s","vendorId":"%s","requesterId":"%s","currency":"BRL","expectedOn":"%s","lines":[{"category":"HARDWARE","item":"LAP-14","quantity":10,"unitPrice":1500.00}]}' "$1" "$(uuid)" "$filed_for" "$(python3 -c "import datetime; print((datetime.date.today() + datetime.timedelta(days=5)).isoformat())")"; }
placed_order() {
  local id; id=$(stb POST "$po/initiate" "$(order_body "$1")" | json "['id']")
  st PUT "$po/$id/control/submit" > /dev/null
  api_status "$(api PUT "$po/$id/approval/capture" "{\"approverId\":\"$approver\",\"outcome\":\"APPROVE\"}" "${staff[@]}")" > /dev/null
  st PUT "$po/$id/control/place" > /dev/null
  echo "$id"
}
postpone() { docker exec "$mongo_container" mongosh --quiet --eval "db.getSiblingDB('thinklab_it_procurement_db').purchase_orders.updateOne({_id: UUID('$1')}, {\$set: {expectedOn: '$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=3)).isoformat())")'}})" > /dev/null; }
order=$(placed_order PO-LATE-1)
check_equal 'a placed order is not late while its expected day is ahead' 'ORDERED/False' "$(stb GET "$po/$order/retrieve" | json "['status']")/$(stb GET "$po/$order/retrieve" | json "['late']")"
check_equal 'a rule for the procurement registry is set (201)' 201 "$(st POST "$alr/rule/initiate" "$(rule_json 'Purchase orders' PROCUREMENT)")"
evaluate > /dev/null
check_equal 'an order that is not late opens nothing' 0 "$(stb GET "$alr/retrieve?checkId=$order" | count)"
postpone "$order"
check_equal 'three days past the expected day: the registry says it is late' True "$(stb GET "$po/$order/retrieve" | json "['late']")"
evaluate > /dev/null
check_equal 'the order gets one alert and one incident' True "$(truth wait_for 20 linked "$order")"
check_equal 'the alert names the order and the fixed code PURCHASE_ORDER_LATE, and carries no vendor or item' 'PO-LATE-1/PURCHASE_ORDER_LATE/False' \
  "$(alert_of "$order" "['checkName']")/$(alert_of "$order" "['lastError']")/$(stb GET "$alr/retrieve?checkId=$order" | python3 -c "import sys; t=sys.stdin.read(); print('LAP-14' in t)")"
evaluate > /dev/null
check_equal 'more evaluations open nothing more for the order' 1 "$(stb GET "$alr/retrieve?checkId=$order" | count)"
check_equal 'the goods are received completely (201)' 201 "$(api_status "$(api POST "$po/$order/receipt/initiate" '{"lineNo":1,"deliveryRef":"DN-LATE","quantity":10}' "${staff[@]}")")"
evaluate > /dev/null
check_equal 'receiving everything resolves the alert' True "$(truth wait_for 20 status_is "$order" RESOLVED)"
cancelled=$(placed_order PO-LATE-2)
postpone "$cancelled"
evaluate > /dev/null
check_equal 'a second late order gets its alert' True "$(truth wait_for 20 linked "$cancelled")"
check_equal 'it is cancelled (204)' 204 "$(st PUT "$po/$cancelled/control/cancel")"
evaluate > /dev/null
check_equal 'cancelling the order resolves the alert: nothing is owed' True "$(truth wait_for 20 status_is "$cancelled" RESOLVED)"

echo "Promises alerting smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
