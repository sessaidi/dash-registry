# Docker

Connects Dash to your local Docker Engine through its unix socket, speaking the Engine API
in-process without the `docker` CLI. The bundle holds two extensions:

- the **Docker** integration: the socket connection, fetchers that store the engine's answers
  in Dash (containers, logs, stats, images, events…) with readers for Dashii and agents, and
  the changes only you make (start, stop, restart, exec, remove, pull, prune);
- the **Containers** feature: a dashboard widget of your containers, refreshed every 15
  seconds, with alerts when a container crashes or turns unhealthy.

It works with Docker Desktop, Colima, OrbStack and Rancher Desktop.

| | |
|---|---|
| Plugin id | `docker` |
| Version | 1.7.0 |
| Minimum DashKit | 2.4.0 |
| Layer | integration `docker` + feature `docker-containers` (requires `docker`) |
| Requires | nothing outside the bundle |

## Setup

Prerequisite: a running Docker engine. With no socket set, Dash uses the first one that
exists among:

- `~/.docker/run/docker.sock`
- `/var/run/docker.sock`
- `~/.colima/default/docker.sock`
- `~/.orbstack/run/docker.sock`
- `~/.rd/docker.sock`

Settings › Docker:

- **Socket**: a socket path. Leave it empty to auto-detect.
- **Detected sockets**: the sockets found, with **Use** to pick one.
- **Check Connection**: calls `GET /version`. The status shows the Docker version and the
  socket.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `docker.containers` (Containers) | Each local container with its image, status and a state or health badge. Unhealthy containers come first, then running, transitional and stopped. | **Show stopped containers** (`showStopped`, default on) |

## Fetch, then read

Dashii and agents never talk to the engine. They read what Dash has stored. When it's missing or
stale, they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher
asks the engine and stores a sanitized answer (at most 200 KB) in Dash's database, per socket,
then returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each reader returns the
stored answer with `synced_at`, `stale` and `refresh` (the `data_fetch` call that refreshes it).
If nothing is stored yet, it returns `{"fetched": false, "hint", "refresh"}`. Answers about one
container, image or time window are kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `docker.containers` | `docker_containers` | Containers (id, name, image, state, status); stopped ones unless `all` is false | 1 min |
| `docker.find_containers` | `docker_find_containers` | Containers by `name`, `image`, `label`, `status` or Compose `project` | 1 min |
| `docker.compose_projects` | `docker_compose_projects` | Compose projects, their services and containers | 1 min |
| `docker.ports` | `docker_ports` | Published ports, host to container | 1 min |
| `docker.inspect` | `docker_inspect` | A container: state, health (last 3 checks), image, command, ports, mounts, labels, restart policy; no environment | 1 min |
| `docker.health` | `docker_health` | A container's health check and its last results | 1 min |
| `docker.top` | `docker_top` | Processes in a container | 1 min |
| `docker.stats` | `docker_stats` | CPU, memory, network, disk I/O and pids of a container, or of every running one | 1 min |
| `docker.env_names` | `docker_env_names` | A container's environment variable names, never values | 1 min |
| `docker.diff` | `docker_diff` | Files a container added, changed or deleted | 1 min |
| `docker.logs` | `docker_logs` | Recent stdout and stderr (`tail`, default 200, at most 5000), the last 50,000 characters | 1 min |
| `docker.logs_search` | `docker_logs_search` | Logs over a window (`since_minutes`, `until_minutes`, `contains`, `stream`) with timestamps | 1 min |
| `docker.events` | `docker_events` | Engine events (`since_minutes`, `container`, `type`), the last 200 | 1 min |
| `docker.info` | `docker_info` | The engine: version, OS, CPUs, memory, container and image counts | 5 min |
| `docker.images` | `docker_images` | Local images (`dangling`, `reference`) | 5 min |
| `docker.volumes` | `docker_volumes` | Volumes and whether a container uses them | 5 min |
| `docker.networks` | `docker_networks` | Networks with their subnets and attached containers | 5 min |
| `docker.disk_usage` | `docker_disk_usage` | Space used by images, containers, volumes and build cache | 15 min |
| `docker.image_inspect` | `docker_image_inspect` | An image: entrypoint, command, ports, environment names, labels, layers | 1 hour |
| `docker.image_history` | `docker_image_history` | How an image was built, newest layer first | 1 hour |

Container ids and image references are checked before anything is stored or sent. DashQL dataset:
`docker_events`, the fetched events with `synced_at` and `stale`.

## Changes

These change the engine, so only you run them: Dash asks first, and Dashii and agents never get
them (`writesRemotely`). The DashQL verbs `container start`, `container stop` and
`container restart` map to `docker_container_action`.

| Tool | What it does |
|---|---|
| `docker_container_action` | Starts, stops or restarts a container. |
| `docker_container_state` | Pauses, unpauses or kills (with a signal) a container. |
| `docker_remove_container` | Removes a container (`force`, `volumes`). |
| `docker_exec` | Runs a command in a running container (no TTY, 60 s). |
| `docker_image_pull` | Pulls an image (up to 10 minutes). |
| `docker_prune` | Removes stopped containers, dangling images, unused networks or build cache; never volumes. |

## Events

| Kind | When |
|---|---|
| `docker.container.exited` | A running container exited with a non-zero code or died, and nobody stopped it on purpose in the last two minutes. |
| `docker.container.unhealthy` | A container's health check turned unhealthy. |
| `docker.container.start`, `docker.container.stop`, `docker.container.restart` | You ran that action through `docker_container_action`. |

## For feature authors

The connection's base URL is `http://docker`, served over the socket by a custom `transport`.
Exports: `socket`, `version`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Docker   # generate the project, run DockerPluginTests, build, zip
scripts/build-plugins.sh Docker          # build and zip without the tests
```

The script writes `dist/docker-1.7.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/Docker/Build/Products/Release/DockerPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
