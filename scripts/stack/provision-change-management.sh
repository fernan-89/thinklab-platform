#!/usr/bin/env bash
# Provisions real CAB/ECAB ApprovalPolicy records against a running workflow-approval-service, for
# it-change-management (GMUD): thinklab.change-management.cab-policy-id/ecab-policy-id have no runtime
# API and must be set at JVM boot (that service's ADR-031), so under docker-compose this can only work
# in two phases - start the stack once with it-change-management blank (STANDARD changes still work,
# since they're pre-approved), provision the policies here now that workflow-approval is up, then
# `docker compose up -d it-change-management` again to recreate just that one container with the real
# ids (compose detects the changed environment and restarts it - nothing else is touched).
#
# Writes thinklab-platform/.e2e/change-management-policies.json (same schema start-local-stack.ps1's own
# provisioning step writes, so change-management-smoke.sh can read it the same way its PowerShell
# counterpart does) and prints THINKLAB_CAB_POLICY_ID=... / THINKLAB_ECAB_POLICY_ID=... lines, meant to
# be appended straight into $GITHUB_ENV (or sourced locally: `source <(./provision-change-management.sh)`).
set -euo pipefail
source "$(dirname "$0")/services.sh"
workflow_approval_url="${1:-http://localhost:8090}/workflow-approval/v1"
out_dir="$PLATFORM_DIR/.e2e"
mkdir -p "$out_dir"

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

tenant=$(uuid)
cab_approvers=("$(uuid)" "$(uuid)" "$(uuid)")
ecab_approvers=("$(uuid)" "$(uuid)")

create_policy() {
  local name=$1 required=$2; shift 2
  local approvers=("$@")
  local ids_json
  ids_json=$(printf '"%s",' "${approvers[@]}"); ids_json="[${ids_json%,}]"
  curl -sS -X POST "$workflow_approval_url/policy/initiate" \
    -H "X-Tenant-Id: $tenant" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"requiredApprovals\":$required,\"eligibleApproverIds\":$ids_json}"
}

cab_response=$(create_policy CAB 2 "${cab_approvers[@]}")
ecab_response=$(create_policy ECAB 1 "${ecab_approvers[@]}")
cab_id=$(echo "$cab_response" | json "['id']")
ecab_id=$(echo "$ecab_response" | json "['id']")

python3 -c "
import json, sys
json.dump({
    'cabPolicyId': sys.argv[1], 'cabApproverIds': sys.argv[2].split(','),
    'ecabPolicyId': sys.argv[3], 'ecabApproverIds': sys.argv[4].split(','),
}, open(sys.argv[5], 'w'))
" "$cab_id" "$(IFS=,; echo "${cab_approvers[*]}")" "$ecab_id" "$(IFS=,; echo "${ecab_approvers[*]}")" \
  "$out_dir/change-management-policies.json"

echo "CAB policy [$cab_id] ECAB policy [$ecab_id]" >&2
echo "THINKLAB_CAB_POLICY_ID=$cab_id"
echo "THINKLAB_ECAB_POLICY_ID=$ecab_id"
