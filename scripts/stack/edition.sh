#!/usr/bin/env bash
# The editions of the local stack: the services each one starts, with a heap that suits it, and a check of what that costs in memory.
#
#   scripts/stack/edition.sh <homelab|team|enterprise> up          # starts only that edition (the images must be built: scripts/stack/build.sh)
#   scripts/stack/edition.sh <edition> down                        # stops them
#   scripts/stack/edition.sh <edition> footprint                   # memory of the running containers of this project; exits 1 over the budget
#   scripts/stack/edition.sh <edition> services                    # the services of the set, one per line (the CI checks that each is defined in docker-compose.yml)
#
# Each edition contains the one before it:
#   homelab     sign-in, assets, discovery, health checks, capacity, incidents and alerting, behind the gateway.
#   team        + sites, maintenance windows and hardware maintenance, change management with its approvals, the service desk (requests, problems,
#               knowledge base), the topology graph and the type catalog, notifications, and the backup, patch, DR, vendor and licence registries.
#   enterprise  everything the compose file starts: also the audit ledger and its anchor store, plans and subscriptions, consumables, single sign-on,
#               the Jira and ServiceNow connector, IPAM and cloud costs.
# A route of a service that is not started answers 502 from the gateway; nothing else depends on the missing services. Environment:
#   THINKLAB_JAVA_OPTS               the JVM options of every service (default below: a 160 MiB heap for homelab, 192 MiB for team, the compose default of 256 MiB for enterprise)
#   THINKLAB_GATEWAY_JAVA_OPTS       the same for the gateway, which is not capped outside these editions (default below: 256 MiB)
#   THINKLAB_FOOTPRINT_BUDGET_MIB    what `footprint` allows in total (default per edition: 2560, 6144 and 9216 MiB, about a fifth above what was measured idle: 2.1, 5.0 and 7.3 GiB)
#   COMPOSE_FILE / COMPOSE_PROJECT_NAME   as docker compose reads them (for instance to add an override file)
set -euo pipefail
cd "$(dirname "$0")/../.."

edition="${1:-}"; command="${2:-}"

homelab=(mongo nats hash-token-registry party-reference-data-directory party-authentication it-asset-registry it-discovery it-health-monitoring
         it-capacity-registry it-incident-management it-alerting gateway)
team=("${homelab[@]}" site-reference-data-directory it-operation-window it-hardware-maintenance workflow-approval it-change-management it-service-request
      it-problem-management it-knowledge-base it-topology-graph ci-type-catalog notification-dispatch it-backup-registry it-patch-registry it-dr-registry
      it-vendor-registry it-license-registry)
enterprise=("${team[@]}" compliance-audit-ledger anchor-store subscription-billing consumable-inventory identity-federation it-external-ticketing it-ipam it-cloud-cost it-cloud-inventory)

case "$edition" in
  homelab) services=("${homelab[@]}"); heap="-Xmx160m"; budget_default=2560 ;;
  team) services=("${team[@]}"); heap="-Xmx192m"; budget_default=6144 ;;
  enterprise) services=("${enterprise[@]}"); heap="-Xmx256m"; budget_default=9216 ;;
  *) echo "usage: $0 <homelab|team|enterprise> up|down|footprint|services" >&2; exit 2 ;;
esac
export THINKLAB_JAVA_OPTS="${THINKLAB_JAVA_OPTS:-$heap -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1}"
export THINKLAB_GATEWAY_JAVA_OPTS="${THINKLAB_GATEWAY_JAVA_OPTS:--Xmx256m -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1}"
budget="${THINKLAB_FOOTPRINT_BUDGET_MIB:-$budget_default}"

case "$command" in
  up) docker compose up -d --no-build "${services[@]}" ;;
  down) docker compose stop "${services[@]}" ;;
  services) printf '%s\n' "${services[@]}" ;;
  footprint)
    ids=$(docker compose ps -q "${services[@]}")
    [[ -n "$ids" ]] || { echo "no $edition container is running (scripts/stack/edition.sh $edition up)" >&2; exit 2; }
    # shellcheck disable=SC2086
    docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $ids | python3 -c '
import re,sys
total=0.0
rows=[]
for line in sys.stdin:
    name,used=line.split()[0],line.split()[1]
    n=float(re.match(r"[0-9.]+",used).group())
    mib=n*1024 if "GiB" in used else n/1024 if "KiB" in used else n
    rows.append((mib,name)); total+=mib
for mib,name in sorted(rows,reverse=True): print("%8.1f MiB  %s" % (mib,name))
budget=float(sys.argv[1])
print("%8.1f MiB  total in %d containers (budget %.0f MiB)" % (total,len(rows),budget))
sys.exit(0 if total<=budget else 1)' "$budget"
    ;;
  *) echo "usage: $0 $edition up|down|footprint|services" >&2; exit 2 ;;
esac
