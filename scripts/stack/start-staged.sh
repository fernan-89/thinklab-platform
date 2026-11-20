#!/usr/bin/env bash
# Starts the compose stack in stages instead of all at once.
#
# About forty JVMs starting together on a hosted runner (4 CPUs) can starve the machine until even the runner agent stops answering GitHub: the e2e job then
# hangs for its whole time limit and the job log is lost. Here the infrastructure (MongoDB, NATS, the anchor store) comes up first and is waited for, then the
# services start a few at a time, each group waited for (/health/readiness on its port) before the next one begins, and the extras of the test profiles
# (second gateway, the test doubles) last. Every stage prints the time, the load, the free memory and the number of containers, so a log that does survive
# says where the machine starts to struggle.
#
#   scripts/stack/start-staged.sh             # the profiles the e2e job uses
#   START_BATCH_SIZE=4 scripts/stack/start-staged.sh
#
# Environment: START_BATCH_SIZE (default 6), START_BATCH_TIMEOUT seconds to wait for one group (default 150), COMPOSE_PROFILES (default: the four test profiles).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/services.sh"
cd "$PLATFORM_DIR"

: "${COMPOSE_PROFILES:=sso-test,ticketing-test,health-test,plan-gating}"
export COMPOSE_PROFILES
batch_size="${START_BATCH_SIZE:-6}"
batch_timeout="${START_BATCH_TIMEOUT:-150}"

stamp() {
  local load free
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo n/a)
  free=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
  printf '[%s] %-34s load %-5s free %-6s MiB containers %s\n' "$(date +%H:%M:%S)" "$1" "$load" "${free:-n/a}" "$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
}

fail() {
  echo "::error::$1"
  stamp "FAILED"
  docker compose ps -a --format 'table {{.Name}}\t{{.Status}}' 2>&1 | grep -v ' Up ' | head -40
  exit 1
}

# 1. Infrastructure: started on its own and waited for through its healthchecks. First the tools one-shot, which fills the volume that the healthcheck of every
# Java service runs from (the images are distroless: no curl); it exits by itself.
stamp "start: tools and infrastructure"
timeout -k 10 120 docker compose run --rm --no-deps tools || fail "the tools one-shot (busybox for the healthchecks) did not finish"
timeout -k 10 200 docker compose up -d --wait --wait-timeout 150 mongo nats anchor-store || fail "infrastructure (mongo, nats, anchor-store) did not become healthy"
stamp "infrastructure healthy"

# 2. The services of services.sh, a few at a time. --no-deps: the infrastructure is already up and nothing else needs starting.
all=("${THINKLAB_SERVICES[@]}")
known=()
for entry in "${all[@]}"; do IFS='|' read -r _ service _ <<<"$entry"; known+=("$service"); done

index=0
group=1
while ((index < ${#all[@]})); do
  names=()
  entries=("${all[@]:index:batch_size}")
  for entry in "${entries[@]}"; do IFS='|' read -r _ service _ <<<"$entry"; names+=("$service"); done
  stamp "group $group: ${names[*]:0:2}..."
  timeout -k 10 120 docker compose up -d --no-deps "${names[@]}" || fail "docker compose could not start group $group (${names[*]})"

  deadline=$((SECONDS + batch_timeout))
  pending=("${entries[@]}")
  while ((${#pending[@]} > 0 && SECONDS < deadline)); do
    still=()
    for entry in "${pending[@]}"; do
      IFS='|' read -r _ service port <<<"$entry"
      curl -fs -o /dev/null --max-time 3 "http://localhost:$port/health/readiness" || still+=("$entry")
    done
    pending=("${still[@]+"${still[@]}"}")
    ((${#pending[@]} > 0)) && sleep 3
  done
  if ((${#pending[@]} > 0)); then
    for entry in "${pending[@]}"; do
      IFS='|' read -r _ service port <<<"$entry"
      echo "NOT READY: $service (:$port)"
      timeout -k 5 30 docker compose logs --no-color --tail 30 "$service" 2>&1 | cut -c1-300
    done
    fail "group $group not ready after ${batch_timeout}s"
  fi
  stamp "group $group ready"
  index=$((index + batch_size))
  group=$((group + 1))
done

# 3. What the test profiles add (the second gateway, the test doubles): every compose service that is not infrastructure and not in the list above.
extras=()
while IFS= read -r service; do
  [[ -z "$service" ]] && continue
  case " mongo nats anchor-store ${known[*]} " in *" $service "*) continue ;; esac
  extras+=("$service")
done < <(docker compose config --services)
if ((${#extras[@]} > 0)); then
  stamp "extras: ${extras[*]}"
  timeout -k 10 120 docker compose up -d --no-deps "${extras[@]}" || fail "docker compose could not start the extras (${extras[*]})"
fi
stamp "stack started"
