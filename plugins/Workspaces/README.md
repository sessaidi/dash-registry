# Workspaces

Fubo backend workspaces on GKE, linked to your worktrees. Dash creates a workspace, builds
and deploys your code into it, applies configuration changes, shows its logs and diagnoses
its problems. It does all of this natively, through the GKE, Kubernetes, Cloud Logging,
Cloud Monitoring and Docker Engine APIs. You don't need up-toolbox or kubectl, but every
action shows the command that does the same thing.

| | |
|---|---|
| Plugin id | `workspaces` |
| Version | 2.1.0 |
| Minimum DashKit | 1.3.0 |
| Layer | feature |
| Requires | `gcp`, `kubernetes`, `docker`, `github`, `agents` |

## What each requirement is for

- **Google Cloud** (`gcp`): credentials, Cloud Logging (`gcp_logs_query`), Cloud Monitoring
  (`gcp_metrics_query`), and the token used to push to Artifact Registry.
- **Kubernetes**: the kubeconfig contexts (`gke_<project>_<location>_<cluster>`) that the
  replay commands use.
- **Docker**: image builds and pushes through the Docker Engine socket.
- **GitHub**: checks whether the PR of a workspace's branch was merged, so the workspace
  can be removed.
- **Agents**: the worktrees, at `~/Codes/<project>/.worktrees/<branch>`.

## Lifecycle

| Dash | up-toolbox equivalent |
|---|---|
| **New Workspace** (profile + worktree) | `workspace generate --services …` then `workspace up` |
| **Deploy Worktree** | `workspace run` (go test, go build, docker build/push, patch, wait) |
| **Config › Apply** | edit the generated files, then `kubectl diff/apply -k` |
| Persist, Delete, Clean | `toggle-persist`, `down`, `clean` |

- **Generate:** Dash reproduces up-toolbox's generate. The rules were taken from its source:
  - It copies the services from `default` on the source cluster.
  - It rewrites them: one replica, the `workspaces-cost-optimized` compute class, fixed
    resources (papi 8G, others 2G), and env rewrites (`BASE_URL`, `BUILD_SOURCE`, data
    sources).
  - It rewrites `services_config*.json` and the rate-limit hosts in the TOML files.
  - CAPIG gets its varnish sidecar, ConfigMap, HTTPRoute and HealthCheckPolicy.
- **Local configuration:** the files go in the linked worktree as
  `<name>-<env>[-<region>]/`, with the same layout as up-toolbox. A `.gitignore`
  containing `*` keeps them out of git. To apply them yourself:
  `kubectl create -f namespace.yaml && kubectl create -k .`
- **Profiles:** sets of services, editable in Settings:
  - `default`: capig, papi
  - `signup`: capig, papi, services-signup, services-user
  - `privacy`: capig, papi, services-user-privacy
  - `vapi`: capig, papi, vapi
- **Deploy:**
  - The image is `<registry>/<app>:<branch>-<sha>`.
  - The registry is `us-east4-docker.pkg.dev/<project>/backend-workspaces`, or
    `europe-west1-…/backend-workspaces-eu`.
  - Git details go on the namespace (`git_hash`, `git_branch`, `git_tag`, `git_dirty`)
    plus `dash_repo`, then the workspace waits for the rollout.
- **Merged PRs:** once the PR of the branch deployed to one of your workspaces is merged,
  Dash deletes that workspace. Persisted workspaces are kept. You can turn this off in
  Settings.

## Logs and diagnosis

- **Logs:** per pod and container, with timestamps, follow, filter, errors only, and the
  run before the last restart. **Explain** has Claude explain the visible lines and quote
  the ones that matter.
- **Cloud Logs:** Cloud Logging for the namespace, including pods that are gone. Filter
  by severity, text and time.
- **Diagnose:** rule-based findings, each with a reference and the verbatim evidence:
  OOMKilled, evictions (ephemeral storage or memory), scheduling, image pulls, missing
  config, failing probes, node pressure. It also lists the containers with usage
  against their limits, and recent events.
- **Workspace doctor** (agent, read-only):
  - It combines Kubernetes status, the logs before a restart, Cloud Logging and Cloud
    Monitoring (memory, CPU and storage against limits over time) to find the root cause.
  - Each finding gives references and the exact log lines.
  - Runs: on demand, after deploys and configuration changes, and every 30 minutes when
    enabled. A precheck skips the run while your workspaces are healthy.
- **Commands:** every action, each with two commands:
  - the **exact** one, which returns the same bytes: `kubectl get --raw '<path>'` for
    reads, `kubectl proxy` plus `curl` for writes, and `curl` with
    `gcloud auth application-default print-access-token` for Google APIs;
  - the **usual** one: `kubectl logs …`, `gcloud logging read …`, `up-toolbox …`.

## What it stores

- `WorkspaceRecord` (one per workspace and environment):
  - URL, region and environment, owner, health (healthy, degraded, failing, deleted);
  - persist flag, node pool, branch, commit, repository, linked worktree;
  - what runs (`app=tag`), and the last change and when it happened.
- `WorkspaceDeployment`: the deployment train. Each entry is a creation, a worktree
  deploy, an image or a configuration change, with app, tag, branch, commit, who, when,
  duration, result and error.

## Widgets

| Kind | Shows |
|---|---|
| `workspaces.list` | Your workspaces, plus **New Workspace**. Opening one shows Overview, Train, Logs, Cloud Logs, Diagnose, Config and Commands. |
| `workspaces.train` | The deployment train for all workspaces or one, mine or everyone's. |

The activity series `workspaces.deploys` counts deployments per day. Each workspace is also
a knowledge-graph entity, linked to its repository and owner.

## Claude tools

| Tool | Approval |
|---|---|
| `workspaces_list`, `workspace_status`, `workspaces_clean_candidates`, `workspace_profiles`, `workspace_config_changes`, `workspace_diagnose`, `workspace_logs`, `workspace_cloud_logs`, `workspace_commands` | No (read-only) |
| `workspace_create`, `workspace_deploy_worktree`, `workspace_apply_config`, `workspace_deploy_image`, `workspace_set_persist` | Yes |
| `workspace_delete` | Dash dialog |

Events: `workspace.created`, `workspace.deployed`, `workspace.configured`,
`workspace.deleted`, `workspace.cleaned`.

## Build & test

```sh
TEST=1 scripts/build-plugins.sh Workspaces   # writes dist/workspaces-2.1.0.dashplugin.zip
```
