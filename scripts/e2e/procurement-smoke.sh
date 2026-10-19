#!/usr/bin/env bash
# Live proof of Journey 15, sixth service (procurement ADR-030..034): purchase orders through the platform gateway, against the REAL approval service.
# An order is drafted and sent for approval (the approval is filed on the shared approval service), an approver who is not eligible is refused with the
# reason, an eligible approver approves it, it is placed and received in part; the same receipt reported twenty times at once is one, twenty receipts of one
# unit against a line with five to arrive leave exactly five (never more than was ordered), a delivery reference cannot be reused with another quantity, a placed
# order with goods received cannot be cancelled, a rejection is final, fixed lists and identifiers (nothing a tool says is repeated), staff only, the tenant, and
# every mutation on the ledger.
#
# Needs the purchase-order ApprovalPolicy provision-change-management.sh writes to thinklab-platform/.e2e/procurement-policy.json, and it-procurement
# restarted with THINKLAB_PO_POLICY_ID set from it (see .github/workflows/e2e.yml).
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
po="$gateway/it-procurement/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
policy_file="${POLICY_FILE:-$(dirname "$0")/../../.e2e/procurement-policy.json}"
checks=0
failed=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[[ -f "$policy_file" ]] || { echo "Missing $policy_file - run provision-change-management.sh first." >&2; exit 1; }

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }
today_plus() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1]))).isoformat())" "$1"; }

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

approver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['approverIds'][0])" "$policy_file")
outsider=$(uuid)
tenant_id=$(uuid); user=$(uuid); requester=$(uuid); requester_user=$(uuid); vendor=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
dock=("$tenant" 'X-Executor: dock-1')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester_user" 'X-Role: REQUESTER'; }
field() { stb GET "$po/$1/retrieve" | json "['$2']"; }
# order_json REFERENCE [LINES_JSON] [EXPECTED_ON_JSON]
default_lines='[{"category":"HARDWARE","item":"LAP-14","quantity":10,"unitPrice":1500.00},{"category":"SOFTWARE","item":"OFFICE-E3","quantity":5,"unitPrice":20}]'
order_json() { local lines=${2:-$default_lines}; printf '{"reference":"%s","vendorId":"%s","requesterId":"%s","currency":"BRL","expectedOn":%s,"lines":%s}' "$1" "$vendor" "$requester" "${3:-null}" "$lines"; }
line_json() { printf '[{"category":"SUPPLIES","item":"%s","quantity":%s,"unitPrice":1.50}]' "$1" "$2"; }
decide() { api PUT "$po/$1/approval/capture" "{\"approverId\":\"$2\",\"outcome\":\"$3\"}" "${staff[@]}"; }
receive() { api POST "$po/$1/receipt/initiate" "{\"lineNo\":$2,\"deliveryRef\":\"$3\",\"quantity\":$4}" "${dock[@]}"; }
# approved_and_placed REFERENCE LINES_JSON -> id of an order that is ORDERED
placed() {
  local id; id=$(stb POST "$po/initiate" "$(order_json "$1" "$2")" | json "['id']")
  st PUT "$po/$id/control/submit" > /dev/null
  decide "$id" "$approver" APPROVE > /dev/null
  st PUT "$po/$id/control/place" > /dev/null
  echo "$id"
}

# 1. A draft: lines in minor units, the total, nothing received.
first=$(api POST "$po/initiate" "$(order_json PO-1 '' "\"$(today_plus 30)\"")" "${staff[@]}")
order=$(api_body "$first" | json "['id']")
check_equal 'a purchase order is drafted (201): DRAFT, a total of 15100.00 in BRL, two lines, NOT_ORDERED' '201/DRAFT/15100.0/BRL/2/NOT_ORDERED' \
  "$(api_status "$first")/$(api_body "$first" | json "['status']")/$(api_body "$first" | json "['total']")/$(api_body "$first" | json "['currency']")/$(api_body "$first" | json "['lines'].__len__()")/$(api_body "$first" | json "['fulfilment']")"
check_equal 'the same reference again is a conflict (409)' 409 "$(st POST "$po/initiate" "$(order_json PO-1)")"
check_equal 'a draft is updated (204): the lines are replaced and the total follows' '204/1/30.0' \
  "$(st PUT "$po/$order/update" "{\"vendorId\":\"$vendor\",\"expectedOn\":null,\"lines\":$(line_json PEN-BLUE 20)}")/$(field "$order" lines | python3 -c "import sys,ast; print(len(ast.literal_eval(sys.stdin.read())))")/$(field "$order" total)"
check_equal 'the list finds it by status and by vendor, and not by another status' "$order/0" "$(stb GET "$po/retrieve?status=DRAFT&vendorId=$vendor" | json "[0]['id']")/$(stb GET "$po/retrieve?status=APPROVED" | count)"

# 2. Approval through the REAL approval service.
check_equal 'an order with no lines cannot be sent for approval (400)' 400 "$(st PUT "$po/$(stb POST "$po/initiate" "$(order_json PO-EMPTY '[]')" | json "['id']")/control/submit")"
check_equal 'it is sent for approval (204): PENDING_APPROVAL, with the approval request kept' '204/PENDING_APPROVAL/True' \
  "$(st PUT "$po/$order/control/submit")/$(field "$order" status)/$([[ -n "$(field "$order" approvalRequestId)" && "$(field "$order" approvalRequestId)" != None ]] && echo True || echo False)"
check_equal 'it cannot be sent again (409) and no longer updated (409)' '409/409' "$(st PUT "$po/$order/control/submit")/$(st PUT "$po/$order/update" "{\"vendorId\":\"$vendor\",\"expectedOn\":null,\"lines\":$(line_json PEN-BLUE 1)}")"
refused=$(decide "$order" "$outsider" APPROVE)
check_equal 'an approver who is not eligible is refused by the approval service (409 ERR-PRC-00409) and the order stays waiting' '409/ERR-PRC-00409/PENDING_APPROVAL' \
  "$(api_status "$refused")/$(api_body "$refused" | json "['error_code']")/$(field "$order" status)"
approved=$(decide "$order" "$approver" APPROVE)
check_equal 'an eligible approver approves (one approval is the quorum): the order is APPROVED' '200/APPROVED' "$(api_status "$approved")/$(api_body "$approved" | json "['status']")"
check_equal 'a decision on an order not waiting is refused (409)' 409 "$(api_status "$(decide "$order" "$approver" APPROVE)")"
check_equal 'it is placed with the vendor (204): ORDERED, NONE received' '204/ORDERED/NONE' "$(st PUT "$po/$order/control/place")/$(field "$order" status)/$(field "$order" fulfilment)"

# 3. A rejection is final.
rejected_order=$(stb POST "$po/initiate" "$(order_json PO-REJ "$(line_json CABLE 2)")" | json "['id']")
st PUT "$po/$rejected_order/control/submit" > /dev/null
check_equal 'an eligible approver rejects: REJECTED' REJECTED "$(api_body "$(decide "$rejected_order" "$approver" REJECT)" | json "['status']")"
check_equal 'a rejected order cannot be placed or cancelled (409 each)' '409/409' "$(st PUT "$po/$rejected_order/control/place")/$(st PUT "$po/$rejected_order/control/cancel")"

# 4. Receiving: partial, idempotent, never more than ordered.
two=$(placed PO-2 '[{"category":"HARDWARE","item":"LAP-14","quantity":10,"unitPrice":1500.00},{"category":"SOFTWARE","item":"OFFICE-E3","quantity":5,"unitPrice":20}]')
first_receipt=$(receive "$two" 1 DN-100 4)
check_equal 'four of line 1 arrive (201): PARTIAL, six still to arrive' '201/PARTIAL/6' "$(api_status "$first_receipt")/$(field "$two" fulfilment)/$(field "$two" lines | python3 -c "import sys,ast; print(ast.literal_eval(sys.stdin.read())[0]['remaining'])")"
check_equal 'the same receipt again is 200 and nothing is counted twice' '200/6' "$(api_status "$(receive "$two" 1 DN-100 4)")/$(field "$two" lines | python3 -c "import sys,ast; print(ast.literal_eval(sys.stdin.read())[0]['remaining'])")"
check_equal 'a delivery reference reused with another quantity is a conflict (409)' 409 "$(api_status "$(receive "$two" 1 DN-100 5)")"
check_equal 'more than is still to arrive is a conflict (409)' 409 "$(api_status "$(receive "$two" 1 DN-101 7)")"
check_equal 'an unknown line is refused (400)' 400 "$(api_status "$(receive "$two" 9 DN-102 1)")"
check_equal 'the rest of line 1 and all of line 2 arrive: COMPLETE' 'COMPLETE' "$( receive "$two" 1 DN-103 6 > /dev/null; receive "$two" 2 DN-103 5 > /dev/null; field "$two" fulfilment)"
check_equal 'the receipts are kept in order, with who reported them' 'DN-100,DN-103,DN-103/dock-1' \
  "$(stb GET "$po/$two/receipt/retrieve" | python3 -c "import json,sys; r=json.load(sys.stdin); print(','.join(x['deliveryRef'] for x in r) + '/' + r[0]['reportedBy'])")"
check_equal 'an order that received goods cannot be cancelled (409)' 409 "$(st PUT "$po/$two/control/cancel")"
check_equal 'a draft takes no receipt (409)' 409 "$(api_status "$(receive "$(stb POST "$po/initiate" "$(order_json PO-DRAFT)" | json "['id']")" 1 DN-1 1)")"

# 5. The same receipt twenty times at once is one; twenty receipts of one unit against five to arrive leave exactly five.
race=$(placed PO-RACE "$(line_json PEN-RED 10)")
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: dock-$i" \
      -d '{"lineNo":1,"deliveryRef":"DN-SAME","quantity":4}' "$po/$race/receipt/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other_count=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other_count=$((other_count + 1));; esac
done
check_equal 'the same delivery reference received by twenty people at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other_count"
check_equal 'it was counted once: six still to arrive, one receipt' '6/1' "$(field "$race" lines | python3 -c "import sys,ast; print(ast.literal_eval(sys.stdin.read())[0]['remaining'])")/$(stb GET "$po/$race/receipt/retrieve" | count)"
five=$(placed PO-FIVE "$(line_json PEN-GREEN 5)")
for i in $(seq 1 20); do
  ( curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: dock-$i" \
      -d "{\"lineNo\":1,\"deliveryRef\":\"DN-$i\",\"quantity\":1}" "$po/$five/receipt/initiate" > "$tmp/five$i" ) &
done
wait
created_count=0; refused_count=0; other_count=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/five$i")" in 201) created_count=$((created_count + 1));; 409) refused_count=$((refused_count + 1));; *) other_count=$((other_count + 1));; esac
done
check_equal 'twenty receipts of one unit against five to arrive: exactly five accepted (201), fifteen refused (409), no other answer' '5/15/0' "$created_count/$refused_count/$other_count"
check_equal 'never more than was ordered: nothing is left to arrive, five receipts, COMPLETE' '0/5/COMPLETE' \
  "$(field "$five" lines | python3 -c "import sys,ast; print(ast.literal_eval(sys.stdin.read())[0]['remaining'])")/$(stb GET "$po/$five/receipt/retrieve" | count)/$(field "$five" fulfilment)"

# 6. Cancelling, and the trail.
unreceived=$(placed PO-CANCEL "$(line_json PEN-BLACK 3)")
check_equal 'a placed order with nothing received is cancelled (204), and cannot be cancelled twice (409)' '204/CANCELLED/409' "$(st PUT "$po/$unreceived/control/cancel")/$(field "$unreceived" status)/$(st PUT "$po/$unreceived/control/cancel")"
check_equal 'the trail holds each real change once, in order' 'INITIATED,SUBMITTED,APPROVED,PLACED,RECEIVED,RECEIVED,RECEIVED' \
  "$(stb GET "$po/$two/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"
check_equal 'the list finds the ordered ones that are complete and none that are late' "COMPLETE/0" "$(stb GET "$po/retrieve?fulfilment=COMPLETE&limit=1" | json "[0]['fulfilment']")/$(stb GET "$po/retrieve?late=true" | count)"

# 7. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(api POST "$po/initiate" "$(order_json PO-B1 '[{"category":"JEWELRY-secret","item":"X","quantity":1,"unitPrice":1}]')" "${staff[@]}")
check_equal 'an unknown category is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('JEWELRY' in sys.stdin.read())")"
sentence=$(api POST "$po/initiate" "$(order_json PO-B2 '[{"category":"OTHER","item":"two red pens, please secret","quantity":1,"unitPrice":1}]')" "${staff[@]}")
check_equal 'an item that is a sentence is refused (400) and not repeated' '400/False' "$(api_status "$sentence")/$(api_body "$sentence" | python3 -c "import sys; print('secret' in sys.stdin.read())")"
check_equal 'a price with three decimals is refused (400)' 400 "$(st POST "$po/initiate" "$(order_json PO-B3 '[{"category":"OTHER","item":"X","quantity":1,"unitPrice":1.005}]')")"
check_equal 'a quantity of zero is refused (400)' 400 "$(st POST "$po/initiate" "$(order_json PO-B4 '[{"category":"OTHER","item":"X","quantity":0,"unitPrice":1}]')")"
check_equal 'a reference with a space is refused (400)' 400 "$(st POST "$po/initiate" "$(order_json 'PO B5')")"
check_equal 'an unknown currency is refused (400)' 400 "$(st POST "$po/initiate" "$(order_json PO-B6 | sed 's/"BRL"/"JPY"/')")"
check_equal 'an expected day in the past is refused (400)' 400 "$(st POST "$po/initiate" "$(order_json PO-B7 '' "\"$(today_plus -1)\"")")"
check_equal 'a day that cannot be read is refused (400) and not repeated' '400/False' \
  "$(api_status "$(api POST "$po/initiate" "$(order_json PO-B8 '' '"secret-tomorrow"')" "${staff[@]}")")/$(api_body "$(api POST "$po/initiate" "$(order_json PO-B8 '' '"secret-tomorrow"')" "${staff[@]}")" | python3 -c "import sys; print('secret' in sys.stdin.read())")"

# 8. Staff only, the tenant.
check_equal 'a REQUESTER cannot draft an order (403 ERR-PRC-00403)' '403/ERR-PRC-00403' \
  "$(api_status "$(rq POST "$po/initiate" "$(order_json PO-R1)")")/$(api_body "$(rq POST "$po/initiate" "$(order_json PO-R1)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read, list or receive (403)' '403/403/403' "$(api_status "$(rq GET "$po/$order/retrieve")")/$(api_status "$(rq GET "$po/retrieve")")/$(api_status "$(rq POST "$po/$two/receipt/initiate" '{"lineNo":1,"deliveryRef":"DN-R","quantity":1}')")"
check_equal 'another tenant gets a 404 for the order and finds none' '404/0' "$(api_status "$(api GET "$po/$order/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$po/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$po/$order")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 9. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-procurement'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-procurement'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; t=sys.stdin.read(); print('secret' in t or 'JEWELRY' in t)" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Procurement smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
