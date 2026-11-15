# GitLab

Connects Dash to gitlab.com or a self-managed GitLab instance with a personal access token,
and keeps a list of the projects you watch. Claude can list open merge requests and read any
GitLab REST v4 endpoint. Features reach GitLab through this integration's connection.

| | |
|---|---|
| Plugin id | `gitlab` |
| Version | 1.1.0 |
| Minimum DashKit | 1.0.0 |
| Layer | integration (provides `gitlab`) |
| Requires | nothing |

## Setup

Prerequisite: a GitLab personal access token. The `read_api` scope is enough to read. A
feature that comments or approves needs the `api` scope.

Settings › GitLab:

- **Instance**: defaults to `https://gitlab.com`. It must be `https`.
- **Personal access token**: stored in the Keychain.
- **Check**: calls `GET /user`. The status shows your username.
- **Watched projects**: `group/project` paths (subgroups allowed), one per line.
- **Features using this integration**: lists the installed features that require or
  optionally use `gitlab`.

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `gitlab_merge_requests` | Lists open merge requests on one project, or on every watched project by default. Without a project, `scope` (`assigned_to_me`, `created_by_me`, `all`) lists them across the instance. Each result has the project, title, author, draft flag, update time, URL and pipeline status. | No |
| `gitlab_api_get` | GETs any REST v4 path, for example `/projects/group%2Fservice/pipelines?per_page=5`. Responses longer than 100,000 characters are truncated. | No |

## For feature authors

The connection points at `<instance>/api/v4` and sends the `PRIVATE-TOKEN` header. The
integration exports nothing.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (each `project.yml` says where it expects DashKit).

```sh
TEST=1 scripts/build-plugins.sh GitLab   # generate the project, run GitLabPluginTests, build, zip
scripts/build-plugins.sh GitLab          # build and zip without the tests
```

The script writes `dist/gitlab-1.1.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GitLab/Build/Products/Release/GitLabPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
