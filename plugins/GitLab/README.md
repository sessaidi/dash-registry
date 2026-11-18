# GitLab

Connects Dash to gitlab.com or a self-managed GitLab instance with a personal access token,
and keeps a list of the projects you watch. Its fetchers store open merge requests, any REST v4
answer and release data (tags, commit ranges) in Dash, and Dashii reads them back. Features reach
GitLab through this integration's connection.

| | |
|---|---|
| Plugin id | `gitlab` |
| Version | 1.5.0 |
| Minimum DashKit | 2.4.0 |
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

## Fetch, then read

Dashii and agents never call GitLab. They read what Dash has stored. When it's missing or stale,
they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher calls
GitLab and stores a sanitized answer (at most 200 KB) in Dash's database, per instance, then
returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each reader returns the
stored answer with `synced_at`, `stale` and `refresh` (the `data_fetch` call that refreshes it).
If nothing is stored yet, it returns `{"fetched": false, "hint", "refresh"}`. Raw answers are
kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `gitlab.merge_requests` | `gitlab_merge_requests` | Open merge requests on one `project`, or every watched project; without a project, `scope` (`assigned_to_me`, `created_by_me`, `all`) lists them across the instance. Project, title, author, draft, update time, URL, pipeline status. | 5 min |
| `gitlab.api` | `gitlab_api_read` | Any REST v4 `path` (GET), e.g. `/projects/group%2Fservice/pipelines?per_page=5` | 5 min |
| `gitlab.tags` | `gitlab_tags` | A project's tags (commit, date, subject, on the default branch), newest first | 10 min |
| `gitlab.range` | `gitlab_range` | The commits between two commits or tags (merges left out) | never stale |

`gitlab.api` paths must start with `/` and can't hold a scheme, a host, a `.` or `..` segment or
whitespace. Tags and ranges go to the release mirror Releases reads (`git.tag`, `git.range`,
`git.repo` under `gitlab:<project>`). `gitlab_sync_tags` and `gitlab_sync_compare` do the same for
other extensions; Dashii and agents never get them (`callsService`).

## For feature authors

The connection points at `<instance>/api/v4` and sends the `PRIVATE-TOKEN` header. The
integration exports nothing.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh GitLab   # generate the project, run GitLabPluginTests, build, zip
scripts/build-plugins.sh GitLab          # build and zip without the tests
```

The script writes `dist/gitlab-1.5.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GitLab/Build/Products/Release/GitLabPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
