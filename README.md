| `scripts/e2e/knowledge-base-smoke.sh` (`knowledge-base-smoke.ps1`) | the knowledge base through the gateway (knowledge-base ADR-030..033): an article linked to a real problem and found by problem, keyword and free text (MongoDB text index), review where nobody publishes their own article, versions (a new draft of the same key; publishing it retires the older one), a REQUESTER reads only published public articles without the people and links, a race between two reviewers where exactly one wins, every mutation (the refused ones too) recorded on the ledger |
| `scripts/e2e/external-ticketing-smoke.sh` (`external-ticketing-smoke.ps1`) | the ServiceNow and Jira connector through the gateway, against a test double of both (`mock-ticketing.mjs`, compose profile `ticketing-test`) that calls the webhook like the real ones (connector ADR-030..033): a connection that names environment variables and never holds a secret, a real incident linked to a Jira ticket in both directions (status and only the public comment out, a person's change and comment in as the integration identity, an internal note a requester cannot read), the provider's calls back for the integration's own pushes recognised and ignored, one event delivered five times applied once, the platform winning a refused cancel and a ServiceNow resolve without root cause, the webhook refusing a missing or wrong token, a ServiceNow problem, an unreachable provider and a refusing one that echoed the credentials (502, body not relayed, retried by a sync), disabled connections and detached links, staff only, two people linking the same incident at once with exactly one ticket, no secret in any answer, every mutation recorded on the ledger |
| `scripts/e2e/health-monitoring-smoke.sh` (`health-monitoring-smoke.ps1`) | health monitoring through the gateway, against a target double (`mock-target.mjs`, compose profile `health-test`) whose answer the script controls (health-monitoring ADR-030..033): the scheduler probing by itself (a 10 s check goes UP unasked, keeps probing, stops while paused, probes at once when resumed), a blip that is not an outage (one failure leaves it UP, the second takes it DOWN, one success brings it back, the audit trail holds exactly those changes), a TCP target refusing then recovering, a slow target as `timeout`, a redirect not followed, the target policy (metadata, link-local, decimal spelling, credentials, query refused), summary and filters, staff only, four simultaneous runs recording exactly one change of health, every mutation on the ledger |
| `scripts/e2e/problem-smoke.sh` (`problem-smoke.ps1`) | problem management through the gateway (problem ADR-030..033): a problem linked to a real incident and found from the problem side, the lifecycle with a known error that needs both a root cause and a workaround, reopen clearing the resolution, staff only (a REQUESTER gets 403), a race between two people, every mutation (the refused ones too) recorded on the ledger |
| `scripts/e2e/service-request-smoke.sh` (`service-request-smoke.ps1`) | the service catalog and requests through the gateway (service-request ADR-030..034): the catalog lifecycle and unique code, a request with no approval run to CLOSED with SLA judged when read, a request whose approval is a two-stage chain on workflow-approval (released by the last stage, ended by a rejection, withdrawn when cancelled), a REQUESTER sees only their own requests and no internal notes and cannot do staff actions (403), a race between two people, every mutation (the refused ones too) recorded on the ledger |
# ThinkLab Platform

Home of everything that is **not** a single service: the local stack, the end-to-end (E2E) runner,
cross-service documentation and the hand-off for the platform as a whole. Each service lives in its
own repository (`micronaut-<domain>-service`); this repository ties them together.

## Services and ports

| Service | Host port | Repository |
|---|---|---|
| hash-token-registry | 8080 | `micronaut-hash-token-registry-service` |
| party-reference-data-directory | 8081 | `micronaut-party-reference-data-directory-service` |
| party-authentication | 8082 | `micronaut-party-authentication-service` |
| it-asset-registry | 8083 | `micronaut-it-asset-registry-service` |
| it-operation-window | 8084 | `micronaut-it-operation-window-service` |
| it-hardware-maintenance | 8085 | `micronaut-it-hardware-maintenance-service` |
| site-reference-data-directory | 8087 | `micronaut-site-reference-data-directory-service` |
| platform-gateway | 8088 | `micronaut-platform-gateway-service` |
| notification-dispatch | 8089 | `micronaut-notification-dispatch-service` |
| it-change-management | 8086 | `micronaut-it-change-management-service` |
| workflow-approval | 8090 | `micronaut-workflow-approval-service` |
| it-discovery | 8091 | `micronaut-it-discovery-service` |
| it-topology-graph | 8092 | `micronaut-it-topology-graph-service` |
| ci-type-catalog | 8093 | `micronaut-ci-type-catalog-service` |
| compliance-audit-ledger | 8094 | `micronaut-compliance-audit-ledger-service` |
| subscription-billing | 8095 | `micronaut-subscription-billing-service` |
| consumable-inventory | 8096 | `micronaut-consumable-inventory-service` |
| identity-federation | 8097 | `micronaut-identity-federation-service` |
| it-incident-management | 8098 | `micronaut-it-incident-management-service` |
| it-service-request | 8099 | `micronaut-it-service-request-service` |
| it-problem-management | 8100 | `micronaut-it-problem-management-service` |
| it-knowledge-base | 8101 | `micronaut-it-knowledge-base-service` |
| it-external-ticketing | 8102 | `micronaut-it-external-ticketing-service` |
| it-health-monitoring | 8103 | `micronaut-it-health-monitoring-service` |
| it-alerting | 8104 | `micronaut-it-alerting-service` |
| it-backup-registry | 8105 | `micronaut-it-backup-registry-service` |
| it-patch-registry | 8106 | `micronaut-it-patch-registry-service` |
| it-capacity-registry | 8107 | `micronaut-it-capacity-registry-service` |
| it-vendor-registry | 8108 | `micronaut-it-vendor-registry-service` |
| it-license-registry | 8109 | `micronaut-it-license-registry-service` |
| it-ipam | 8110 | `micronaut-it-ipam-service` |
| it-cloud-cost | 8111 | `micronaut-it-cloud-cost-service` |
| it-dr-registry | 8112 | `micronaut-it-dr-registry-service` |

Infrastructure: MongoDB 8.0 as a single-node replica set (multi-document transactions, which the
transactional outbox needs) and NATS JetStream (the event backbone: party-authentication publishes
`user.initiated`, which notification-dispatch consumes; it-hardware-maintenance publishes repair
started/completed, which it-asset-registry consumes to move the Asset in and out of MAINTENANCE). Every
service except the gateway has its own database; the gateway is a stateless proxy in front of the
other APIs.

## Run the stack

All scripts expect the service repositories cloned as siblings of this one (`../micronaut-*-service`).

### With Docker

```bash
scripts/stack/build.sh           # gradlew installDist in every service (Windows: scripts\stack\build.ps1)
docker compose up -d --build
scripts/stack/wait-ready.sh      # waits for /health/readiness on every service
```

The web app (`../thinklab-web`) is behind a compose profile so the commands above never need it:
`docker compose --profile web up -d --build` serves it on http://localhost:3000 (`scripts/e2e/seed-demo.ps1` creates a demo tenant to sign in with).

### Editions and their memory

`scripts/stack/edition.sh <homelab|team|enterprise> up|down|footprint|services` (`edition.ps1`) starts only the services of an edition, each containing the one before it
(`homelab.sh` and `homelab.ps1` are `edition homelab`); the images must already be built. A route of a service that is not started answers 502.

| Edition | Services | Heap per service | Measured idle | Budget `footprint` allows |
|---|---|---|---|---|
| `homelab` | 12: MongoDB, NATS, sign-in, assets, discovery, health checks, capacity, incidents, alerting, the gateway | 160 MiB | 2.1 GiB | 2560 MiB |
| `team` | 28: also sites, maintenance windows and hardware maintenance, change management and its approvals, requests, problems, knowledge base, topology graph, type catalog, notifications, and the backup, patch, DR, vendor and licence registries | 192 MiB | 5.0 GiB | 6144 MiB |
| `enterprise` | 36: everything the compose file starts, also the audit ledger and its anchor store, plans and subscriptions, consumables, single sign-on, the Jira and ServiceNow connector, IPAM and cloud costs | 256 MiB (the compose default) | 7.3 GiB | 9216 MiB |

Measured on 2026-10-19, each edition started from nothing in its own compose project (own MongoDB 7.0, no published ports), then 90 to 150 seconds idle
once every container was up, nothing restarting. The gateway has a 256 MiB heap in all three (it had no cap at all and started at 1.1 GiB). In `enterprise`,
413 MiB is the `anchor-store`, a LocalStack standing in for S3 with Object Lock; against a real bucket it is not part of the stack. These are idle numbers:
a service under load grows to its heap. Heaps are set with `THINKLAB_JAVA_OPTS` and `THINKLAB_GATEWAY_JAVA_OPTS`, the budget with
`THINKLAB_FOOTPRINT_BUDGET_MIB`; `footprint` exits 1 over it.

### Starter pack of alert rules

`scripts/stack/seed-starter-pack.sh <HOMELAB|TEAM|ENTERPRISE> <organisationId> <requesterId>` (`seed-starter-pack.ps1` on Windows) gives a tenant the
alert rules its edition starts with, through the gateway. A rule with no check covers every check or policy of its source, so the pack keeps working as
assets are added:

| Edition | Rules |
|---|---|
| `HOMELAB` | health checks down, capacity policy critical |
| `TEAM` | the above, plus backup promise broken, patch overdue and recovery plan not ready |
| `ENTERPRISE` | the above (higher impact and urgency), plus vendor agreement about to end and licence over its limit |

It is only rules: capacity, backup and patch policies are about one asset and a number only its owner knows, so they cannot be guessed. Running it
again keeps what is there and adds what is missing (moving a tenant from `HOMELAB` to `TEAM` adds the three new rules), and it never touches a rule that
was changed or paused. No rule names a webhook, since the environment variables are the deployment's: add `notifyTarget` with `rule/update`.

### Netdata connector

`scripts/connectors/netdata-sync.sh <config.json> <organisationId>` (`netdata-sync.ps1 -Config ... -OrganisationId ...`) reads one Netdata agent and reports to ThinkLab through the gateway. It runs outside the
services, as the tool that measures (capacity-registry ADR-030): no ThinkLab service reaches an asset or holds a credential. Copy
`scripts/connectors/netdata.example.json` and fill in your capacity policy ids.

- **The node** goes to the discovery queue (`source: netdata`, keyed by the agent's id). A person still reviews and promotes it; a second run is a re-sighting, not a second item.
- **Each entry of `samples`** becomes one capacity sample: the chart's average over the last seconds, the named dimensions added up, times `factor`. The policy's limit and the sample must use the same unit, and the unit is Netdata's (`system.ram` is MiB, `disk_space` GiB). The moment is rounded to the minute, so two runs in a minute report one sample.
- **Alerts are not mirrored.** The samples feed the capacity policies, which the alerting service already watches (a `CAPACITY` rule).
- `NETDATA_TOKEN`, if the agent asks for one, is sent as a bearer token and never written anywhere. Run it from cron or a loop; it exits 1 if anything failed, 2 on bad usage.

The images package each service's `installDist` output, so nothing is compiled inside Docker and no
credential reaches an image. The build needs `micronaut-thinklab-service-kit` from GitHub Packages: export
`GITHUB_ACTOR` and `GITHUB_TOKEN` (a token with `read:packages`), or publish the kit to your local
Maven repository first (`./gradlew publishToMavenLocal` in `micronaut-thinklab-service-kit`).

`docker compose down -v` stops everything and drops the data volumes.

### Without Docker (portable tools, Windows)

`scripts/e2e` runs the same stack with portable MongoDB and NATS binaries and the services'
`installDist` output, with no installation or admin rights. Place the tools under `<workspace>/tools`:
`mongodb/`, `mongosh/`, `nats/`, `node/` and `newman/` (`npm install newman`).

```powershell
powershell -File scripts\e2e\start-local-stack.ps1 -Build   # builds every service, starts Mongo, NATS and the services
powershell -File scripts\e2e\run-e2e.ps1                    # runs the Postman suites with newman
powershell -File scripts\e2e\stop-local-stack.ps1           # -IncludeMongo to stop MongoDB too
```

## End-to-end tests

With the stack up (either way):

| Script | What it checks |
|---|---|
| `scripts/e2e/run-e2e.sh` (`run-e2e.ps1`) | every service's Postman suite (`docs/postman` in each repo), in dependency order, threading the `organisationId` created by the Party Reference Data Directory suite into the others |
| `scripts/e2e/starter-pack-smoke.sh` (`starter-pack-smoke.ps1`) | the starter pack of alert rules through the gateway: an edition gets its rules (Homelab 2, Team 5, Enterprise 7), each taking the class of its source, a repeat creates nothing, moving up adds only what is missing, a paused rule stays paused, another tenant has none, a wrong call exits 2 |
| `scripts/e2e/netdata-connector-smoke.sh` (`netdata-connector-smoke.ps1`) | the Netdata connector against a test double of an agent (`mock-netdata.mjs`, started by the script): the node reaches the discovery queue once, a chart becomes a capacity sample (dimensions added up, a factor), a failing chart or an unreachable agent fails only what it must, the token is sent and never printed |
| `scripts/e2e/dr-smoke.sh` (`dr-smoke.ps1`) | the DR registry through the gateway (DR registry ADR-030..033): a recovery plan judged when read, a walk through the runbook that counts as a pass but measures nothing, a failover and a full recovery that measure the recovery time and point, twenty reports of one exercise make one, a later pass clears a failure and a late report moves nothing, a backup-restore plan that cannot promise to lose nothing, the runbook as an identifier, a race between two people, staff only, every mutation recorded on the ledger |
| `scripts/e2e/events-smoke.sh` (`events-smoke.ps1`) | creating a user publishes `user.initiated` through the outbox and NATS, and notification-dispatch delivers the welcome notification |
| `scripts/e2e/hardware-maintenance-smoke.sh` (`hardware-maintenance-smoke.ps1`) | starting a WorkOrder repair moves the Asset into MAINTENANCE and passing quality check moves it back to DEPLOYED, both through NATS |
| `scripts/e2e/ledger-smoke.sh` (`ledger-smoke.ps1`) | the gateway records every mutating request on the compliance ledger and the hash chain verifies, anchoring included |
| `scripts/e2e/anchor-store-smoke.sh` | the write-once anchor store (ledger ADR-035; compose only, needs the LocalStack anchor store + the AWS CLI): the chain head is published to an Object Lock bucket in COMPLIANCE mode, a locked version cannot be deleted, a plain delete (a hidden-by-marker listing) does not hide the anchor from the ledger |
| `scripts/e2e/investigation-smoke.sh` (`investigation-smoke.ps1`) | the pseudonym lookup (gateway ADR-027): a known person's sign-in found by pseudonym, the lookup itself recorded on the ledger with its reason, no email or password anywhere, short/personal-data reasons refused |
| `scripts/e2e/incident-smoke.sh` (`incident-smoke.ps1`) | incident management through the gateway (incident ADR-030..033): the priority is derived from impact and urgency, the lifecycle with SLA judged when read, a REQUESTER sees only their own incidents and no internal notes and cannot do staff actions (403), a race between two people never loses or doubles a move, every mutation (the refused ones too) recorded on the ledger |
| `scripts/e2e/billing-smoke.sh` (`billing-smoke.ps1`) | plans, subscriptions and entitlements through the gateway (limits, plan change, grace period, suspension, one subscription per organisation), every subscription mutation recorded on the ledger |
| `scripts/e2e/inventory-smoke.sh` (`inventory-smoke.ps1`) | stock items and movements through the gateway: the balance never goes below zero even with eight concurrent issues against five units, the reorder-level flag and low-stock list follow the balance, every stock mutation recorded on the ledger |
| `scripts/e2e/federation-smoke.sh` (`federation-smoke.ps1`) | single sign-on against an OIDC provider double (`--profile sso-test`): sign-in only for pre-linked people, state replay refused, refresh token only in an HttpOnly cookie, rotation, replay of an old cookie revokes the session, auto-provision gives VIEWER only, secrets never in answers |
| `scripts/e2e/approval-chain-smoke.sh` (`approval-chain-smoke.ps1`) | approval chains through the gateway (workflow-approval ADR-033/034): a two-stage policy, a request that waits on one stage at a time, the approver inbox, two reviewers voting at the same instant (no vote lost: the loser of a race retries), a reject at stage 2, a policy edit that leaves a filed request alone, tenant isolation |
| `scripts/e2e/plan-gating-smoke.sh` (`plan-gating-smoke.ps1`) | plan-based feature gating at the gateway (ADR-026) against a second gateway with gating on (`--profile plan-gating`, port 8188): a plan without `audit`/`sso` is refused 403, a plan change and a suspension are felt within the cache time, unlisted domains and sign-in are untouched |
| `scripts/e2e/gateway-smoke.sh` | the gateway routes to each upstream API |
| `scripts/e2e/secured-smoke.ps1` | the security stack (tokens, JWKS, revocation) with `THINKLAB_SECURITY_ENABLED=true` |

The bash runners need `newman` on the `PATH` (`npm install -g newman`). Reports (JUnit XML and the
exported Postman environments) land in `.e2e/reports/`.

The [`e2e` workflow](.github/workflows/e2e.yml) does all of this on GitHub Actions: it clones
every service listed in `scripts/stack/services.sh` from `master`, builds and starts the compose stack
and runs the bash checks, on every
push and pull request here, nightly, and on demand.

## Quality gates

* Every service and the kit: `./gradlew check` in CI, which runs the unit tests with a 100% line and
  branch coverage gate (JaCoCo) and a separate integration suite against real MongoDB and NATS
  containers (Testcontainers). The CI also builds the container image.
* Platform: the `e2e` workflow above. The E2E runs found real defects the unit tests could not (see
  `docs/e2e-findings.md`).

## License

Licensed under the [PolyForm Strict License 1.0.0](LICENSE): you may read and use this software for noncommercial purposes only. Modifying it, creating derivative works, redistributing it and any commercial use are not permitted without a separate written license. This software is not open source.
