#!/usr/bin/env python3
"""Fails when a service of docker-compose.yml has no Docker healthcheck.

Every service and application of the platform must say, to Docker, whether it is healthy: the Java services (through the busybox of the `tools` volume, against
/health/readiness), the two gateways, the test doubles, the web app and the infrastructure. The only exception is `tools` itself, a one-shot that copies the
busybox and exits with 0 by design.

    python3 scripts/stack/check-compose-health.py              # reads `docker compose ... config --format json` (all profiles)
    python3 scripts/stack/check-compose-health.py --self-test  # also proves the check fails when a healthcheck goes missing

Standard library only; `docker compose config` needs no running daemon.
"""
import copy
import json
import subprocess
import sys

PROFILES = ["sso-test", "ticketing-test", "health-test", "plan-gating", "web"]
EXEMPT = {"tools": "one-shot: copies the busybox into the tools volume and exits with 0"}


def load_config():
    command = ["docker", "compose"]
    for profile in PROFILES:
        command += ["--profile", profile]
    command += ["config", "--format", "json"]
    return json.loads(subprocess.run(command, capture_output=True, text=True, check=True).stdout)["services"]


def is_java(service):
    context = str(service.get("build", {}).get("context", "")).replace("\\", "/")
    return context.rstrip("/").split("/")[-1].startswith("micronaut-")


def problems(services):
    found = []
    for name, service in sorted(services.items()):
        if name in EXEMPT:
            continue
        healthcheck = service.get("healthcheck")
        if not healthcheck or healthcheck.get("disable") or healthcheck.get("test") in (["NONE"], None):
            found.append(f"{name}: no healthcheck")
            continue
        if is_java(service):
            if not str(healthcheck["test"][-1]).endswith("/health/readiness"):
                found.append(f"{name}: the healthcheck of a Java service must ask /health/readiness, it asks {healthcheck['test'][-1]}")
            mounts = [v for v in service.get("volumes", []) if v.get("target") == "/tools"]
            if not mounts or not all(v.get("read_only") for v in mounts):
                found.append(f"{name}: a Java service must mount the tools volume at /tools, read-only (its healthcheck runs the busybox from there)")
    if any(is_java(s) for s in services.values()) and "tools" not in services:
        found.append("tools: the Java services mount the tools volume, but the tools one-shot that fills it is gone")
    return found


def self_test(services):
    """Each mutation of a healthy configuration must be caught; otherwise the check proves nothing."""
    java = sorted(n for n, s in services.items() if is_java(s))
    assert java, "no Java service found: the self-test has nothing to mutate"
    cases = []

    broken = copy.deepcopy(services)
    del broken[java[0]]["healthcheck"]
    cases.append((f"{java[0]} loses its healthcheck", broken))

    broken = copy.deepcopy(services)
    broken[java[1]]["healthcheck"]["test"][-1] = "http://127.0.0.1:8080/health/liveness"
    cases.append((f"{java[1]} asks liveness instead of readiness", broken))

    broken = copy.deepcopy(services)
    broken[java[2]]["volumes"] = []
    cases.append((f"{java[2]} stops mounting /tools", broken))

    for name in ("web", "mock-target", "mongo"):
        if name in services:
            broken = copy.deepcopy(services)
            del broken[name]["healthcheck"]
            cases.append((f"{name} loses its healthcheck", broken))

    broken = copy.deepcopy(services)
    del broken["tools"]
    cases.append(("the tools one-shot is removed", broken))

    failures = 0
    for label, config in cases:
        caught = problems(config)
        print(f"  self-test: {label}: {'caught' if caught else 'NOT CAUGHT'}")
        failures += 0 if caught else 1
    return failures


def main():
    services = load_config()
    found = problems(services)
    java = sum(1 for s in services.values() if is_java(s))
    print(f"{len(services)} services ({java} Java), exempt: {', '.join(sorted(EXEMPT))}")
    for line in found:
        print(f"PROBLEM {line}")
    if found:
        return 1
    print("every service has a healthcheck, and the Java ones ask /health/readiness with the tools volume mounted read-only")
    if "--self-test" in sys.argv:
        if self_test(services):
            print("the self-test found a mutation that the check does not catch")
            return 1
        print("the self-test caught every mutation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
