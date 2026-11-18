# Kubernetes

Reads your kubeconfig in-process and gives Dash features read-only access to one cluster context
at a time. Its fetchers store what the cluster answers in Dash, and Dashii reads it from there. No
`kubectl` and no credential plugins run. The bundle holds two extensions:

- the **Kubernetes** integration: the cluster connection, its fetchers and Dashii's readers;
- the **Pods** feature: a widget of the pods in your namespace, refreshed every 30 seconds,
  with an alert when a pod starts crash-looping.

| | |
|---|---|
| Plugin id | `kubernetes` |
| Version | 1.1.0 |
| Minimum DashKit | 1.3.0 |
| Layer | integration `kubernetes` + feature `kubernetes-pods` (requires `kubernetes`) |
| Requires | nothing |
| Optional | `gcp` (Google Cloud), for contexts that use `gke-gcloud-auth-plugin` |

## Setup

Prerequisite: a kubeconfig. Dash reads the first file in `$KUBECONFIG`, else `~/.kube/config`.
These authentication methods work:

- bearer tokens
- token files
- basic auth
- client certificates (RSA or ECDSA)
- `gke-gcloud-auth-plugin` contexts, which get their token from the Google Cloud integration
  (install and connect it)

Other exec plugins, such as the aws plugin or kubelogin, are not supported. TLS trusts the
cluster CA from the kubeconfig, or the system roots when there is none. If a context sets
`insecure-skip-tls-verify`, Settings shows a warning.

Settings › Kubernetes:

- **kubeconfig**: the file in use (read-only).
- **Context**: defaults to the kubeconfig's `current-context`. You can pick any other context.
- **Namespace**: overrides the context's namespace. Empty uses the context's namespace, else
  `default`.
- **Server**, **Authentication**, **Trust**: what Dash resolved for the context.
- **Reload kubeconfig** re-reads the file. **Check** calls `GET /version`.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `kubernetes.pods` (Pods) | The pods of the configured namespace, with ready containers, node, kubectl-style status and a restart count. Default size: medium. | **Only pods with problems** (`problemsOnly`, default off) hides pods that are running and ready, or completed. |

## Fetch, then read

Dashii and agents never call the cluster. They read what Dash has stored. When it's missing or
stale, they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher
calls the current context and stores a sanitized answer (at most 200 KB) in Dash's database, per
context, then returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each reader has
the old tool's name and input. It returns the stored answer with `synced_at`, `stale` and
`refresh` (the `data_fetch` call that refreshes it). If nothing is stored yet, it returns
`{"fetched": false, "hint", "refresh"}`. Without a namespace, the one from Settings is used (and
stored with the answer). Answers to queries are kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `k8s.pods` | `k8s_list_pods` | Pods with phase, kubectl-style status, ready containers, restarts and node; `all` for every namespace; label and field selectors; at most 500 | 1 min |
| `k8s.namespaces` | `k8s_namespaces` | Namespaces with status and labels | 1 hour |
| `k8s.list` | `k8s_list` | Objects of a kind (kubectl get), a compact line each; Secrets show keys only | 5 min |
| `k8s.describe` | `k8s_describe` | One object with its events; Secret values removed | 5 min |
| `k8s.logs` | `k8s_logs` | A pod's logs: container, previous run, last lines or seconds | 2 min |
| `k8s.events` | `k8s_events` | Events, newest first; warnings only by default | 2 min |
| `k8s.top_pods` | `k8s_top_pods` | CPU and memory per container (needs metrics-server) | 1 min |
| `k8s.rollout_status` | `k8s_rollout_status` | Whether a deployment's rollout finished | 1 min |
| `k8s.api` | `k8s_api_read` | Any API path, GET only: refuses `exec`, `attach`, `portforward`, `proxy`, and `watch`/`follow` queries; text cut at 100,000 characters | 5 min |

`k8s_contexts` reads the kubeconfig (no request). DashQL datasets: `k8s_events` and `k8s_objects`,
the fetched rows with `context`, `synced_at` and `stale`; `pods` is the Pods feature's.

`k8s_rollout_restart` and `k8s_scale` change a cluster: the user approves each call, and Dashii
and agents never get them.

## Events

| Kind | When |
|---|---|
| `pod.crashloop` | A pod in the watched namespace entered CrashLoopBackOff. Each episode is reported once. |

## For feature authors

The connection points at the current context's server and uses a `session` that trusts its CA.
Auth comes from headers or `sign`. Exports: `contexts`, `currentContext`, `namespace`, `server`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Kubernetes   # generate the project, run KubernetesPluginTests, build, zip
scripts/build-plugins.sh Kubernetes          # build and zip without the tests
```

The script writes `dist/kubernetes-1.1.0.dashplugin.zip` and regenerates `registry.json`. To
try a build in a running Dash, copy
`build/Kubernetes/Build/Products/Release/KubernetesPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
