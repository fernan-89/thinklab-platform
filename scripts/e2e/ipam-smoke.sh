#!/usr/bin/env bash
# Live proof of Journey 15, third service (bash port of ipam-smoke.ps1; ipam ADR-030..033): IP address management through the platform gateway.
# A subnet is judged when read (OK, nearly full, full), an overlapping subnet is refused and of twenty overlapping creations at once exactly one
# survives, an address is held once (twenty requests for one address give one winner), twenty requests for the next free address at once all get
# a different one, a released address is handed out again, a retired subnet takes no address and cannot come back over a range taken meanwhile,
# nothing that is not an address is kept, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
ipm="$gateway/it-ipam/v1"
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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); site_id=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")

st() { api_status "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
subnet_json() { printf '{"name":"%s","cidr":"%s","warnPercent":%s,"siteId":"%s"}' "$1" "$2" "${3:-80}" "$site_id"; }
alloc_json() { if [[ -n "${2:-}" ]]; then printf '{"subnetId":"%s","ip":"%s"}' "$1" "$2"; else printf '{"subnetId":"%s"}' "$1"; fi; }
judged() { stb GET "$ipm/$1/retrieve" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s' % (d['level'], d['used'], d['free']))"; }
codes() { local ok=0 conflict=0 other=0; for i in $(seq 1 "$1"); do case "$(cat "$tmp/code$i")" in 201) ok=$((ok + 1));; 409) conflict=$((conflict + 1));; *) other=$((other + 1));; esac; done; echo "$ok/$conflict/$other"; }

# 1. A subnet is an IPv4 range, judged when read; an overlapping one is refused.
created=$(api POST "$ipm/initiate" "$(subnet_json 'Office LAN' 10.20.0.0/24)" "${staff[@]}")
office=$(api_body "$created" | json "['id']")
check_equal 'staff register 10.20.0.0/24: 201, ACTIVE, OK, 254 free, broadcast 10.20.0.255' '201/ACTIVE/OK/254/10.20.0.255' \
  "$(api_status "$created")/$(api_body "$created" | python3 -c "import json,sys; d=json.load(sys.stdin); print('%s/%s/%s/%s' % (d['status'], d['level'], d['free'], d['broadcast']))")"
check_equal 'the list finds it by site and status' "$office" "$(stb GET "$ipm/retrieve?siteId=$site_id&status=ACTIVE" | json "[0]['id']")"
overlap=$(api POST "$ipm/initiate" "$(subnet_json 'Inside' 10.20.0.128/25)" "${staff[@]}")
check_equal 'an overlapping range is refused (409) and the answer names the range it overlaps' '409/True' "$(api_status "$overlap")/$(api_body "$overlap" | python3 -c "import sys; print('10.20.0.0/24' in sys.stdin.read())")"
check_equal 'a CIDR with host bits set is refused (400)' 400 "$(st POST "$ipm/initiate" "$(subnet_json 'Host bits' 10.30.0.7/24)")"

# 2. Twenty creations at once of ranges that all overlap each other (all start at 172.16.0.0): exactly one survives.
for i in $(seq 1 20); do
  cidr=$([[ $((i % 2)) -eq 0 ]] && echo "172.16.0.0/16" || echo "172.16.0.0/$((16 + i % 8))")
  ( curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: $user" \
      -d "$(subnet_json "Race $i" "$cidr")" "$ipm/initiate" > "$tmp/code$i" ) &
done
wait
check_equal 'twenty overlapping subnets created at once: one 201, nineteen 409, no other answer' '1/19/0' "$(codes 20)"
check_equal 'and exactly one subnet holds the 172.16 range' 1 "$(stb GET "$ipm/retrieve" | python3 -c "import json,sys; print(sum(1 for s in json.load(sys.stdin) if s['cidr'].startswith('172.16.')))")"

# 3. An address is held once.
first=$(api POST "$ipm/allocation/initiate" "$(alloc_json "$office")" "${staff[@]}")
check_equal 'without an address the lowest free one is handed out: 201, 10.20.0.1' '201/10.20.0.1' "$(api_status "$first")/$(api_body "$first" | json "['ip']")"
for i in $(seq 1 20); do
  ( curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: $user" \
      -d "$(alloc_json "$office" 10.20.0.50)" "$ipm/allocation/initiate" > "$tmp/code$i" ) &
done
wait
check_equal 'twenty requests for 10.20.0.50 at once: one 201, nineteen 409, no other answer' '1/19/0' "$(codes 20)"
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: $user" \
      -d "$(alloc_json "$office")" "$ipm/allocation/initiate" > "$tmp/code$i" ) &
done
wait
check_equal 'twenty requests for the next free address at once: twenty 201' '20/0/0' "$(codes 20)"
check_equal 'and twenty different addresses, none of them .1 or .50' '20/False' \
  "$(for i in $(seq 1 20); do json "['ip']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')/$(for i in $(seq 1 20); do json "['ip']" < "$tmp/body$i"; done | grep -cxE '10\.20\.0\.(1|50)' | sed 's/^0$/False/;s/^[1-9].*/True/')"
check_equal 'the subnet counts 22 used, 232 free, OK' 'OK/22/232' "$(judged "$office")"

# 4. Released, an address is handed out again.
held=$(stb GET "$ipm/allocation/retrieve?subnetId=$office" | python3 -c "import json,sys; print(next(a['id'] for a in json.load(sys.stdin) if a['ip']=='10.20.0.50'))")
check_equal '10.20.0.50 is released (204), and a second release is a 409' '204/409' "$(st PUT "$ipm/allocation/$held/control/release")/$(st PUT "$ipm/allocation/$held/control/release")"
check_equal '10.20.0.50 can be handed out again (201)' 201 "$(st POST "$ipm/allocation/initiate" "$(alloc_json "$office" 10.20.0.50)")"
check_equal 'its trail reads ALLOCATED, RELEASED' 'ALLOCATED,RELEASED' "$(stb GET "$ipm/allocation/$held/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 5. A tiny subnet fills up; retired, it takes nothing and cannot come back over a range taken meanwhile.
tiny=$(stb POST "$ipm/initiate" "$(subnet_json 'Lab' 192.168.50.0/29 50)" | json "['id']")
for i in $(seq 1 6); do api POST "$ipm/allocation/initiate" "$(alloc_json "$tiny")" "${staff[@]}" > /dev/null; done
check_equal 'six addresses fill a /29: FULL, nothing free' 'FULL/6/0' "$(judged "$tiny")"
check_equal 'a full subnet has no next free address (409)' 409 "$(st POST "$ipm/allocation/initiate" "$(alloc_json "$tiny")")"
check_equal 'the network and the broadcast address are never handed out (400)' '400/400' \
  "$(st POST "$ipm/allocation/initiate" "$(alloc_json "$office" 10.20.0.0)")/$(st POST "$ipm/allocation/initiate" "$(alloc_json "$office" 10.20.0.255)")"
check_equal 'the /29 is retired (204) and takes no address (409)' '204/409' "$(st PUT "$ipm/$tiny/control/retire")/$(st POST "$ipm/allocation/initiate" "$(alloc_json "$tiny" 192.168.50.6)")"
check_equal 'a new subnet over the retired range is fine (201)' 201 "$(st POST "$ipm/initiate" "$(subnet_json 'Lab 2' 192.168.50.0/28)")"
check_equal 'reactivating the old /29 is refused now (409) and it stays RETIRED' '409/RETIRED' "$(st PUT "$ipm/$tiny/control/reactivate")/$(stb GET "$ipm/$tiny/retrieve" | json "['status']")"
check_equal 'its trail shows the reactivation undone' 'INITIATED,RETIRED,REACTIVATED,REACTIVATION_UNDONE' \
  "$(stb GET "$ipm/$tiny/audit-log/retrieve" | python3 -c "import json,sys; print(','.join(e['action'] for e in json.load(sys.stdin)))")"

# 6. Nothing that is not an address or a DNS name is kept, nor repeated.
bad=$(api POST "$ipm/allocation/initiate" "{\"subnetId\":\"$office\",\"hostname\":\"John secret-value Smith\"}" "${staff[@]}")
check_equal 'a hostname that is not a DNS name is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('secret-value' in sys.stdin.read())")"
check_equal 'an address that is not a dotted quad is refused (400)' 400 "$(st POST "$ipm/allocation/initiate" "$(alloc_json "$office" 10.20.0)")"
check_equal 'an address with a leading zero is refused (400)' 400 "$(st POST "$ipm/allocation/initiate" "$(alloc_json "$office" 10.20.0.010)")"

# 7. Staff only, the tenant.
check_equal 'a REQUESTER cannot register a subnet (403 ERR-IPM-00403)' '403/ERR-IPM-00403' \
  "$(api_status "$(rq POST "$ipm/initiate" "$(subnet_json 'r' 10.99.0.0/24)")")/$(api_body "$(rq POST "$ipm/initiate" "$(subnet_json 'r' 10.99.0.0/24)")" | json "['error_code']")"
check_equal 'a REQUESTER cannot allocate or list allocations (403)' '403/403' "$(api_status "$(rq POST "$ipm/allocation/initiate" "$(alloc_json "$office")")")/$(api_status "$(rq GET "$ipm/allocation/retrieve")")"
check_equal 'another tenant gets a 404 for the subnet and finds no allocations' '404/0' \
  "$(api_status "$(api GET "$ipm/$office/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$ipm/allocation/retrieve" "" "${other_tenant[@]}")" | count)"
delete_status=$(st DELETE "$ipm/$office")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 8. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-ipam'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-ipam'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; print('secret' in sys.stdin.read())" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "IPAM smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
