# E2E findings — first live run (2026-09-21)

**Result after the fixes: all five Postman suites pass against the live stack (0 failed assertions).**

The five services were run for the first time together against a real MongoDB with the five Postman
suites (newman). The lifecycle scenarios, state machines, collision detection, 404/409/422 paths and
audit ledger all behaved as specified. The run also exposed defects that 518 passing unit tests could
not see. Each one now has a regression test.

| # | Finding | Impact | Fix | Regression guard |
|---|---|---|---|---|
| 1 | The dependency probe in `warmup.endpoints` did a `GET` on the bare Hash Token Registry base URL, which answers **404** | every consumer reported readiness DOWN (HTTP 503); in Kubernetes the pods would never become ready | probe `/health/liveness` | `WarmupEndpointsConfigTest` (4 services) |
| 2 | Micronaut's built-in `ConstraintExceptionHandler` is more specific than the catch-all `ExceptionHandler<Throwable>` | a body that failed `@Valid` returned Micronaut's envelope with **no `error_code`**; the RFC 7807 validation branch was unreachable over HTTP | `ValidationExceptionHandler` (`@Replaces` the built-in) delegating to `GlobalExceptionHandler` | `ValidationProblemContractTest` (5 services, real HTTP) |
| 3 | A malformed `X-Tenant-Id` on a collection `retrieve` returned **500**. `Flux` routes are *streamed* by Micronaut, so an error raised while subscribing escapes the exception handlers (a `Flux.defer` alone does not help) | malformed tenant header on the list endpoints = HTTP 500 | the four list endpoints return `Mono<List<T>>` (still a JSON array) so errors are handled before the response is committed | `ValidationProblemContractTest` (real HTTP, asset/op-window/party-auth) + controller tests + Postman negative |
| 4 | `/prometheus` and `/metrics` were enabled in config but no Micrometer registry was on the classpath | endpoints returned an error document; the documented observability did not exist | added `micronaut-micrometer-core` + `micronaut-micrometer-registry-prometheus` | Postman infra folder (`jvm_memory` in the scrape) |
| 5 | Hash request DTOs threw from their compact constructors (`requireNonNull`, blank check) during deserialisation | `{}` or a blank payload returned **500** instead of a 400 validation problem | removed the constructor guards; `@NotBlank`/`@NotNull` already enforce them | `ValidationProblemContractTest` (hash) |
| 6 | Infra assertions in the Postman suites assumed `/health/liveness` = `UP` and `/swagger-ui` = 200 | false failures | liveness accepts `UP` or `UNKNOWN`; Swagger is `/swagger-ui/index.html` | suites regenerated |

Test-suite hardening found on the way: `@MicronautTest` classes bound the fixed port 8080 and collided
with a running stack, so every `application-test.yml` now sets `micronaut.server.port: -1`.

## How to reproduce

```powershell
powershell -File scripts\e2e\start-local-stack.ps1 -Build
powershell -File scripts\e2e\run-e2e.ps1
```
