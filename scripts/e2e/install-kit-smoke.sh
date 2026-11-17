#!/usr/bin/env bash
# Live proof of Journey 17 (install-kit ADR-030): the Quick Install back end through the platform gateway. A kit is a recipe (system, language, machine
# class), never a machine; a server kit is English only; a kit is retired and reinstated, never deleted, and every update raises its revision; the stick
# definition lists only the active kits; a report keeps the revision that ran, may be filed against a retired kit and is a fact (nothing edits it); twenty
# simultaneous registrations of one name make one kit; staff only; the tenant; and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
ikt="$gateway/it-install-kit/v1"
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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
kit_json() { printf '{"name":"%s","family":"WINDOWS","role":"%s","language":"%s","systemId":"%s","machineClass":"%s"}' "$1" "$2" "$3" "$4" "$5"; }
report_json() { printf '{"kitId":"%s","addOnVersion":"1.2.2","outcome":"%s","warnings":%s,"occurredAt":"2026-11-17T12:00:00Z"}' "$1" "$2" "$3"; }
kit_field() { stb GET "$ikt/$1/retrieve" | json "$2"; }

# 1. A kit is a recipe.
created=$(api POST "$ikt/initiate" "$(kit_json 'Windows 11 EN BASE' WORKSTATION EN W11 BASE)" "${staff[@]}")
kit=$(api_body "$created" | json "['id']")
check_equal 'staff register a kit: 201, ACTIVE, revision 1' '201/ACTIVE/1' "$(api_status "$created")/$(api_body "$created" | json "['status']")/$(api_body "$created" | json "['revision']")"
check_equal 'the list finds it by status and family and not by another family' "1/0" \
  "$(stb GET "$ikt/retrieve?status=ACTIVE&family=WINDOWS" | count)/$(stb GET "$ikt/retrieve?family=LINUX" | count)"
check_equal 'a server kit in Portuguese is refused (400)' 400 "$(st POST "$ikt/initiate" "$(kit_json 'Server PT' SERVER PT S19 BASE)")"
check_equal 'a system id that is not a short code is refused (400)' 400 "$(st POST "$ikt/initiate" "$(kit_json 'Odd' WORKSTATION EN 'not a code!' BASE)")"
check_equal 'the same name in the same organisation is a conflict (409)' 409 "$(st POST "$ikt/initiate" "$(kit_json 'Windows 11 EN BASE' WORKSTATION EN W11 BASE)")"

# 2. An update raises the revision; retire and reinstate go one way each.
check_equal 'an update is accepted (204)' 204 "$(st PUT "$ikt/$kit/update" "$(kit_json 'Windows 11 PT P520' WORKSTATION PT W11 P520)")"
check_equal 'and it is kept, at revision 2' 'PT/P520/2' "$(kit_field "$kit" "['language']")/$(kit_field "$kit" "['machineClass']")/$(kit_field "$kit" "['revision']")"
check_equal 'reinstating an active kit is a conflict (409)' 409 "$(st PUT "$ikt/$kit/control/reinstate")"
sticks=$(stb GET "$ikt/stick-definition/retrieve")
check_equal 'the stick definition lists the active kit under its system, at its revision' '1/W11/2' \
  "$(json "['kitCount']" <<<"$sticks")/$(json "['systems'][0]['systemId']" <<<"$sticks")/$(json "['systems'][0]['kits'][0]['revision']" <<<"$sticks")"

# 3. Reports are facts; they keep the revision that ran, even on a retired kit.
report=$(api POST "$ikt/install-report/initiate" "$(report_json "$kit" PARTIAL 2)" "${staff[@]}")
report_id=$(api_body "$report" | json "['id']")
check_equal 'a report is filed: 201, with the kit revision that ran' '201/2/PARTIAL' "$(api_status "$report")/$(api_body "$report" | json "['kitRevision']")/$(api_body "$report" | json "['outcome']")"
check_equal 'the retire is accepted (204) and the stick definition no longer lists the kit' '204/0' \
  "$(st PUT "$ikt/$kit/control/retire")/$(stb GET "$ikt/stick-definition/retrieve" | json "['kitCount']")"
check_equal 'a retired kit can still be reported on (201)' 201 "$(st POST "$ikt/install-report/initiate" "$(report_json "$kit" SUCCEEDED 0)")"
check_equal 'the reports are found by kit and outcome' "2/1/0" \
  "$(stb GET "$ikt/install-report/retrieve?kitId=$kit" | count)/$(stb GET "$ikt/install-report/retrieve?kitId=$kit&outcome=PARTIAL" | count)/$(stb GET "$ikt/install-report/retrieve?outcome=FAILED" | count)"
check_equal 'a report of an unknown kit is a 404' 404 "$(st POST "$ikt/install-report/initiate" "$(report_json "$(uuid)" FAILED 0)")"
check_equal 'a malformed add-on version is refused (400)' 400 "$(st POST "$ikt/install-report/initiate" "$(report_json "$kit" FAILED 0 | sed 's/1.2.2/v1/')")"
check_equal 'there is no way to change or delete a report (405 or 404)' True "$(code=$(st PUT "$ikt/install-report/$report_id/update" '{}'); [[ "$code" == 404 || "$code" == 405 ]] && echo True || echo False)"
check_equal 'reinstating brings the kit back (204) and the audit log keeps every step' '204/INITIATED,UPDATED,RETIRED,REINSTATED' \
  "$(st PUT "$ikt/$kit/control/reinstate")/$(stb GET "$ikt/$kit/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 4. Twenty simultaneous registrations of one name make one kit.
for i in $(seq 1 20); do
  api POST "$ikt/initiate" "$(kit_json 'Race kit' WORKSTATION EN W10 BASE)" "${staff[@]}" >"$tmp/race-$i" &
done
wait
created_count=$(for f in "$tmp"/race-*; do head -1 "$f"; done | grep -c '^201$')
check_equal 'twenty at once: exactly one kit is created' "1/1" "$created_count/$(stb GET "$ikt/retrieve?family=WINDOWS" | python3 -c "import json,sys; print(sum(1 for k in json.load(sys.stdin) if k['name']=='Race kit'))")"

# 5. Staff only, and the tenant.
check_equal 'a requester is refused on every route (403)' '403/403/403/403' \
  "$(api_status "$(rq GET "$ikt/retrieve")")/$(api_status "$(rq GET "$ikt/stick-definition/retrieve")")/$(api_status "$(rq GET "$ikt/install-report/retrieve")")/$(api_status "$(rq POST "$ikt/initiate" "$(kit_json 'Nope' WORKSTATION EN W11 BASE)")")"
check_equal 'another tenant sees none of it' '404/0' \
  "$(api_status "$(api GET "$ikt/$kit/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$ikt/retrieve" "" "${other_tenant[@]}")" | count)"

# 6. Every mutation is on the ledger.
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(len([e for e in json.load(sys.stdin) if e['resourceType']=='it-install-kit']))" <<<"$entries")
  [[ "$recorded" -ge 10 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger' True "$([[ "$recorded" -ge 10 ]] && echo True || echo False)"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Install kit smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
