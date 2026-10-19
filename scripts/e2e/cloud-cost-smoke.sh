#!/usr/bin/env bash
# Live proof of Journey 15, fourth service (bash port of cloud-cost-smoke.ps1; cloud-cost ADR-030..033): cloud costs through the platform gateway.
# An account in one currency is judged when read over the current UTC month (spent, a straight line to the month end, OK, near its budget, over
# it), the same day and amount reported by twenty tools at once is one report, another amount is a correction and going back to an earlier one
# counts again, last month stays out of this month, a day may be one day ahead and no more, nothing a tool says is repeated, two people pausing at
# once get one winner, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
cc="$gateway/it-cloud-cost/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
# day OFFSET -> a UTC day relative to today; first / last_of_previous / days_in_month of the current UTC month.
day() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }
first_day=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).date().replace(day=1).isoformat())")
last_of_previous=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc).date().replace(day=1) - datetime.timedelta(days=1)).isoformat())")
days_in_month=$(python3 -c "import calendar,datetime; t=datetime.datetime.now(datetime.timezone.utc).date(); print(calendar.monthrange(t.year, t.month)[1])")

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); vendor_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: billing-export')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$cc/cost/initiate" "$1" "${tool[@]}"; }
cost_json() { printf '{"accountId":"%s","day":"%s","amount":%s}' "$1" "$2" "$3"; }
account_json() { printf '{"name":"%s","provider":"%s","externalId":"%s","currency":"%s","monthlyBudget":%s,"warnPercent":80,"reportEveryHours":24,"vendorId":"%s"}' "$1" "$2" "$3" "$4" "$5" "$vendor_id"; }
# judged ID -> level/spent/projected, amounts with two decimals.
judged() { stb GET "$cc/$1/retrieve" | python3 -c "
import json,sys; d=json.load(sys.stdin); f=lambda v: 'None' if v is None else '%.2f' % v
print('%s/%s/%s' % (d['level'], f(d.get('spent')), f(d.get('projected'))))"; }
line() { python3 -c "import sys; print('%.2f' % (float(sys.argv[1]) * int(sys.argv[2])))" "$1" "$days_in_month"; }

# 1. An account is a provider account in one currency with a monthly budget, judged when read.
created=$(api POST "$cc/initiate" "$(account_json 'Production' AWS 123456789012 USD 3100.00)" "${staff[@]}")
account=$(api_body "$created" | json "['id']")
check_equal 'staff register an AWS account in USD with 3100.00 a month: 201, ACTIVE, NO_DATA' '201/ACTIVE/NO_DATA/USD' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['status'], d['level'], d['currency']))")"
check_equal 'the list finds it by provider and currency, and not by another currency' "$account/$account/0" \
  "$(stb GET "$cc/retrieve?provider=AWS" | json "[0]['id']")/$(stb GET "$cc/retrieve?currency=USD" | json "[0]['id']")/$(stb GET "$cc/retrieve?currency=EUR" | count)"
check_equal 'a second account with the same name is a conflict (409)' 409 "$(st POST "$cc/initiate" "$(account_json 'Production' GCP other-project EUR 1)")"
check_equal 'a second account for the same provider account is a conflict (409)' 409 "$(st POST "$cc/initiate" "$(account_json 'Other name' AWS 123456789012 USD 1)")"

# 2. Days move the verdict: OK, NEAR_BUDGET from the line, back to OK, OVER_BUDGET.
first=$(report "$(cost_json "$account" "$first_day" 50.00)")
first_id=$(api_body "$first" | json "['id']")
check_equal 'the first day is a new fact: 201, the amount kept, reported by the tool' '201/50.0/billing-export' "$(api_status "$first")/$(api_body "$first" | json "['amount']")/$(api_body "$first" | json "['reportedBy']")"
check_equal '50.00 on day one heads well under the budget: OK, the line at 50.00 times the days of the month' "OK/50.00/$(line 50)" "$(judged "$account")"
again=$(report "$(cost_json "$account" "$first_day" 50.00)")
check_equal 'the same day and amount again is the stored report (200)' "200/$first_id" "$(api_status "$again")/$(api_body "$again" | json "['id']")"
check_equal 'a correction to 120.00 is a new report (201): NEAR_BUDGET from the line' "201/NEAR_BUDGET/120.00/$(line 120)" \
  "$(api_status "$(report "$(cost_json "$account" "$first_day" 120.00)")")/$(judged "$account")"
back=$(report "$(cost_json "$account" "$first_day" 50.00)")
check_equal 'back to 50.00 is the first report, restated (200), and it counts again: OK' "200/$first_id/OK/50.00/$(line 50)" "$(api_status "$back")/$(api_body "$back" | json "['id']")/$(judged "$account")"
check_equal 'a correction to 3200.00 (201): OVER_BUDGET' "201/OVER_BUDGET/3200.00/$(line 3200)" "$(api_status "$(report "$(cost_json "$account" "$first_day" 3200.00)")")/$(judged "$account")"
check_equal 'the list finds it by level OVER_BUDGET and not by OK' "$account/0" "$(stb GET "$cc/retrieve?level=OVER_BUDGET" | json "[0]['id']")/$(stb GET "$cc/retrieve?level=OK" | count)"

# 3. The same new amount reported by twenty tools at once is one report.
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: billing-export-$i" \
      -d "$(cost_json "$account" "$first_day" 3300.00)" "$cc/cost/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other=$((other + 1));; esac
done
check_equal 'the same day and amount reported by twenty tools at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other"
check_equal 'every answer is the same report' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'the account holds exactly four reports, and the month counts 3300.00' '4/OVER_BUDGET/3300.00' \
  "$(stb GET "$cc/cost/retrieve?accountId=$account" | count)/$(judged "$account" | cut -d/ -f1,2)"

# 4. The month is this month; a day may be one day ahead, no more.
check_equal 'a late cost for last month is new (201) and stays out of this month' '201/3300.00' \
  "$(api_status "$(report "$(cost_json "$account" "$last_of_previous" 99999.99)")")/$(judged "$account" | cut -d/ -f2)"
check_equal 'the reports are listed newest day first, latest stated first, and limited' '3300.0,3200.0' \
  "$(stb GET "$cc/cost/retrieve?accountId=$account&limit=2" | python3 -c "import json,sys; print(','.join(str(r['amount']) for r in json.load(sys.stdin)))")"
second=$(stb POST "$cc/initiate" "$(account_json 'Data platform' AZURE 'sub-0f3c:prod' EUR 500.00)" | json "['id']")
check_equal 'a cost for tomorrow is accepted (the provider day may be ahead): 201' 201 "$(api_status "$(report "$(cost_json "$second" "$(day 1)" 0.01)")")"
check_equal 'a cost two days ahead is refused (400)' 400 "$(api_status "$(report "$(cost_json "$second" "$(day 2)" 0.01)")")"

# 5. A bigger budget changes the verdict at once, because nothing of it is stored.
check_equal 'update to 10000.00 a month (204)' 204 "$(st PUT "$cc/$account/update" '{"name":"Production","monthlyBudget":10000.00,"warnPercent":80,"reportEveryHours":24}')"
check_equal '3300.00 on day one still heads over 10000.00: NEAR_BUDGET' 'NEAR_BUDGET/3300.00' "$(judged "$account" | cut -d/ -f1,2)"

# 6. Two people pause at once: one wins.
for i in 1 2; do
  ( curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "$tenant" -H "X-Executor: $(uuid)" "$cc/$account/control/pause" > "$tmp/p$i" ) &
done
wait
check_equal 'two people pausing at once: one 204 and one 409' '204/409' "$(sort "$tmp/p1" "$tmp/p2" | paste -sd/ -)"
check_equal 'a paused account is not judged' 'PAUSED/None/None' "$(judged "$account")"
check_equal 'a paused account still accepts costs (201)' 201 "$(api_status "$(report "$(cost_json "$account" "$first_day" 1.00)")")"
check_equal 'resume' 204 "$(st PUT "$cc/$account/control/resume")"
check_equal 'the account trail holds each real change once, in order' 'INITIATED,UPDATED,PAUSED,RESUMED' \
  "$(stb GET "$cc/$account/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 7. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(api POST "$cc/initiate" "$(account_json 'n' 'AWS-secret-value' x1 USD 1)" "${staff[@]}")
check_equal 'an unknown provider is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('secret-value' in sys.stdin.read())")"
badday=$(report "{\"accountId\":\"$account\",\"day\":\"secret-yesterday\",\"amount\":1}")
check_equal 'a day that cannot be read is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$badday")/$(api_body "$badday" | python3 -c "import sys; print('secret' in sys.stdin.read())")"
check_equal 'an amount with three decimals is refused (400)' 400 "$(api_status "$(report "$(cost_json "$account" "$first_day" 1.005)")")"
check_equal 'a negative amount is refused (400)' 400 "$(api_status "$(report "$(cost_json "$account" "$first_day" -1.00)")")"
check_equal 'an unknown currency is refused (400)' 400 "$(st POST "$cc/initiate" "$(account_json 'Yen' AWS y1 JPY 1)")"
check_equal 'a cost for an account that is not the tenant'"'"'s is a 404' 404 "$(api_status "$(report "$(cost_json "$(uuid)" "$first_day" 1.00)")")"

# 8. Staff only, the tenant.
check_equal 'a REQUESTER cannot register an account (403 ERR-CLD-00403)' '403/ERR-CLD-00403' \
  "$(api_status "$(rq POST "$cc/initiate" "$(account_json 'r' AWS r1 USD 1)")")/$(api_body "$(rq POST "$cc/initiate" "$(account_json 'r' AWS r1 USD 1)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read an account (403)' 403 "$(api_status "$(rq GET "$cc/$account/retrieve")")"
check_equal 'a REQUESTER cannot report a cost (403)' 403 "$(api_status "$(rq POST "$cc/cost/initiate" "$(cost_json "$account" "$first_day" 1.00)")")"
check_equal 'another tenant gets a 404 for the account and finds no reports' '404/0' \
  "$(api_status "$(api GET "$cc/$account/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$cc/cost/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$cc/$account")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 9. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-cloud-cost'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-cloud-cost'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('secret' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Cloud cost smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
