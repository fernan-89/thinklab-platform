#!/usr/bin/env bash
# Provisions the purchase-order ApprovalPolicy of it-procurement against a running workflow-approval-service (one approval, two eligible approvers) and writes
# .e2e/procurement-policy.json for the smokes that send purchase orders for approval. it-procurement needs no restart: the policy of an order is that of its approval
# band (procurement ADR-036), and each smoke makes a band at 0 for its own tenant with this policy.
#
# The file is still called provision-change-management for the scripts that call it. It no longer provisions a CAB and ECAB: since ADR-039 of it-change-management
# they belong to each tenant (PUT /it-change-management/v1/approval-settings/update), so the smokes that route changes make their own and there is no shared pair
# to put in the environment and no second boot of change-management.
set -euo pipefail
source "$(dirname "$0")/services.sh"
workflow_approval_url="${1:-http://localhost:8090}/workflow-approval/v1"
out_dir="$PLATFORM_DIR/.e2e"
mkdir -p "$out_dir"

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

tenant=$(uuid)
po_approvers=("$(uuid)" "$(uuid)")

ids_json=$(printf '"%s",' "${po_approvers[@]}"); ids_json="[${ids_json%,}]"
# one approval of two eligible approvers, on the same tenant (policies belong to a tenant)
po_response=$(curl -sS -X POST "$workflow_approval_url/policy/initiate" \
  -H "X-Tenant-Id: $tenant" -H 'Content-Type: application/json' \
  -d "{\"name\":\"PURCHASE-ORDER\",\"requiredApprovals\":1,\"eligibleApproverIds\":$ids_json}")
po_id=$(echo "$po_response" | json "['id']")

python3 -c "
import json, sys
json.dump({'tenantId': sys.argv[1], 'policyId': sys.argv[2], 'approverIds': sys.argv[3].split(',')}, open(sys.argv[4], 'w'))
" "$tenant" "$po_id" "$(IFS=,; echo "${po_approvers[*]}")" "$out_dir/procurement-policy.json"

echo "purchase-order policy [$po_id]" >&2
