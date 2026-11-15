# Kubernetes

Reads your kubeconfig in-process and gives Claude and Dash features read-only access to one
cluster context at a time. No `kubectl` and no credential plugins run. The bundle holds two
extensions:

- the **Kubernetes** integration: the cluster connection and read-only Claude tools;
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

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `k8s_get` | GETs any API path on the current context, for example `/api/v1/namespaces/default/pods` or a pod's `log?tailLines=100`. It refuses `exec`, `attach`, `portforward`, `proxy`, and `watch`/`follow` queries. Responses longer than 100,000 characters are truncated. | No |
| `k8s_list_pods` | Lists pods with phase, kubectl-style status (CrashLoopBackOff, ImagePullBackOff…), ready containers, restarts and node. Uses the configured namespace by default; `all` lists every namespace. Accepts label and field selectors and returns at most 500 pods. | No |

## Events

| Kind | When |
|---|---|
| `pod.crashloop` | A pod in the watched namespace entered CrashLoopBackOff. Each episode is reported once. |

## For feature authors

The connection points at the current context's server and uses a `session` that trusts its CA.
Auth comes from headers or `sign`. Exports: `contexts`, `currentContext`, `namespace`, `server`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and the Dash repository at `~/code/perso/dash`.

```sh
TEST=1 scripts/build-plugins.sh Kubernetes   # generate the project, run KubernetesPluginTests, build, zip
scripts/build-plugins.sh Kubernetes          # build and zip without the tests
```

The script writes `dist/kubernetes-1.1.0.dashplugin.zip` and regenerates `registry.json`. To
try a build in a running Dash, copy
`build/Kubernetes/Build/Products/Release/KubernetesPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
