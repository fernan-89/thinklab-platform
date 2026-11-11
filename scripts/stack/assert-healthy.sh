#!/usr/bin/env bash
# Waits until every container of the compose project reports a healthy Docker healthcheck, and fails, listing the others, if one does not.
#
# docker-compose.yml gives every Java service, the gateways and the test doubles a healthcheck (the infrastructure had one already). Whether a service
# answers on its port (wait-ready.sh) is not the same as Docker saying it is healthy: this is the proof of the second, and it catches a service that
# lost its healthcheck. The `tools` one-shot (it exits with 0 by design) is the only exception.
#
#   scripts/stack/assert-healthy.sh        # waits up to 150 seconds
#   scripts/stack/assert-healthy.sh 60
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/services.sh"
cd "$PLATFORM_DIR"

timeout_s="${1:-150}"
project="${COMPOSE_PROJECT_NAME:-thinklab}"
exempt=" tools "
deadline=$((SECONDS + timeout_s))

while true; do
  bad=()
  rows=()
  while IFS='|' read -r service name; do
    [[ -z "$name" ]] && continue
    case "$exempt" in *" $service "*) continue ;; esac
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$name" 2>/dev/null || echo missing)
    rows+=("$service|$health")
    [[ "$health" == healthy ]] || bad+=("$service|$name|$health")
  done < <(docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Label "com.docker.compose.service"}}|{{.Names}}')

  if ((${#rows[@]} == 0)); then echo "no container of the project '$project' was found"; exit 1; fi
  ((${#bad[@]} == 0)) && break
  ((SECONDS >= deadline)) && break
  sleep 5
done

echo "health of ${#rows[@]} containers (tools excluded):"
printf '%s\n' "${rows[@]}" | cut -d'|' -f2 | sort | uniq -c | sed 's/^/  /'
if ((${#bad[@]} > 0)); then
  for entry in "${bad[@]}"; do
    IFS='|' read -r service name health <<<"$entry"
    echo "NOT HEALTHY: $service ($health)"
    docker inspect --format '{{if .State.Health}}{{range $i, $l := .State.Health.Log}}{{if $i}}{{end}}  last probe: exit {{$l.ExitCode}} {{$l.Output}}{{end}}{{end}}' "$name" 2>/dev/null | tail -2 | cut -c1-200
  done
  exit 1
fi
echo "every container is healthy"
