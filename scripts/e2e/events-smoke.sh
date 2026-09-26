#!/usr/bin/env bash
# The event backbone end to end against the running stack: creating a User makes party-authentication
# write a user.initiated event through its transactional outbox, the relay publishes it to NATS
# JetStream, and notification-dispatch consumes it and delivers a welcome notification.
set -euo pipefail
org_url="${ORG_URL:-http://localhost:8081}/party-reference-data-directory/v1"
auth_url="${AUTH_URL:-http://localhost:8082}/party-authentication/v1"
notification_url="${NOTIFICATION_URL:-http://localhost:8089}/notification-dispatch/v1"
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

tax_id=$(printf '%014d' $(( (RANDOM << 30 | RANDOM << 15 | RANDOM) % 100000000000000 )))
organisation_id=$(curl -fsS -X POST "$org_url/initiate" -H 'Content-Type: application/json' -H 'X-Executor: events-smoke' \
  -d "{\"corporateName\":\"Events Corp\",\"tradeName\":\"Events\",\"taxIdentifier\":\"$tax_id\",\"billing\":{\"billingEmail\":\"b@events.example\",\"currency\":\"USD\",\"taxRegime\":\"SIMPLES\"}}" \
  | json "['id']")
echo "organisation created: $organisation_id"

email="ada.$(date +%s%N | tail -c 9)@events.example"
curl -fsS -o /dev/null -X POST "$auth_url/initiate" -H 'Content-Type: application/json' \
  -H 'X-Executor: events-smoke' -H "X-Tenant-Id: $organisation_id" \
  -d "{\"fullName\":\"Ada Lovelace\",\"email\":\"$email\",\"role\":\"OPERATOR\"}"
echo "user created: $email (this writes the outbox event)"

for _ in $(seq 1 15); do
  found=$(curl -fsS "$notification_url/retrieve?status=DELIVERED" -H "X-Tenant-Id: $organisation_id" \
    | python3 -c "import json,sys; print(next((n['subject'] for n in json.load(sys.stdin) if n.get('recipient')=='$email'), ''))")
  if [[ "$found" == "Welcome to ThinkLab" ]]; then
    echo "welcome notification DELIVERED to $email"
    exit 0
  fi
  sleep 2
done
echo "no welcome notification for $email after 30s" >&2
exit 1
