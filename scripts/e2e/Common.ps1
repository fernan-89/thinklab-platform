# Shared definitions for the local (no-Docker) ThinkLab stack. Dot-source this file.
$script:Workspace = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:Tools     = Join-Path $script:Workspace 'tools'
$script:RunDir    = Join-Path $script:Workspace 'thinklab-platform\.e2e'
# Single-node replica set name - required so mongod unlocks multi-document transactions (kit ADR-003).
$script:MongoReplSetName = 'thinklab-rs0'

# Order matters for the E2E run: the Party Reference Data Directory produces the organisationId
# that every other suite consumes as its tenant.
$script:Services = @(
    [pscustomobject]@{ Name = 'micronaut-hash-token-registry-service';            Port = 8080; Db = 'thinklab_hash_db' },
    [pscustomobject]@{ Name = 'micronaut-party-reference-data-directory-service'; Port = 8081; Db = 'thinklab_company_db' },
    # Every Site is scoped to an Organisation (X-Tenant-Id), so it comes right after the service that
    # produces organisationId - no other ordering dependency (no events, no cross-service warmup).
    [pscustomobject]@{ Name = 'micronaut-site-reference-data-directory-service';    Port = 8087; Db = 'thinklab_site_db' },
    # Events = $true: services with io.nats:jnats on their runtime classpath and the thinklab.events.*
    # config block (kit ADR-003). THINKLAB_EVENTS_ENABLED must not leak to any other service - one that
    # has the property but not the jnats jar fails at startup with NoSuchBeanException on EventPublisher
    # (found live: the gateway crashed its OutboxRelay this way).
    [pscustomobject]@{ Name = 'micronaut-party-authentication-service';           Port = 8082; Db = 'thinklab_party_authentication_db'; Events = $true },
    # Consumes it-hardware-maintenance's repair-started/repair-completed events (that service's own
    # ADR-034) to drive Asset MAINTENANCE status - Events = $true even though this service is listed
    # before the one that produces those events; NATS delivery is independent of HTTP startup order.
    [pscustomobject]@{ Name = 'micronaut-it-asset-registry-service';              Port = 8083; Db = 'thinklab_asset_db'; Events = $true },
    [pscustomobject]@{ Name = 'micronaut-it-operation-window-service';            Port = 8084; Db = 'thinklab_operation_db' },
    # Publishes repair-started/repair-completed (ADR-034); the asset it references is created by
    # whichever suite runs before it, not a startup-order dependency of this service itself.
    [pscustomobject]@{ Name = 'micronaut-it-hardware-maintenance-service';        Port = 8085; Db = 'thinklab_hardware_maintenance_db'; Events = $true },
    # No MongoDB of its own (stateless proxy); listed last so its own readiness (which depends on
    # party-authentication's liveness via warmup.endpoints) has something to actually wait on.
    [pscustomobject]@{ Name = 'micronaut-platform-gateway-service';                Port = 8088; Db = $null },
    # Consumes party-authentication's user.initiated event (micronaut-thinklab-service-kit ADR-003), so it comes
    # after it; also has nothing to wait on before NATS itself is up.
    [pscustomobject]@{ Name = 'micronaut-notification-dispatch-service';           Port = 8089; Db = 'thinklab_notification_db'; Events = $true },
    # No events either (ADR-032 of both new Journey 7 services) - it-change-management calls both of
    # these synchronously over HTTP at request time, not at startup, so list order here is only
    # cosmetic (matches the dependency direction for readability, not a real wait-for requirement).
    [pscustomobject]@{ Name = 'micronaut-workflow-approval-service';               Port = 8090; Db = 'thinklab_workflow_approval_db' },
    [pscustomobject]@{ Name = 'micronaut-it-change-management-service';            Port = 8086; Db = 'thinklab_it_change_management_db' },
    # Journey 10. No events. it-discovery calls it-asset-registry only on control/promote, and
    # it-asset-registry calls ci-type-catalog on initiate/update (fail-open), all at request time, so list
    # order is only cosmetic - except that ci-type-catalog is LAST on purpose: its own suite activates
    # SERVER/LAPTOP schemas on the shared tenant, which must not exist yet while earlier suites create assets.
    [pscustomobject]@{ Name = 'micronaut-it-discovery-service';                    Port = 8091; Db = 'thinklab_it_discovery_db' },
    [pscustomobject]@{ Name = 'micronaut-it-topology-graph-service';               Port = 8092; Db = 'thinklab_it_topology_graph_db' },
    # Journey 8. Independent of the others; the gateway appends to it when gateway.audit.enabled is on.
    [pscustomobject]@{ Name = 'micronaut-compliance-audit-ledger-service';         Port = 8094; Db = 'thinklab_compliance_audit_ledger_db' },
    # Journey 9. Independent of the others; no events, no calls to other services (the web app and, later, other services ask it).
    [pscustomobject]@{ Name = 'micronaut-subscription-billing-service';            Port = 8095; Db = 'thinklab_subscription_billing_db' },
    # Journey 13 (consumables). Independent; no events, no calls to other services.
    [pscustomobject]@{ Name = 'micronaut-consumable-inventory-service';            Port = 8096; Db = 'thinklab_consumable_inventory_db' },
    # Journey 13b. Calls party-authentication synchronously at sign-in time (never at startup), so list order is only cosmetic.
    [pscustomobject]@{ Name = 'micronaut-identity-federation-service';             Port = 8097; Db = 'thinklab_identity_federation_db' },
    # Journey 12 (ITSM core), incidents. Independent: only the hash registry for sovereign ids; no events, no calls to other services.
    [pscustomobject]@{ Name = 'micronaut-it-incident-management-service';           Port = 8098; Db = 'thinklab_it_incident_management_db' },
    # Journey 12, service requests. The hash registry for sovereign ids; workflow-approval only at call time, and only for an item with an approval policy.
    [pscustomobject]@{ Name = 'micronaut-it-service-request-service';            Port = 8099; Db = 'thinklab_it_service_request_db' },
    # Journey 12, problems. Independent: only the hash registry for sovereign ids; no events, no calls to other services.
    [pscustomobject]@{ Name = 'micronaut-it-problem-management-service';        Port = 8100; Db = 'thinklab_it_problem_management_db' },
    # Journey 12, knowledge base. Independent: only the hash registry for sovereign ids; no events, no calls to other services.
    [pscustomobject]@{ Name = 'micronaut-it-knowledge-base-service';            Port = 8101; Db = 'thinklab_it_knowledge_base_db' },
    # Journey 12, ServiceNow and Jira connector. Reads and acts on the incident, request and problem services at request time (no events,
    # no startup dependency); needs the hash registry for sovereign ids. Its credentials are environment variables it is told the NAMES of.
    [pscustomobject]@{ Name = 'micronaut-it-external-ticketing-service';        Port = 8102; Db = 'thinklab_it_external_ticketing_db' },
    # Journey 14, health monitoring. Independent: only the hash registry for sovereign ids. It probes its targets itself (a scheduler in the service), no events.
    [pscustomobject]@{ Name = 'micronaut-it-health-monitoring-service';           Port = 8103; Db = 'thinklab_it_health_monitoring_db' },
    # Journey 14, alerting. Polls the health monitor and opens an incident on the incident service (their default local ports), no events; needs the hash registry.
    [pscustomobject]@{ Name = 'micronaut-it-alerting-service';                    Port = 8104; Db = 'thinklab_it_alerting_db' },
    # Journey 14, backup registry. Independent: only the hash registry for sovereign ids. It records what the backup tools report, no scheduler, no events.
    [pscustomobject]@{ Name = 'micronaut-it-backup-registry-service';             Port = 8105; Db = 'thinklab_it_backup_registry_db' },
    [pscustomobject]@{ Name = 'micronaut-ci-type-catalog-service';                 Port = 8093; Db = 'thinklab_ci_type_catalog_db' }
)

function Get-Java21 {
    $candidates = Get-ChildItem "$env:USERPROFILE\.jdks" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '21' } | Sort-Object Name -Descending
    foreach ($c in $candidates) { $j = Join-Path $c.FullName 'bin\java.exe'; if (Test-Path $j) { return $j } }
    if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\java.exe")) { return "$env:JAVA_HOME\bin\java.exe" }
    throw 'No JDK 21 found (looked in ~/.jdks and JAVA_HOME).'
}

function Wait-Http($url, $timeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { return $true } } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}
