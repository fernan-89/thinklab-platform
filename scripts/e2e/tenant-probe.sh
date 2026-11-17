#!/usr/bin/env bash
# Cross-tenant probe (ACTION-PLAN 0.8-c, docs/TENANT-AUDIT-2026-11.md): does a service hand an object of tenant X to tenant Y when Y asks for it by id?
#
# For each service of the audit's group A it creates one object as tenant X, then reads it back as tenant Y by id (retrieve, and audit-log when the service has
# one). The right answer is a 404 (another tenant's object is the same as none). A 200 is a LEAK. Read-only on Y's side; it writes one object per service as X.
#
# A ratchet, not a one-off: LEAKY lists the services known to leak today. The probe FAILS when a service outside that list leaks (a regression). A listed service that
# stops leaking is reported as FIXED and does not fail the job (the service lives in another repository and merges first): remove its name from LEAKY in the next
# platform PR, so it can never come back.
#
# Needs the stack up (the services are called on their own ports; security off, the tenant is the X-Tenant-Id header). Bash only (ACTION-PLAN 1.4).
set -uo pipefail

LEAKY=(asset-registry change-management discovery hardware-maintenance operation-window site-directory ci-type-catalog topology-graph notification-dispatch)

host="${PROBE_HOST:-http://localhost}"
org_api="$host:8081/party-reference-data-directory/v1"
asset_api="$host:8083/it-asset-registry/v1"
window_api="$host:8084/it-operation-window/v1"
work_api="$host:8085/it-hardware-maintenance/v1"
change_api="$host:8086/it-change-management/v1"
site_api="$host:8087/site-reference-data-directory/v1"
notify_api="$host:8089/notification-dispatch/v1"
discovery_api="$host:8091/it-discovery/v1"
topology_api="$host:8092/it-topology-graph/v1"
catalog_api="$host:8093/ci-type-catalog/v1"

PY=python3; "$PY" -c 'print(1)' >/dev/null 2>&1 || PY=python
clean() { tr -d '\r'; }
json() { "$PY" -c "import json,sys; print(json.load(sys.stdin)$1)" | clean; }
uuid() { "$PY" -c 'import uuid; print(uuid.uuid4())' | clean; }
iso_in() { "$PY" -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1" | clean; }

executor="X-Executor: tenant-probe"
tenant_x=""; tenant_y=""

# post URL BODY TENANT -> prints the id of what was created, empty on a non-2xx
post() {
  local out code
  out=$(curl -sS -X POST -H 'Content-Type: application/json' -H "$executor" -H "X-Tenant-Id: $3" -d "$2" -w '\n%{http_code}' "$1")
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [[ "$code" == 2* ]]; then printf '%s' "$out" | json "['id']"; else echo "  (create failed: $1 -> $code ${out:0:160})" >&2; fi
}
status_of() { curl -sS -o /dev/null -w '%{http_code}' -H "$executor" -H "X-Tenant-Id: $2" "$1"; }

make_org() {
  local tax; tax=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
  post "$org_api/initiate" "{\"corporateName\":\"Probe $1\",\"tradeName\":\"Probe $1\",\"taxIdentifier\":\"$tax\",\"billing\":{\"billingEmail\":\"p@probe.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" "$(uuid)"
}

tenant_x=$(make_org X); tenant_y=$(make_org Y)
if [[ -z "$tenant_x" || -z "$tenant_y" ]]; then echo "could not create the two organisations: is the stack up?" >&2; exit 2; fi
echo "tenant X: $tenant_x"; echo "tenant Y: $tenant_y"

asset=$(post "$asset_api/initiate" "{\"name\":\"Probe laptop\",\"category\":\"LAPTOP\",\"serialNumber\":\"SN-PROBE-$(uuid | cut -c1-8)\",\"specifications\":{\"cpu\":\"i7\"}}" "$tenant_x")

declare -A created base paths
add() { created[$1]=$2; base[$1]=$3; paths[$1]=$4; }

add asset-registry "$asset" "$asset_api" "retrieve audit-log/retrieve"
add change-management "$(post "$change_api/initiate" "{\"requesterId\":\"$(uuid)\",\"title\":\"Probe change\",\"description\":\"probe\",\"changeType\":\"NORMAL\",\"targetAssetIds\":[\"$asset\"]}" "$tenant_x")" "$change_api" "retrieve audit-log/retrieve"
add discovery "$(post "$discovery_api/initiate" "{\"source\":\"manual\",\"externalKey\":\"probe-$(uuid | cut -c1-8)\",\"name\":\"Probe item\",\"rawAttributes\":{\"mac\":\"aa\"}}" "$tenant_x")" "$discovery_api" "retrieve audit-log/retrieve"
add hardware-maintenance "$(post "$work_api/initiate" "{\"assetId\":\"$asset\",\"requesterId\":\"$(uuid)\",\"title\":\"Probe order\",\"symptom\":\"probe\",\"type\":\"CORRECTIVE\",\"location\":\"Room 1\"}" "$tenant_x")" "$work_api" "retrieve audit-log/retrieve"
add operation-window "$(post "$window_api/initiate" "{\"title\":\"Probe window\",\"description\":\"probe\",\"windowType\":\"PATCHING\",\"targetAssetIds\":[\"$asset\"],\"startAt\":\"$(iso_in 40)\",\"endAt\":\"$(iso_in 41)\"}" "$tenant_x")" "$window_api" "retrieve audit-log/retrieve"
add site-directory "$(post "$site_api/initiate" "{\"organisationId\":\"$tenant_x\",\"siteName\":\"Probe site $(uuid | cut -c1-6)\",\"address\":\"1 Main St\",\"city\":\"Lisbon\",\"country\":\"PT\",\"zipCode\":\"1000-001\",\"timezone\":\"Europe/Lisbon\",\"latitude\":38.72,\"longitude\":-9.14}" "$tenant_x")" "$site_api" "retrieve audit-log/retrieve"
add ci-type-catalog "$(post "$catalog_api/initiate" "{\"category\":\"SERVER\",\"jsonSchema\":\"{\\\"type\\\":\\\"object\\\"}\"}" "$tenant_x")" "$catalog_api" "retrieve audit-log/retrieve"
add topology-graph "$(post "$topology_api/initiate" "{\"nodeType\":\"ASSET\",\"externalId\":\"$(uuid)\",\"label\":\"probe\",\"attributes\":{\"tier\":\"web\"}}" "$tenant_x")" "$topology_api" "retrieve"
add notification-dispatch "$(post "$notify_api/initiate" "{\"recipient\":\"probe@thinklab.com\",\"subject\":\"Probe\",\"body\":\"probe\",\"channel\":\"LOG\"}" "$tenant_x")" "$notify_api" "retrieve"

is_leaky() { local s; for s in "${LEAKY[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

failed=0
printf '%-22s %-8s %s\n' service verdict "answers of tenant Y to what tenant X made"
for svc in asset-registry change-management discovery hardware-maintenance operation-window site-directory ci-type-catalog topology-graph notification-dispatch; do
  id=${created[$svc]}
  if [[ -z "$id" ]]; then printf '%-22s %-8s %s\n' "$svc" NOCREATE "could not create the object as tenant X (see the line above)"; failed=$((failed + 1)); continue; fi
  own=$(status_of "${base[$svc]}/$id/retrieve" "$tenant_x")
  answers=""; leaked=0
  for path in ${paths[$svc]}; do
    code=$(status_of "${base[$svc]}/$id/$path" "$tenant_y")
    answers="$answers $path=$code"
    [[ "$code" == 200 ]] && leaked=1
  done
  if [[ "$own" != 200 ]]; then verdict=BADSETUP; failed=$((failed + 1))
  elif [[ $leaked == 1 ]]; then
    if is_leaky "$svc"; then verdict=leak-known; else verdict=LEAK-NEW; failed=$((failed + 1)); fi
  else
    if is_leaky "$svc"; then verdict=FIXED; else verdict=ok; fi
  fi
  printf '%-22s %-8s own=%s%s\n' "$svc" "$verdict" "$own" "$answers"
done

echo
echo "leak-known: a leak the audit already lists (fix it, then remove the service from LEAKY)."
echo "FIXED:      listed in LEAKY but no longer leaks (not a failure): remove it from LEAKY so it cannot come back."
echo "LEAK-NEW:   a service outside the list leaks: a regression."
[[ $failed -eq 0 ]]
