# ADR-001 (platform): The Promises Contract

## Status
Accepted (2026-10-20, approved by the owner). Phase 1.1 of `docs/ACTION-PLAN.md`.

## Context
The alerting service turns what the registries judge into one alert and one incident. Until now it knew each registry: a client, a DTO of that registry's fields and a mapping of its verdicts, for nine sources (backup, patch, capacity, vendor, licence, DR, cloud inventory, procurement, and the health checks). Every new registry meant changes in five places, and the same problem (a reader that must see what *recovered*, not only what is wrong) was solved case by case (`presence=MISSING`, `changedWithinDays`).

## Decision
Every registry whose state can be a **promise kept or broken** exposes one standard route, under its own BIAN path:

```
GET /<domain>/v1/promises/retrieve?changedWithinDays=<1..365, default 30>&limit=<1..1000, default 500>
X-Tenant-Id (mandatory) · X-Executor, X-Role (as everywhere; a REQUESTER is refused with 403)

200 [ { "id": uuid, "name": string, "assetId": uuid|null,
        "verdict": "KEPT" | "BROKEN" | "NOT_JUDGED",
        "code": string|null, "status": string, "changedAt": instant } ]
```

- **`verdict`** is judged when read (as ever): `BROKEN` is a promise not being kept, `KEPT` one that is, `NOT_JUDGED` one the registry cannot judge yet (no data, paused, not placed).
- **`code`** is a **fixed code** of the registry's own vocabulary (`PATCH_OVERDUE`, `PURCHASE_ORDER_LATE`...), present **only** when the verdict is `BROKEN`. Never a value, a name of a person, a vendor, an item or free text.
- **`name`** is what the registry already treats as an identifier (a policy name, a contract reference, a product, a PO reference). **`status`** is the registry's own (`ACTIVE`, `PAUSED`, `CANCELLED`...); only `ACTIVE` can open an alert, so a registry that wants a promise settled without ever opening one (a terminated resource, a cancelled order) reports its verdict `KEPT` with another status.
- **What is returned:** every `BROKEN` promise (at most `limit`) **and** every promise whose `changedAt` is within `changedWithinDays` (at most `limit`), each once, broken first. A promise that recovers has changed (a report, a receipt, a renewal, an exercise), so it is in the second set: the consumer sees both what is wrong and what was settled since, with no two-read workaround and with the filtering done **in the registry, where the store can do it**, not after a cap.
- **`changedAt`** is the last moment the promise or the facts it is judged on changed (an update, a report, a receipt, an exercise). Time passing alone changes no `changedAt`; a promise that *becomes* broken by time is returned as `BROKEN` regardless.
- The route is read-only, staff only, tenant-scoped, and adds no vocabulary the registry did not already have.

The alerting service reads a source through this route only: a source is its name, the noun used in the incident, the default class (ADR-040), and where the registry is. Verdicts map to the alert's health: `BROKEN` is DOWN, `KEPT` is UP, `NOT_JUDGED` is not judged; `code` is the alert's error code.

## Migration (strangler)
One registry per pull request, each adding the route with its tests, an entry in its Postman suite and its README. Alerting keeps reading the registries that have not migrated through their old clients and the ones that have through the contract; the old adapters are deleted when the last registry has moved. The health checks stay as they are (they are measured by the health monitor, not judged by a registry).

## Consequences
- Positive: a new source of alerts is a registry that implements one route plus a line of configuration; the consumer needs no knowledge of a registry's fields; the same contract serves a promises screen in the web app and, later, the MCP server and the Terraform provider.
- Negative: nine registries change; each judgement rule that lived in alerting (which verdict is a broken promise, and its code) moves into its registry, where it belongs and where it is tested with the rest of the domain. Until `changedAt` exists in a registry it is its `updatedAt`.
- A recovery that happens only by time passing and changes nothing (rare: none found among the nine) would be seen only while the promise is still returned; the owner of such a registry must move its `changedAt` when that happens.
