#!/usr/bin/env bash
# Runs every service's Postman suite with newman against the running stack, in dependency order,
# threading the organisationId created by the Party Reference Data Directory suite into the others.
# Needs newman on the PATH (npm install -g newman). Reports land in .e2e/reports/.
set -uo pipefail
source "$(dirname "$0")/../stack/services.sh"
reports="$PLATFORM_DIR/.e2e/reports"
mkdir -p "$reports"
organisation_id=""
failed=()

for entry in "${THINKLAB_SERVICES[@]}"; do
  IFS='|' read -r repo service port <<<"$entry"
  postman="$WORKSPACE_DIR/$repo/docs/postman"
  collection=$(find "$postman" -maxdepth 1 -name '*.postman_collection.json' 2>/dev/null | head -1)
  environment=$(find "$postman" -maxdepth 1 -name '*.postman_environment.json' 2>/dev/null | head -1)
  [[ -n "$collection" && -n "$environment" ]] || { echo "--- $service: no Postman suite, skipped"; continue; }

  echo; echo "=== $service ==="
  args=(run "$collection" -e "$environment" --export-environment "$reports/$repo.env.json"
        --reporters cli,junit --reporter-junit-export "$reports/$repo.xml"
        --env-var "base_url=http://localhost:$port" --timeout-request 20000 --color off)
  [[ -n "$organisation_id" ]] && args+=(--env-var "organisationId=$organisation_id")
  newman "${args[@]}" || failed+=("$service")

  if [[ "$repo" == *party-reference-data-directory* && -f "$reports/$repo.env.json" ]]; then
    organisation_id=$(python3 -c 'import json,sys; print(next((v["value"] for v in json.load(open(sys.argv[1]))["values"] if v["key"]=="organisationId"), ""))' "$reports/$repo.env.json")
    echo "organisationId for downstream suites: $organisation_id"
  fi
done

echo
if ((${#failed[@]} > 0)); then echo "E2E failed: ${failed[*]}"; exit 1; fi
echo "E2E passed."
