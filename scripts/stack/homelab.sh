#!/usr/bin/env bash
# The Homelab edition of the local stack: the services a home lab needs, with a smaller heap, and a check of what that costs in memory.
#
#   scripts/stack/homelab.sh up          # starts only the Homelab services (the images must be built: scripts/stack/build.sh)
#   scripts/stack/homelab.sh down        # stops them
#   scripts/stack/homelab.sh footprint   # memory of the running containers of this project; exits 1 over the budget
#
# Homelab = sign-in, assets, discovery, health checks, capacity, incidents and alerting, behind the gateway. A route of a service that is not started
# answers 502 from the gateway; nothing else depends on the missing services. Environment:
#   THINKLAB_JAVA_OPTS               the JVM options of every service (default below: a 160 MiB heap)
#   THINKLAB_GATEWAY_JAVA_OPTS       the same for the gateway, which is not capped outside Homelab
#   THINKLAB_FOOTPRINT_BUDGET_MIB    what `footprint` allows in total (default 2560)
#   COMPOSE_FILE / COMPOSE_PROJECT_NAME   as docker compose reads them (for instance to add an override file)
set -euo pipefail
cd "$(dirname "$0")/../.."

services=(mongo nats hash-token-registry party-reference-data-directory party-authentication it-asset-registry it-discovery it-health-monitoring
          it-capacity-registry it-incident-management it-alerting gateway)
export THINKLAB_JAVA_OPTS="${THINKLAB_JAVA_OPTS:--Xmx160m -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1}"
export THINKLAB_GATEWAY_JAVA_OPTS="${THINKLAB_GATEWAY_JAVA_OPTS:--Xmx256m -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1}"
budget="${THINKLAB_FOOTPRINT_BUDGET_MIB:-2560}"

case "${1:-}" in
  up) docker compose up -d --no-build "${services[@]}" ;;
  down) docker compose stop "${services[@]}" ;;
  footprint)
    ids=$(docker compose ps -q "${services[@]}")
    [[ -n "$ids" ]] || { echo "no Homelab container is running (scripts/stack/homelab.sh up)" >&2; exit 2; }
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
  *) echo "usage: $0 up|down|footprint" >&2; exit 2 ;;
esac
