#!/usr/bin/env bash
# The gateway has no Postman suite of its own: this checks it routes one read to every upstream service.
set -uo pipefail
gateway="${GATEWAY_URL:-http://localhost:8088}"
tenant="${1:-00000000-0000-0000-0000-000000000000}"
failed=0
for path in \
  party-reference-data-directory/v1/retrieve \
  party-authentication/v1/retrieve \
  it-asset-registry/v1/retrieve \
  it-operation-window/v1/retrieve \
  notification-dispatch/v1/retrieve; do
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "X-Tenant-Id: $tenant" "$gateway/$path")
  echo "GET /$path -> $status"
  [[ "$status" == 200 ]] || failed=1
done
exit $failed
