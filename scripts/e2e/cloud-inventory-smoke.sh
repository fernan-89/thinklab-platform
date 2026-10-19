#!/usr/bin/env bash
# Live proof of Journey 15, fifth service (cloud inventory ADR-030..034): AWS and Azure resources through the platform gateway.
# The provider's id is the identity (the same one reported again is the same resource, restated; twenty tools reporting a new one at once leave one),
# a snapshot that is replaced by what the tool says now, fixed lists and four tags (nothing a tool says is repeated), judged PRESENT or GONE when read,
# a terminated resource that comes back, the filters and the summary, staff only, the tenant, and every mutation on the ledger.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
inv="$gateway/it-cloud-inventory/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
checks=0
failed=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

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

tenant_id=$(uuid); user=$(uuid); requester=$(uuid); account=$(uuid); other_account=$(uuid)
tenant="X-Tenant-Id: $tenant_id"
staff=("$tenant" "X-Executor: $user")
tool=("$tenant" 'X-Executor: steampipe-sync')
other_tenant=("X-Tenant-Id: $(uuid)" "X-Executor: $user")
arn='arn:aws:ec2:us-east-1:123456789012:instance/i-0abc'
azure_id='/subscriptions/0000-1111/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1'

stb() { api_body "$(api "$1" "$2" "${3:-}" "${staff[@]}")"; }
rq() { api "$1" "$2" "${3:-}" "$tenant" "X-Executor: $requester" 'X-Role: REQUESTER'; }
report() { api POST "$inv/initiate" "$1" "${tool[@]}"; }
# res_json ACCOUNT PROVIDER EXTERNAL_ID NAME KIND REGION STATE TAGS_JSON
res_json() { printf '{"accountId":"%s","provider":"%s","externalId":"%s","name":"%s","kind":"%s","region":"%s","state":"%s","tags":%s}' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"; }

# 1. A resource is reported, restated and replaced; the provider's id is its identity.
first=$(report "$(res_json "$account" AWS "$arn" web-1 COMPUTE us-east-1 RUNNING '{"environment":"prod","owner":"team-a"}')")
check_equal 'a new AWS instance is 201, judged PRESENT, with what the tool said' '201/PRESENT/RUNNING/COMPUTE' \
  "$(api_status "$first")/$(api_body "$first" | json "['presence']")/$(api_body "$first" | json "['state']")/$(api_body "$first" | json "['kind']")"
resource=$(api_body "$first" | json "['id']")
again=$(report "$(res_json "$account" AWS "$arn" web-1 COMPUTE us-east-1 RUNNING '{"environment":"prod","owner":"team-a"}')")
check_equal 'the same resource again is 200 and the same resource' "200/$resource" "$(api_status "$again")/$(api_body "$again" | json "['id']")"
replaced=$(report "$(res_json "$account" AWS "$arn" web-1b COMPUTE us-east-1 STOPPED '{"environment":"dev"}')")
check_equal 'a changed report replaces the snapshot (200, same id, new state, name and tags)' "200/$resource/STOPPED/web-1b/{'environment': 'dev'}" \
  "$(api_status "$replaced")/$(api_body "$replaced" | json "['id']")/$(api_body "$replaced" | json "['state']")/$(api_body "$replaced" | json "['name']")/$(api_body "$replaced" | json "['tags']")"
azure=$(report "$(res_json "$account" AZURE "$azure_id" vm1 COMPUTE brazilsouth RUNNING '{}')")
check_equal 'an Azure resource id, with slashes and no tags, is 201' '201/AZURE/{}' "$(api_status "$azure")/$(api_body "$azure" | json "['provider']")/$(api_body "$azure" | json "['tags']")"
other=$(report "$(res_json "$other_account" AWS "$arn" web-1 COMPUTE us-east-1 RUNNING '{}')")
check_equal 'the same ARN under another account is another resource (201)' "201/True" "$(api_status "$other")/$(python3 -c "import json,sys; print(json.load(sys.stdin)['id'] != sys.argv[1])" "$resource" <<<"$(api_body "$other")")"
db=$(report "$(res_json "$account" AWS 'arn:aws:rds:us-east-1:123456789012:db:orders' orders DATABASE us-east-1 RUNNING '{}')")
db_id=$(api_body "$db" | json "['id']")

# 2. The same new resource reported by twenty tools at once is one resource.
race='arn:aws:s3:::race-bucket'
for i in $(seq 1 20); do
  ( curl -sS -o "$tmp/body$i" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H "$tenant" -H "X-Executor: sync-$i" \
      -d "$(res_json "$account" AWS "$race" race-bucket STORAGE us-east-1 RUNNING '{}')" "$inv/initiate" > "$tmp/code$i" ) &
done
wait
created_count=0; ok_count=0; other_count=0
for i in $(seq 1 20); do
  case "$(cat "$tmp/code$i")" in 201) created_count=$((created_count + 1));; 200) ok_count=$((ok_count + 1));; *) other_count=$((other_count + 1));; esac
done
check_equal 'the same new resource reported by twenty tools at once: one 201, nineteen 200, no other answer' '1/19/0' "$created_count/$ok_count/$other_count"
check_equal 'every answer is the same resource' 1 "$(for i in $(seq 1 20); do json "['id']" < "$tmp/body$i"; done | sort -u | wc -l | tr -d ' ')"
check_equal 'the inventory holds exactly four resources of the account (and the other account has one)' '4/1' \
  "$(stb GET "$inv/retrieve?accountId=$account" | count)/$(stb GET "$inv/retrieve?accountId=$other_account" | count)"

# 3. Reading, filters and the summary.
check_equal 'one resource is read, judged now' 'STOPPED/PRESENT' "$(stb GET "$inv/$resource/retrieve" | json "['state']")/$(stb GET "$inv/$resource/retrieve" | json "['presence']")"
check_equal 'the list finds the Azure resource by provider' "$(api_body "$azure" | json "['id']")" "$(stb GET "$inv/retrieve?provider=AZURE" | json "[0]['id']")"
check_equal 'the list finds the database by kind and by region, and nothing in another region' "$db_id/0" "$(stb GET "$inv/retrieve?kind=DATABASE&region=us-east-1" | json "[0]['id']")/$(stb GET "$inv/retrieve?kind=DATABASE&region=eu-west-1" | count)"
check_equal 'the list finds the stopped one by state' "$resource" "$(stb GET "$inv/retrieve?state=STOPPED" | json "[0]['id']")"
check_equal 'a limit is kept' 2 "$(stb GET "$inv/retrieve?limit=2" | count)"
summary=$(stb GET "$inv/summary/retrieve")
check_equal 'the summary counts five resources by provider and by presence' "5/{'AWS': 4, 'AZURE': 1}/{'PRESENT': 5}" \
  "$(json "['total']" <<<"$summary")/$(json "['byProvider']" <<<"$summary")/$(json "['byPresence']" <<<"$summary")"
check_equal 'the summary of one provider counts only it' 1 "$(stb GET "$inv/summary/retrieve?provider=AZURE" | json "['total']")"

# 4. A terminated resource is GONE, and comes back when reported running.
gone=$(report "$(res_json "$account" AWS 'arn:aws:rds:us-east-1:123456789012:db:orders' orders DATABASE us-east-1 TERMINATED '{}')")
check_equal 'a terminated resource is judged GONE (same resource)' "200/$db_id/GONE" "$(api_status "$gone")/$(api_body "$gone" | json "['id']")/$(api_body "$gone" | json "['presence']")"
check_equal 'the list finds what is gone' "$db_id" "$(stb GET "$inv/retrieve?presence=GONE" | json "[0]['id']")"
back=$(report "$(res_json "$account" AWS 'arn:aws:rds:us-east-1:123456789012:db:orders' orders DATABASE us-east-1 RUNNING '{}')")
check_equal 'reported running again, it is PRESENT' PRESENT "$(api_body "$back" | json "['presence']")"

# 5. Nothing the registry does not know is accepted, and nothing of it is repeated.
bad=$(report "$(res_json "$account" GCP "$arn" n COMPUTE us-east-1 RUNNING '{}')")
check_equal 'an unknown provider is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$bad")/$(api_body "$bad" | python3 -c "import sys; print('GCP' in sys.stdin.read())")"
secret=$(report "$(res_json "$account" AWS 'i-secret' n COMPUTE us-east-1 RUNNING '{"password":"hunter2-secret"}')")
check_equal 'a tag key that is not kept is refused (400) and the answer does not repeat it' '400/False' "$(api_status "$secret")/$(api_body "$secret" | python3 -c "import sys; print('hunter2' in sys.stdin.read())")"
person=$(report "$(res_json "$account" AWS 'i-person' n COMPUTE us-east-1 RUNNING '{"owner":"Ana <ana-secret@example.com>"}')")
check_equal 'a tag value with a person and an address is refused (400) and not repeated' '400/False' "$(api_status "$person")/$(api_body "$person" | python3 -c "import sys; print('ana-secret' in sys.stdin.read())")"
check_equal 'a name with a space is refused (400)' 400 "$(api_status "$(report "$(res_json "$account" AWS 'i-x' 'web 1' COMPUTE us-east-1 RUNNING '{}')")")"
check_equal 'a region in capitals is refused (400)' 400 "$(api_status "$(report "$(res_json "$account" AWS 'i-y' n COMPUTE US-EAST RUNNING '{}')")")"
check_equal 'an unknown kind is refused (400)' 400 "$(api_status "$(report "$(res_json "$account" AWS 'i-z' n TOASTER us-east-1 RUNNING '{}')")")"

# 6. Staff only, the tenant.
check_equal 'a REQUESTER cannot report a resource (403 ERR-INV-00403)' '403/ERR-INV-00403' \
  "$(api_status "$(rq POST "$inv/initiate" "$(res_json "$account" AWS r1 n COMPUTE us-east-1 RUNNING '{}')")")/$(api_body "$(rq POST "$inv/initiate" "$(res_json "$account" AWS r1 n COMPUTE us-east-1 RUNNING '{}')")" | json "['error_code']")"
check_equal 'a REQUESTER cannot read, list or count (403)' '403/403/403' "$(api_status "$(rq GET "$inv/$resource/retrieve")")/$(api_status "$(rq GET "$inv/retrieve")")/$(api_status "$(rq GET "$inv/summary/retrieve")")"
check_equal 'another tenant gets a 404 for the resource, finds none and counts none' '404/0/0' \
  "$(api_status "$(api GET "$inv/$resource/retrieve" "" "${other_tenant[@]}")")/$(api_body "$(api GET "$inv/retrieve" "" "${other_tenant[@]}")" | count)/$(api_body "$(api GET "$inv/summary/retrieve" "" "${other_tenant[@]}")" | json "['total']")"
delete_status=$(api_status "$(api DELETE "$inv/$resource" "" "${staff[@]}")")
check_equal 'there is no delete (404 or 405)' True "$([[ "$delete_status" == 404 || "$delete_status" == 405 ]] && echo True || echo False)"

# 7. The ledger.
recorded=0
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=500" "" "$tenant")")
  recorded=$(python3 -c "import json,sys; print(sum(1 for e in json.load(sys.stdin) if e['resourceType']=='it-cloud-inventory'))" <<<"$entries")
  [[ "$recorded" -ge 30 ]] && break
  sleep 0.5
done
check_equal 'the gateway recorded the mutations on the ledger (many, refused ones included)' True "$([[ "$recorded" -ge 30 ]] && echo True || echo False)"
check_equal 'a refused one is there with its status' True "$(python3 -c "import json,sys; print(any(e['detail']=='status=403' for e in json.load(sys.stdin) if e['resourceType']=='it-cloud-inventory'))" <<<"$entries")"
check_equal 'nothing anyone said is on the ledger' False "$(python3 -c "import sys; t=sys.stdin.read(); print('hunter2' in t or 'ana-secret' in t)" <<<"$entries")"
check_equal 'the chain verifies' True "$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")" | json "['valid']")"

echo "Cloud inventory smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
