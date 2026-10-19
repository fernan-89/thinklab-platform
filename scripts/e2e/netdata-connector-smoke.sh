#!/usr/bin/env bash
# Live proof of the Netdata connector (scripts/connectors/netdata-sync.sh) through the platform gateway, against a test double of a Netdata agent
# (mock-netdata.mjs, started here): the node reaches the discovery queue once however often it is seen, each configured chart becomes a capacity
# sample for its policy (dimensions added up, a factor applied), a run in the same minute reports the same samples, a chart or a dimension the agent
# does not have fails that entry only, an agent that cannot be reached fails every entry, the token is sent when given and is never printed, and a
# wrong call exits 2. The agent's own alerts are not mirrored (the samples feed the capacity policies).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
connector="$here/../connectors/netdata-sync.sh"
gateway="${GATEWAY_URL:-http://localhost:8088}"
cap="$gateway/it-capacity-registry/v1"
dsc="$gateway/it-discovery/v1"
port="${NETDATA_MOCK_PORT:-19998}"
token='tok-smoke-9f3a71'
checks=0
failed=0
tmp=$(mktemp -d)
mock_pid=""
mock_container=""
cleanup() {
  [[ -n "$mock_pid" ]] && kill "$mock_pid" 2>/dev/null
  [[ -n "$mock_container" ]] && docker rm -f "$mock_container" >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
count() { python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }

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

# The double needs Node: on a machine without it (a developer's), the same file runs in a container.
if command -v node >/dev/null 2>&1; then
  MOCK_NETDATA_PORT=$port MOCK_NETDATA_TOKEN=$token node "$here/mock-netdata.mjs" >/dev/null 2>&1 &
  mock_pid=$!
else
  mock_container="mock-netdata-smoke-$$"
  docker run -d --rm --name "$mock_container" --network host -e MOCK_NETDATA_PORT=$port -e MOCK_NETDATA_TOKEN=$token -v "$here":/m:ro node:22 node /m/mock-netdata.mjs >/dev/null
fi
for _ in $(seq 1 30); do curl -s -o /dev/null -H "Authorization: Bearer $token" "http://localhost:$port/api/v1/info" && break; sleep 0.5; done

tenant_id=$(uuid); asset=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" 'X-Executor: smoke')
policy() { printf '{"name":"%s","assetId":"%s","metric":"%s","limit":%s,"warnPercent":70,"criticalPercent":90,"windowDays":7,"horizonDays":30,"reportEveryHours":1}' "$1" "$asset" "$2" "$3"; }
ram=$(api_body "$(api POST "$cap/initiate" "$(policy 'RAM used' MEMORY 10000)" "${staff[@]}")" | json "['id']")
disk=$(api_body "$(api POST "$cap/initiate" "$(policy 'Root disk' DISK 100)" "${staff[@]}")" | json "['id']")

cat > "$tmp/good.json" <<JSON
{"netdata":"http://localhost:$port","nodes":true,"samples":[
 {"policyId":"$ram","chart":"system.ram","dimensions":["used","buffers"]},
 {"policyId":"$disk","chart":"disk_space./","dimensions":["used"],"factor":2.0}]}
JSON
python3 - "$tmp/good.json" "$port" "$ram" "$disk" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); port,ram,disk=sys.argv[2:5]
bad=json.loads(json.dumps(c)); bad["samples"][0]["dimensions"]=["nope"]; json.dump(bad,open(sys.argv[1]+".dimension","w"))
missing=json.loads(json.dumps(c)); missing["samples"][1]["chart"]="no.such.chart"; json.dump(missing,open(sys.argv[1]+".chart","w"))
down=json.loads(json.dumps(c)); down["netdata"]="http://localhost:1"; json.dump(down,open(sys.argv[1]+".down","w"))
PY

sync() { NETDATA_TOKEN="$token" "$connector" "$@" 2>&1; }

# 1. A good run: the node and both charts.
out=$(sync "$tmp/good.json" "$tenant_id"); status=$?
check_equal 'a run reports the node and both samples, none failed (exit 0)' '0/netdata-sync: 3 reported, 0 failed' "$status/$(tail -1 <<<"$out")"
nodes=$(api_body "$(api GET "$dsc/retrieve?source=netdata" "" "${staff[@]}")")
check_equal 'the node is in the discovery queue, once' 1 "$(count <<<"$nodes")"
check_equal 'it waits for a person (DISCOVERED), named for the host' 'DISCOVERED/smoke-node' "$(json "[0]['status']" <<<"$nodes")/$(json "[0]['name']" <<<"$nodes")"
check_equal 'it carries what Netdata knows of the machine, as text' 'v2.12.1/12' "$(json "[0]['rawAttributes']['version']" <<<"$nodes")/$(json "[0]['rawAttributes']['cores_total']" <<<"$nodes")"
last() { api_body "$(api GET "$cap/$1/retrieve" "" "${staff[@]}")" | python3 -c "import json,sys; print('%.2f' % json.load(sys.stdin)['lastValue'])"; }
check_equal 'the memory sample is the dimensions added up (used 2000 + buffers 50)' 2050.00 "$(last "$ram")"
check_equal 'the disk sample is times its factor (20 x 2)' 40.00 "$(last "$disk")"

# 2. A second run: the same node is a re-sighting, never a second item, and the samples do not break.
out=$(sync "$tmp/good.json" "$tenant_id"); status=$?
check_equal 'running again succeeds' '0/netdata-sync: 3 reported, 0 failed' "$status/$(tail -1 <<<"$out")"
check_equal 'the node is still one item' 1 "$(api_body "$(api GET "$dsc/retrieve?source=netdata" "" "${staff[@]}")" | count)"
check_equal 'the samples are the same' '2050.00/40.00' "$(last "$ram")/$(last "$disk")"

# 3. Failures: only the entry that cannot be read fails.
out=$(sync "$tmp/good.json.dimension" "$tenant_id"); status=$?
check_equal 'a dimension the chart does not have fails that entry only (exit 1)' '1/netdata-sync: 2 reported, 1 failed' "$status/$(tail -1 <<<"$out")"
check_equal 'it says which chart' True "$(grep -q 'FAILED  system.ram' <<<"$out" && echo True || echo False)"
out=$(sync "$tmp/good.json.chart" "$tenant_id"); status=$?
check_equal 'a chart the agent does not have fails that entry only (exit 1)' '1/netdata-sync: 2 reported, 1 failed' "$status/$(tail -1 <<<"$out")"
out=$(sync "$tmp/good.json.down" "$tenant_id"); status=$?
check_equal 'an agent that cannot be reached fails every entry (exit 1)' '1/netdata-sync: 0 reported, 3 failed' "$status/$(tail -1 <<<"$out")"

# 4. The token: sent when given, never printed.
out=$("$connector" "$tmp/good.json" "$tenant_id" 2>&1); status=$?
check_equal 'without the token the agent refuses and nothing is reported (exit 1)' 1 "$status"
out=$(sync "$tmp/good.json" "$tenant_id"); 
check_equal 'the token is never printed' False "$(grep -q "$token" <<<"$out" && echo True || echo False)"

# 5. A wrong call.
"$connector" >/dev/null 2>&1; check_equal 'no arguments exit 2' 2 "$?"
"$connector" "$tmp/does-not-exist.json" "$tenant_id" >/dev/null 2>&1; check_equal 'a config that is not there exits 2' 2 "$?"

# 6. The tenant: another tenant sees none of it.
other=("X-Tenant-Id: $(uuid)" 'X-Executor: smoke')
check_equal 'another tenant finds no node' 0 "$(api_body "$(api GET "$dsc/retrieve?source=netdata" "" "${other[@]}")" | count)"

echo "Netdata connector smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
