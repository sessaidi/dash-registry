# Docker

Connects Dash to your local Docker Engine through its unix socket, speaking the Engine API
in-process without the `docker` CLI. The bundle holds two extensions:

- the **Docker** integration: the socket connection and Claude tools to list, inspect, read
  logs from, and start, stop or restart containers;
- the **Containers** feature: a dashboard widget of your containers, refreshed every 15
  seconds, with alerts when a container crashes or turns unhealthy.

It works with Docker Desktop, Colima, OrbStack and Rancher Desktop.

| | |
|---|---|
| Plugin id | `docker` |
| Version | 1.1.0 |
| Minimum DashKit | 1.3.0 |
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

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `docker_containers` | Lists containers (id, name, image, state, status). Includes stopped containers unless `all` is false. | No |
| `docker_inspect` | Inspects a container: state, health (last 3 checks), image, command, entrypoint, ports, mounts, labels and restart policy. Environment variables are left out. | No |
| `docker_logs` | Returns recent stdout and stderr, 200 lines by default and at most 5000, keeping the last 50,000 characters. | No |
| `docker_container_action` | Starts, stops or restarts a container. | Yes |

## Events

| Kind | When |
|---|---|
| `docker.container.exited` | A running container exited with a non-zero code or died, and nobody stopped it on purpose in the last two minutes. |
| `docker.container.unhealthy` | A container's health check turned unhealthy. |
| `docker.container.start`, `docker.container.stop`, `docker.container.restart` | Claude ran that action through `docker_container_action`. |

## For feature authors

The connection's base URL is `http://docker`, served over the socket by a custom `transport`.
Exports: `socket`, `version`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Docker   # generate the project, run DockerPluginTests, build, zip
scripts/build-plugins.sh Docker          # build and zip without the tests
```

The script writes `dist/docker-1.1.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/Docker/Build/Products/Release/DockerPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
