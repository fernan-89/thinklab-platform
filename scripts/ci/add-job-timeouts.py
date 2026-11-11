#!/usr/bin/env python3
"""Adds `timeout-minutes` to every job of a GitHub Actions workflow that has none (the default is 360 minutes).

    python3 scripts/ci/add-job-timeouts.py <workflow.yml> [--minutes 15] [--write]

The edit is text-based so the file keeps its comments, quoting and line endings: one line is inserted after the `runs-on:` line of each job
that has neither `timeout-minutes` nor `uses:` (a reusable-workflow call cannot take one). Without --write it only reports.
Before it writes, it parses the file with PyYAML before and after and refuses unless the data is identical except for the added keys.
Needs PyYAML (pip install pyyaml). Exit code 0 = nothing to do or done, 1 = error.
"""
import re
import sys

import yaml


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    write = "--write" in argv
    minutes = 15
    if "--minutes" in argv:
        minutes = int(argv[argv.index("--minutes") + 1])
        args = [a for a in args if a != str(minutes)]
    if len(args) != 1:
        print(__doc__)
        return 1
    path = args[0]
    raw = open(path, encoding="utf-8", newline="").read()
    eol = "\r\n" if "\r\n" in raw else "\n"
    lines = raw.split(eol)
    before = yaml.safe_load(raw)
    jobs = (before or {}).get("jobs") or {}
    todo = [name for name, job in jobs.items()
            if isinstance(job, dict) and "timeout-minutes" not in job and "uses" not in job and "runs-on" in job]
    if not todo:
        print("nothing to do")
        return 0

    out, in_jobs, current, added = [], False, None, []
    for line in lines:
        out.append(line)
        if re.match(r"^jobs:\s*(#.*)?$", line):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", line) and not line.startswith("#"):
            in_jobs = False
        if not in_jobs:
            continue
        m = re.match(r"^  (['\"]?)([A-Za-z0-9_-]+)\1:\s*(#.*)?$", line)
        if m:
            current = m.group(2)
            continue
        m = re.match(r"^(    )runs-on:", line)
        if m and current in todo and current not in added:
            out.append(f"    timeout-minutes: {minutes}")
            added.append(current)
    if sorted(added) != sorted(todo):
        print(f"ERROR: expected to add to {todo}, added to {added}")
        return 1
    new = eol.join(out)
    after = yaml.safe_load(new)
    expected = yaml.safe_load(raw)
    for name in todo:
        expected["jobs"][name]["timeout-minutes"] = minutes
    if after != expected:
        print("ERROR: the data differs from the original beyond the added keys")
        return 1
    removed = [l for l in lines if l not in out]
    if removed and len(out) - len(lines) != len(added):
        print("ERROR: lines were removed")
        return 1
    print(f"{'wrote' if write else 'would add'} timeout-minutes: {minutes} to: {', '.join(added)}")
    if write:
        open(path, "w", encoding="utf-8", newline="").write(new)
    return 0


sys.exit(main(sys.argv[1:]))
