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
| `scripts/e2e/events-smoke.sh` (`events-smoke.ps1`) | creating a user publishes `user.initiated` through the outbox and NATS, and notification-dispatch delivers the welcome notification |
| `scripts/e2e/hardware-maintenance-smoke.sh` (`hardware-maintenance-smoke.ps1`) | starting a WorkOrder repair moves the Asset into MAINTENANCE and passing quality check moves it back to DEPLOYED, both through NATS |
| `scripts/e2e/ledger-smoke.sh` (`ledger-smoke.ps1`) | the gateway records every mutating request on the compliance ledger and the hash chain verifies, anchoring included |
| `scripts/e2e/anchor-store-smoke.sh` | the write-once anchor store (ledger ADR-035; compose only, needs the LocalStack anchor store + the AWS CLI): the chain head is published to an Object Lock bucket in COMPLIANCE mode, a locked version cannot be deleted, a plain delete (a hidden-by-marker listing) does not hide the anchor from the ledger |
| `scripts/e2e/investigation-smoke.sh` (`investigation-smoke.ps1`) | the pseudonym lookup (gateway ADR-027): a known person's sign-in found by pseudonym, the lookup itself recorded on the ledger with its reason, no email or password anywhere, short/personal-data reasons refused |
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
