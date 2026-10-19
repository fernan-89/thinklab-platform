#!/usr/bin/env bash
# The Homelab edition: see scripts/stack/edition.sh, which holds the editions. `homelab.sh up|down|footprint|services` is `edition.sh homelab ...`.
exec "$(dirname "$0")/edition.sh" homelab "$@"
