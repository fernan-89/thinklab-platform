#!/usr/bin/env bash
# Waits until every service of the compose stack reports /health/readiness UP (default 180s).
# On timeout it prints the logs of the services that are not ready and exits 1.
set -uo pipefail
source "$(dirname "$0")/services.sh"
timeout="${1:-180}"
deadline=$((SECONDS + timeout))
pending=("${THINKLAB_SERVICES[@]}")

while ((${#pending[@]} > 0 && SECONDS < deadline)); do
  still=()
  for entry in "${pending[@]}"; do
    IFS='|' read -r repo service port <<<"$entry"
    if curl -fs -o /dev/null --max-time 3 "http://localhost:$port/health/readiness"; then
      echo "ready: $service (:$port)"
    else
      still+=("$entry")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
  ((${#pending[@]} > 0)) && sleep 3
done

if ((${#pending[@]} > 0)); then
  for entry in "${pending[@]}"; do
    IFS='|' read -r repo service port <<<"$entry"
    echo "NOT READY: $service (:$port)"
    curl -sS --max-time 3 "http://localhost:$port/health/readiness"; echo
    docker compose -f "$PLATFORM_DIR/docker-compose.yml" logs --tail 80 "$service"
  done
  exit 1
fi
echo "Stack is up."
