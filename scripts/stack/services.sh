# Shared by the bash stack/e2e scripts: sourced, not executed.
# repository | compose service | host port. Order matters for the E2E run: the Party Reference Data
# Directory creates the organisationId every later suite uses as its tenant.
THINKLAB_SERVICES=(
  "micronaut-hash-token-registry-service|hash-token-registry|8080"
  "micronaut-party-reference-data-directory-service|party-reference-data-directory|8081"
  "micronaut-party-authentication-service|party-authentication|8082"
  "micronaut-it-asset-registry-service|it-asset-registry|8083"
  "micronaut-it-operation-window-service|it-operation-window|8084"
  "micronaut-it-hardware-maintenance-service|it-hardware-maintenance|8085"
  "micronaut-site-reference-data-directory-service|site-reference-data-directory|8087"
  "micronaut-platform-gateway-service|gateway|8088"
  "micronaut-notification-dispatch-service|notification-dispatch|8089"
  "micronaut-workflow-approval-service|workflow-approval|8090"
  "micronaut-it-change-management-service|it-change-management|8086"
  "micronaut-it-discovery-service|it-discovery|8091"
  "micronaut-it-topology-graph-service|it-topology-graph|8092"
  "micronaut-compliance-audit-ledger-service|compliance-audit-ledger|8094"
  "micronaut-subscription-billing-service|subscription-billing|8095"
  "micronaut-consumable-inventory-service|consumable-inventory|8096"
  "micronaut-ci-type-catalog-service|ci-type-catalog|8093"
)
PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE_DIR="$(cd "$PLATFORM_DIR/.." && pwd)"
