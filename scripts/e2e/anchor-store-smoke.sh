#!/usr/bin/env bash
# Live proof of the write-once anchor store (ledger ADR-035): the chain head is published to an S3-compatible bucket with Object Lock,
# the published anchor cannot be removed (a locked version refuses deletion), and a plain delete - which on a versioned bucket only
# hides the object from a normal listing - does not hide it from the ledger.
# Needs the compose stack (docker compose up: the ledger publishes to the anchor-store LocalStack) and the AWS CLI (preinstalled on GitHub
# runners). Only the compose stack has the object store; the local no-Docker stack publishes to files.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
org_api="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
ledger_api="${LEDGER_URL:-http://localhost:8094}/compliance-audit-ledger/v1"
store="${ANCHOR_STORE_URL:-http://localhost:9100}"
bucket="${ANCHOR_BUCKET:-thinklab-anchors}"
export AWS_ACCESS_KEY_ID="${ANCHOR_STORE_USER:-test}"
export AWS_SECRET_ACCESS_KEY="${ANCHOR_STORE_PASSWORD:-test}"
export AWS_DEFAULT_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true
checks=0
failed=0

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
s3api() { aws --endpoint-url "$store" s3api "$@"; }

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
org=$(api POST "$org_api/initiate" "{\"corporateName\":\"Anchor Corp\",\"tradeName\":\"ANC\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@anc.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" 'X-Executor: anchor-store-smoke')
org_id=$(api_body "$org" | json "['id']")
tenant="X-Tenant-Id: $org_id"
check_equal 'organisation created' 201 "$(api_status "$org")"

# Something on the chain to anchor: one asset created through the gateway (recorded by the gateway on the ledger).
serial="ANC-$stamp"
check_equal 'an asset is created through the gateway (so the ledger has an entry)' 201 "$(api_status "$(api POST "$gateway/it-asset-registry/v1/initiate" "{\"name\":\"Anchored switch\",\"category\":\"NETWORK_DEVICE\",\"serialNumber\":\"$serial\",\"specifications\":{\"model\":\"SW-1\"}}" "$tenant" 'X-Executor: anchor-store-smoke')")"
for _ in $(seq 1 20); do
  entries=$(api_body "$(api GET "$ledger_api/retrieve?limit=10" "" "$tenant")" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  [[ "$entries" -ge 1 ]] && break
  sleep 0.5
done

# 1. The head is published to the object store.
anchor=$(api POST "$ledger_api/anchor/initiate" "" "$tenant" 'X-Executor: anchor-store-smoke')
check_equal 'anchor/initiate publishes the chain head (201)' 201 "$(api_status "$anchor")"
check_equal 'anchor outcome is PUBLISHED' PUBLISHED "$(api_body "$anchor" | json "['status']")"
versions=$(s3api list-object-versions --bucket "$bucket" --prefix "anchors/$org_id/" --output json)
check_equal 'the anchor is one object in the bucket' 1 "$(json "['Versions'].__len__()" <<<"$versions")"
key=$(json "['Versions'][0]['Key']" <<<"$versions")
version_id=$(json "['Versions'][0]['VersionId']" <<<"$versions")
check_equal 'the object is under the organisation folder' "anchors/$org_id/" "${key%/*}/"

# 2. It is locked: COMPLIANCE mode, so nobody can shorten or remove it.
retention=$(s3api get-object-retention --bucket "$bucket" --key "$key" --version-id "$version_id" --output json)
check_equal 'the object is locked in COMPLIANCE mode' COMPLIANCE "$(json "['Retention']['Mode']" <<<"$retention")"

# 3. A locked version cannot be deleted.
if s3api delete-object --bucket "$bucket" --key "$key" --version-id "$version_id" >/dev/null 2>&1; then deleted=yes; else deleted=no; fi
check_equal 'deleting the locked version is refused' no "$deleted"
check_equal 'the anchor is still there' 1 "$(s3api list-object-versions --bucket "$bucket" --prefix "anchors/$org_id/" --output json | json "['Versions'].__len__()")"

# 4. A plain delete only hides the object from an ordinary listing; the ledger is not fooled.
s3api delete-object --bucket "$bucket" --key "$key" >/dev/null 2>&1
listed=$(s3api list-objects-v2 --bucket "$bucket" --prefix "anchors/$org_id/" --output json | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Contents") or []))')
check_equal 'an ordinary listing no longer shows the anchor (the hazard)' 0 "$listed"
check_equal 'the ledger still lists the anchor' 1 "$(api_body "$(api GET "$ledger_api/anchor/retrieve" "" "$tenant")" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
integrity=$(api_body "$(api GET "$ledger_api/integrity-check/evaluate" "" "$tenant")")
check_equal 'the chain is valid against the anchor' True "$(json "['valid']" <<<"$integrity")"
check_equal 'one anchor was verified' 1 "$(json "['anchorsVerified']" <<<"$integrity")"

echo "Anchor store smoke: $checks checks, $failed failed"
[[ $failed -eq 0 ]]
