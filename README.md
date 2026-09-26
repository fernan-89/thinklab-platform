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

Every service depends on MongoDB and on the Hash Token Registry (sovereign identity). The four
consumers probe the registry's `/health/liveness` as part of their readiness.

## Run the stack

### With Docker

```bash
docker compose up --build
```

Expects the service repositories as siblings of this one (`../micronaut-*-service`).

### Without Docker (portable tools)

`scripts/e2e` runs the same stack with a portable MongoDB and the services' `installDist` output,
and needs no installation or admin rights. Place the portable tools under `<workspace>/tools`:
`mongodb/` (MongoDB Community zip), `node/` (Node.js zip) and `newman/` (`npm install newman`).

```powershell
powershell -File scripts\e2e\start-local-stack.ps1 -Build   # builds every service, starts Mongo + 5 services
powershell -File scripts\e2e\run-e2e.ps1                    # runs the five Postman suites with newman
powershell -File scripts\e2e\stop-local-stack.ps1           # -IncludeMongo to stop MongoDB too
```

The E2E runner executes the suites in dependency order and threads the `organisationId` created by
the Party Reference Data Directory suite into the others (they scope every call to that tenant).
JUnit XML and the console output of each suite land in `.e2e/reports/`.

## Quality gates

* Every service: `./gradlew check` (tests + JaCoCo floor, 60% line / 40% branch) — see each repo's CI.
* Workspace: `scripts/audit-compliance.ps1` (naming, docs, ADRs, Postman, formatting, git hygiene).
* Platform: the E2E suites above; they found real defects the unit tests could not (see `docs/e2e-findings.md`).

## License

Licensed under the [PolyForm Strict License 1.0.0](LICENSE): you may read and use this software for noncommercial purposes only. Modifying it, creating derivative works, redistributing it and any commercial use are not permitted without a separate written license. This software is not open source.
