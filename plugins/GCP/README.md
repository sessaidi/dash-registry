# Google Cloud

Connects Dash to Google Cloud using Application Default Credentials or a service-account key
file. Dash reads the credentials and refreshes OAuth tokens itself over HTTPS, so neither
`gcloud` nor `gke-gcloud-auth-plugin` runs. Every request to `*.googleapis.com` is signed with
a fresh token. Workspaces requires this integration. Kubernetes uses it, when it is present, to
reach GKE contexts. Claude gets read-only access to Google Cloud REST APIs.

| | |
|---|---|
| Plugin id | `gcp` (folder `GCP`) |
| Version | 1.0.0 |
| Minimum DashKit | 1.3.0 |
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

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `gcp_api_get` | GETs any Google Cloud REST URL on `https://*.googleapis.com`, for example GKE clusters or Logging. Responses longer than 100,000 characters are truncated. | No |
| `gcp_list_projects` | Lists the projects you can see, with `projectId`, name and state. Uses the Cloud Resource Manager API. | No |

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

The script writes `dist/gcp-1.0.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GCP/Build/Products/Release/GCPPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
