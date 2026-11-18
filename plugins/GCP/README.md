# Google Cloud

Connects Dash to Google Cloud using Application Default Credentials or a service-account key
file. Dash reads the credentials and refreshes OAuth tokens itself over HTTPS, so neither
`gcloud` nor `gke-gcloud-auth-plugin` runs. Every request to `*.googleapis.com` is signed with
a fresh token. Workspaces requires this integration. Kubernetes uses it, when it is present, to
reach GKE contexts. Its fetchers store logs, metrics and resources in Dash, and Dashii reads them
from there. Nothing here changes Google Cloud.

| | |
|---|---|
| Plugin id | `gcp` (folder `GCP`) |
| Version | 1.5.0 |
| Minimum DashKit | 2.4.0 |
| Layer | integration (provides `gcp`) |
| Requires | nothing |

## Setup

Prerequisite: one of these credential files.

- **Application Default Credentials** (the default). This is the file
  `gcloud auth application-default login` writes once (`authorized_user`). Dash looks for
  `$GOOGLE_APPLICATION_CREDENTIALS`, else `~/.config/gcloud/application_default_credentials.json`.
- **A service-account JSON key** (`service_account`). Dash signs the JWT locally with RS256
  and exchanges it for a token.

Settings › Google Cloud:

- **Credentials**: shows which file is in use.
- **Service Account Key…**: picks a JSON key file.
- **Use Default**: switches back to Application Default Credentials.
- **Check**: gets a token. For user credentials, it also looks up the signed-in email
  (tokeninfo).

Tokens are requested with the `cloud-platform` scope and cached until a minute before they
expire.

## Fetch, then read

Dashii and agents never call Google Cloud. They read what Dash has stored. When it's missing or
stale, they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher
calls Google Cloud and stores a sanitized answer (at most 200 KB) in Dash's database, per
credentials file, then returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each
reader has the old tool's name and input. It returns the stored answer with `synced_at`, `stale`
and `refresh` (the `data_fetch` call that refreshes it). If nothing is stored yet, it returns
`{"fetched": false, "hint", "refresh"}`. Answers to queries are kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `gcp.projects` | `gcp_list_projects` | Projects you can see: `projectId`, name, state | 1 hour |
| `gcp.logs` | `gcp_logs_query` | Cloud Logging entries, newest first (container logs or any filter) | 5 min |
| `gcp.metrics` | `gcp_metrics_query` | Container memory, CPU, restarts, ephemeral storage | 5 min |
| `gcp.audit_logs` | `gcp_audit_logs` | Admin Activity audit logs (who changed what) | 5 min |
| `gcp.gke_clusters` | `gcp_gke_clusters` | GKE clusters with node pools | 15 min |
| `gcp.gke_cluster` | `gcp_gke_cluster` | One GKE cluster in full | 15 min |
| `gcp.cloud_run_services` | `gcp_cloud_run_services` | Cloud Run services | 5 min |
| `gcp.cloud_run_revisions` | `gcp_cloud_run_revisions` | A service's revisions, newest first | 5 min |
| `gcp.pubsub_topics` | `gcp_pubsub_topics` | Pub/Sub topics | 1 hour |
| `gcp.pubsub_subscriptions` | `gcp_pubsub_subscriptions` | Subscriptions, optionally with backlog | 5 min |
| `gcp.sql_instances` | `gcp_sql_instances` | Cloud SQL instances | 15 min |
| `gcp.artifact_repositories` | `gcp_artifact_repositories` | Artifact Registry repositories | 1 hour |
| `gcp.artifact_images` | `gcp_artifact_images` | Docker images of a repository, or one image's tags | 15 min |
| `gcp.secrets` | `gcp_secrets` | Secret Manager names and metadata (never values) | 1 hour |
| `gcp.iam_policy` | `gcp_iam_policy` | Roles and their members | 15 min |
| `gcp.compute_instances` | `gcp_compute_instances` | Compute Engine VMs across zones | 5 min |
| `gcp.cloud_builds` | `gcp_cloud_builds` | Recent Cloud Build builds | 5 min |
| `gcp.error_groups` | `gcp_error_groups` | Error Reporting groups, most frequent first | 5 min |
| `gcp.uptime_checks` | `gcp_uptime_checks` | Uptime checks | 1 hour |
| `gcp.api` | `gcp_api_read` | Any `https://*.googleapis.com` URL, GET only (no `..`, no secret values) | 5 min |

Inputs that go into a URL path (project, location, name…) must be plain names. Relative windows
(`since: 1h`) count from the fetch. Answers over 100,000 characters are cut. DashQL datasets:
`gcp_logs`, `gcp_errors` and `gcp_builds`, the fetched rows with their `project`, `synced_at` and
`stale`. Fetched Pub/Sub topics and subscriptions join the knowledge graph as `topic:gcp:…`
nodes, `same_as` the code's `topic:pubsub:<name>`.

## For feature authors

The connection's base URL is `https://www.googleapis.com` and it allows the hosts
`[".googleapis.com"]`. Its `sign` adds a fresh `Authorization: Bearer` header. Exports:
`account`, `credentialsFile`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh GCP   # generate the project, run GCPPluginTests, build, zip
scripts/build-plugins.sh GCP          # build and zip without the tests
```

The script writes `dist/gcp-1.5.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GCP/Build/Products/Release/GCPPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
