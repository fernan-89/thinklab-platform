#!/usr/bin/env bash
# Netdata connector: reads one Netdata agent and reports to ThinkLab through the gateway. It runs outside the services, as the tool that measures
# (capacity-registry ADR-030): no ThinkLab service reaches an asset or holds a credential.
#
#   scripts/connectors/netdata-sync.sh <config.json> <organisationId>
#
# 1. The node goes to the discovery queue (source "netdata", keyed by the agent's id): a human still reviews and promotes it. Idempotent: a second run
#    is a re-sighting (200), not a second item.
# 2. Every entry of "samples" becomes one capacity sample for its policy: the chart's average over the last few seconds, the named dimensions added up,
#    times "factor" (the policy's limit and the sample must use the same unit, and Netdata's is in the chart: system.ram is MiB, disk_space GiB).
#    The moment is rounded to the minute, so running twice in one minute reports one sample.
# Alerts are not mirrored: the samples feed the capacity policies, which the alerting service already watches.
#
# Config: {"netdata":"http://localhost:19999","nodes":true,"samples":[{"policyId":"<uuid>","chart":"system.ram","dimensions":["used"],"factor":1.0}]}
# Environment: GATEWAY_URL (default http://localhost:8088); NETDATA_TOKEN, if the agent asks for one, sent as a bearer token and never written anywhere.
set -uo pipefail

config="${1:-}"; tenant_id="${2:-}"
gateway="${GATEWAY_URL:-http://localhost:8088}"
if [[ -z "$config" || -z "$tenant_id" || ! -f "$config" ]]; then
  echo "usage: $0 <config.json> <organisationId>" >&2; exit 2
fi
cfg() { python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print($1)" "$config"; }

netdata=$(cfg "c.get('netdata','http://localhost:19999')")
nd_args=(-sS -m 15)
[[ -n "${NETDATA_TOKEN:-}" ]] && nd_args+=(-H "Authorization: Bearer $NETDATA_TOKEN")
tl_args=(-sS -m 15 -H "X-Tenant-Id: $tenant_id" -H 'X-Executor: netdata-sync' -H 'Content-Type: application/json')
reported=0; failed=0

report() { # report <what> <expected codes, space separated> <url> <body>
  local what=$1 ok=$2 url=$3 body=$4 code
  code=$(curl "${tl_args[@]}" -o /dev/null -w '%{http_code}' -X POST "$url" -d "$body" 2>/dev/null)
  if [[ " $ok " == *" $code "* ]]; then reported=$((reported + 1)); echo "ok      $what ($code)"; else failed=$((failed + 1)); echo "FAILED  $what (HTTP $code)" >&2; fi
}

if [[ "$(cfg "str(c.get('nodes', True)).lower()")" == "true" ]]; then
  if info=$(curl "${nd_args[@]}" "$netdata/api/v1/info"); then
    body=$(python3 -c '
import json,sys
i=json.loads(sys.argv[1])
keep=["version","os_name","os_version","kernel_name","kernel_version","architecture","virtualization","cores_total","ram_total","total_disk_space","cloud_provider_type","cloud_instance_type"]
attrs={k:str(i[k]) for k in keep if i.get(k) not in (None,"","unknown")}
host=(i.get("mirrored_hosts") or ["netdata-node"])[0]
print(json.dumps({"source":"netdata","externalKey":i["uid"],"name":host,"rawAttributes":attrs}))' "$info" 2>/dev/null) \
      && report "node" "200 201" "$gateway/it-discovery/v1/initiate" "$body" \
      || { failed=$((failed + 1)); echo "FAILED  node (unreadable /api/v1/info)" >&2; }
  else
    failed=$((failed + 1)); echo "FAILED  node (Netdata not reachable at $netdata)" >&2
  fi
fi

now=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(second=0,microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"))')
count=$(cfg "len(c.get('samples', []))")
for ((n = 0; n < count; n++)); do
  entry=$(cfg "json.dumps(c['samples'][$n])")
  read -r policy chart < <(python3 -c 'import json,sys; e=json.loads(sys.argv[1]); print(e["policyId"], e["chart"])' "$entry")
  if ! data=$(curl "${nd_args[@]}" -G "$netdata/api/v1/data" --data-urlencode "chart=$chart" --data-urlencode "after=-20" --data-urlencode "points=1" \
        --data-urlencode "group=average" --data-urlencode "format=json"); then
    failed=$((failed + 1)); echo "FAILED  $chart (Netdata not reachable)" >&2; continue
  fi
  body=$(python3 -c '
import json,sys
e=json.loads(sys.argv[1]); d=json.loads(sys.argv[2]); now=sys.argv[3]
labels=d.get("labels",[])[1:]; rows=d.get("data",[])
if not rows: sys.exit(1)
row=rows[0][1:]
wanted=e.get("dimensions") or labels
missing=[w for w in wanted if w not in labels]
if missing: sys.exit(1)
total=sum(row[labels.index(w)] or 0 for w in wanted)*float(e.get("factor",1.0))
print(json.dumps({"policyId":e["policyId"],"value":round(total,4),"measuredAt":now}))' "$entry" "$data" "$now" 2>/dev/null) \
    || { failed=$((failed + 1)); echo "FAILED  $chart (no data, or a dimension that the chart does not have)" >&2; continue; }
  report "$chart -> policy ${policy:0:8}" "200 201" "$gateway/it-capacity-registry/v1/sample/initiate" "$body"
done

echo "netdata-sync: $reported reported, $failed failed"
exit $((failed > 0 ? 1 : 0))
