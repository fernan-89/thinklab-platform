#!/usr/bin/env bash
# Runs `gradlew installDist` in every sibling service repository; docker-compose.yml packages the result.
# thinklab-service-kit comes from GitHub Packages: export GITHUB_ACTOR and GITHUB_TOKEN (a token with
# read:packages), or have the kit in your local Maven repository (`./gradlew publishToMavenLocal` in it).
set -euo pipefail
source "$(dirname "$0")/services.sh"

for entry in "${THINKLAB_SERVICES[@]}"; do
  repo="${entry%%|*}"
  dir="$WORKSPACE_DIR/$repo"
  [[ -d "$dir" ]] || { echo "missing $dir (clone the service repositories next to thinklab-platform)" >&2; exit 1; }
  echo "==> $repo"
  (cd "$dir" && ./gradlew installDist --console=plain -q)
done
