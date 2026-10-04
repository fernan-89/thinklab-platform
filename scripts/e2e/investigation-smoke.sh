#!/usr/bin/env bash
# Live proof of the investigation procedure (bash port of investigation-smoke.ps1; gateway ADR-027): given the email of a KNOWN person,
# an administrator finds the pseudonym their sign-ins are recorded under and reads the ledger by it - and the lookup itself is on the
# ledger with its reason. Needs the stack up with the gateway started with GATEWAY_INVESTIGATION_ENABLED=true and
# GATEWAY_AUDIT_ENABLED=true (docker-compose.yml does that).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
pseudonym_url="$gateway/gateway/v1/investigation/pseudonym"
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

stamp=$(date +%s%3N)
tax_id=$(printf '%s0000000000000' "$stamp" | cut -c1-14)
org=$(api POST "$org_api/initiate" "{\"corporateName\":\"Investigation Corp\",\"tradeName\":\"INV\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@inv.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" 'X-Executor: investigation-smoke')
check_equal 'organisation created' 201 "$(api_status "$org")"
org_id=$(api_body "$org" | json "['id']")
tenant="X-Tenant-Id: $org_id"
admin_id=$(uuid)
reason='Ticket SEC-1234: unusual night access'
lookup() { api POST "$pseudonym_url" "$1" "$tenant" "X-Executor: $admin_id"; }
by_actor() { api_body "$(api GET "$ledger_api/retrieve?actor=$1&limit=50" "" "$tenant")"; }
count_lookups() { by_actor "$admin_id" | python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['action']=='POST /gateway/v1/investigation/pseudonym'))"; }

# 1. A sign-in attempt for a person we have a name for.
suspect_user="suspect.$(uuid | cut -c1-8)"
suspect="$suspect_user@example.com"
password="Sm0ke-P@ss-$(uuid | cut -c1-8)"
sign_in=$(api POST "$gateway/party-authentication/v1/session/initiate" "{\"organisationId\":\"$org_id\",\"email\":\"$suspect\",\"password\":\"$password\"}")
code=$(api_status "$sign_in")
check_equal 'a sign-in with unknown credentials is refused (4xx)' True "$([[ $code -ge 400 && $code -lt 500 ]] && echo True || echo False)"
recorded=''
for _ in $(seq 1 20); do
  recorded=$(api_body "$(api GET "$ledger_api/retrieve?limit=50" "" "$tenant")" | python3 -c "import json,sys,re; m=[e for e in json.load(sys.stdin) if e['action']=='POST /party-authentication/v1/session/initiate']; print(m[0]['actor'] if len(m)==1 and re.fullmatch(r'login:[0-9a-f]{32}', m[0]['actor']) else '')")
  [[ -n "$recorded" ]] && break
  sleep 0.5
done
check_equal 'the sign-in attempt was recorded under a pseudonym' True "$([[ -n "$recorded" ]] && echo True || echo False)"

# 2. The lookup.
answer=$(lookup "{\"email\":\"$suspect\",\"reason\":\"$reason\"}")
check_equal 'the lookup answers (200)' 200 "$(api_status "$answer")"
actor=$(api_body "$answer" | json "['actor']")
check_equal 'it answers the pseudonym the sign-in was recorded under' "$recorded" "$actor"
check_equal 'it says how to read the ledger by it' "/compliance-audit-ledger/v1/retrieve?actor=$actor" "$(api_body "$answer" | json "['ledgerQuery']")"
check_equal 'it says the lookup was recorded' True "$(api_body "$answer" | json "['recorded']")"
upper=$(lookup "{\"email\":\"${suspect^^}\",\"reason\":\"$reason\"}")
check_equal 'the pseudonym is stable whatever the capitals' "$actor" "$(api_body "$upper" | json "['actor']")"

# 3. Reading the ledger by that actor.
check_equal 'the ledger read by that actor returns the sign-in' 1 "$(by_actor "$actor" | python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['action']=='POST /party-authentication/v1/session/initiate'))")"
other=$(lookup "{\"email\":\"nobody.$(uuid | cut -c1-8)@example.com\",\"reason\":\"$reason\"}")
other_actor=$(api_body "$other" | json "['actor']")
check_equal 'another person has another pseudonym' True "$([[ "$other_actor" != "$actor" ]] && echo True || echo False)"
check_equal 'and nothing on the ledger' 0 "$(by_actor "$other_actor" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"

# 4. The lookup itself is on the ledger, with its reason, and no personal data anywhere.
check_equal 'every lookup is recorded against the administrator (three so far)' 3 "$(count_lookups)"
check_equal 'the record names the target pseudonym and the reason' True "$(by_actor "$admin_id" | python3 -c "import json,sys; print(any(('target=$actor;' in e['detail']) and e['detail'].endswith('reason=$reason') for e in json.load(sys.stdin)))")"
dump=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
check_equal 'the email appears nowhere on the ledger' False "$([[ "${dump,,}" == *"${suspect_user,,}"* ]] && echo True || echo False)"
check_equal 'the password appears nowhere on the ledger' False "$([[ "$dump" == *"$password"* ]] && echo True || echo False)"

# 5. What is refused.
check_equal 'a short reason is refused (400)' 400 "$(api_status "$(lookup "{\"email\":\"$suspect\",\"reason\":\"because\"}")")"
check_equal 'a reason that carries an email is refused (400)' 400 "$(api_status "$(lookup "{\"email\":\"$suspect\",\"reason\":\"Because bob@example.com did it\"}")")"
check_equal 'a missing reason is refused (400)' 400 "$(api_status "$(lookup "{\"email\":\"$suspect\"}")")"
check_equal 'refused lookups are not recorded as lookups (still three)' 3 "$(count_lookups)"

echo "Investigation smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
