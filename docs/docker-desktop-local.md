# Docker Desktop on the development machine: containers stuck in "Created"

Three times between 2026-11-11 and 2026-11-14 Docker Desktop stopped starting **new** containers on the Windows development machine: `docker compose up`, `compose run` and Testcontainers left the container in `Created` and never returned, while the containers already running kept working. Restarting Docker Desktop fixed it each time. The CI runners are not affected (they use their own Docker).

## What is known

| | |
|---|---|
| Docker | Desktop with engine 29.9.2, VM kernel `7.0.14-linuxkit` (MongoDB 8.0 runs on it: the SERVER-121912 range ended at 7.0.13) |
| VM | 12 CPUs, 32 GiB, swap 2 GiB, disk 1.5 TB; host has 64 GiB and a terabyte free |
| WSL | the inbox one: `wsl --version` is not recognised (an old build) |
| When it hung | 1) starting a second project after the first had been up for about 40 hours; 2) the Testcontainers helper (`ryuk`) of a Gradle `check`; 3) `compose up --force-recreate` of four services at once |

## What was tried, on 2026-11-17

- 250 `docker run --rm` of a short container in a row: no hang.
- 120 `docker run -d -p 18099:80` followed by `docker rm -f`, reusing the same host port: no hang.

So neither the number of containers created nor reusing a published port is enough. **The cause is not found.** What is left untested is long uptime of the Docker VM (the first hang followed about 40 hours of uptime), and old WSL components.

## What was tried, on 2026-11-22 (Resource Saver)

Docker Desktop stops its VM when idle (Resource Saver) and starts it again on the next command. That stop/start was the leading suspect, so it was timed on the real machine: baseline `docker run --rm` 0.40 s; wait for the idle shutdown (seen after about 5 minutes); first `docker run` after it took **10.8 s** (VM start) and worked; then 6 `docker run` in parallel finished 6 of 6 in 3.1 s. No container stayed in `Created`.

So an idle stop/start costs about 11 s but does **not** reproduce the hang. The Hyper-V log also shows 108 VM creations since 2026-11-07 (many per day when working, gaps up to 64 h) and unclean host reboots (Kernel-Power 41) on 11-04, 11-06, 11-07, 11-14, 11-20, 11-21 and 11-22, so a reboot or sleep of the host is another candidate; nothing in the logs that are left ties either to a hang.

**Still not found.** Not tried: long uptime of the VM (the host was rebooted today), and `wsl --update` (the machine was not changed, because no evidence points to it). If the hang happens again, collect first, as below.
## What to do when it happens

1. Do not restart yet. Collect, in this order: `docker ps -a --format '{{.Names}} {{.Status}}'`, `docker events --since 10m` (a few seconds, Ctrl-C), `docker info`, and the tail of `%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log` (it is rotated at the restart).
2. `docker rm -f` the containers stuck in `Created`, then restart Docker Desktop.
3. Add what was collected to the table above (when it hung, how long Docker had been up).

If it happens again after a long uptime, restarting Docker Desktop once a day before a long session is the cheap rule until the cause is known. Updating WSL (`wsl --update`, or the Microsoft Store version) is the other untested step; it changes the machine, so it is left to the owner.
