# GitHub

Holds your GitHub account (token and API URL) and the list of repositories you watch. Pull
Requests and other GitHub features build on it: they use its authenticated connection and
share its watched-repository list. The Agents feature also uses it, optionally, to open draft
PRs. It works with github.com and with GitHub Enterprise Server.

| | |
|---|---|
| Plugin id | `github` |
| Version | 1.8.0 |
| Minimum DashKit | 2.4.0 |
| Layer | integration (provides `github`) |
| Requires | nothing |

## Setup

Prerequisite: a fine-grained personal access token with these permissions on the repositories
you watch:

- Pull requests: read & write
- Contents: read
- Actions: read

Settings › GitHub:

- **Personal access token**: stored in the Keychain.
- **API URL**: defaults to `https://api.github.com`. For GitHub Enterprise Server, use
  `https://<host>/api/v3`.
- **Check**: calls `GET /user`. The status shows your login.
- **Watched repositories**: `owner/name` entries, one per line (commas also work). Every
  GitHub feature uses this list.
- **Fetched data**: how long fetched data stays fresh (15 minutes by default). Older data is
  marked stale and Dashii may fetch it again.

## Fetch, then read

Dashii and agents never call GitHub. They read what Dash has stored. When it's missing or stale,
they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher calls
GitHub and stores a compact, sanitized answer (at most 200 KB) in Dash's database, then returns a
receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each reader has the old tool's name and
input. It returns the stored answer with `synced_at`, `stale` and `refresh` (the `data_fetch` call
that refreshes it). If nothing is stored yet, it returns `{"fetched": false, "hint", "refresh"}`.
Answers to queries (filtered lists, search, raw paths) are kept for a day.

Fetchers send the ETag of GitHub's last answer, so fetching something that didn't change costs no
rate limit. When GitHub says the rate limit is used up, fetches stop until it resets and Dash
keeps showing what it stored. The plugin is built on the
[Ingestor package](https://github.com/sessaidi/dash/tree/main/Packages/Ingestor).

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What |
|---|---|---|
| `github.whoami` | `github_whoami` | The signed-in user and their organizations |
| `github.repo` | `github_repo` | Default branch, visibility, language, topics, open issues, last push |
| `github.branches` | `github_branches` | Branches with their last commit and protection |
| `github.pulls` | `github_pulls` | Pull requests: open, closed or all; by author or base |
| `github.pull` | `github_pull` | One pull request with its description, mergeability, size and comment counts |
| `github.pull_files` | `github_pull_files` | Files a pull request changes (patches on request) |
| `github.pull_reviews` | `github_pull_reviews` | Reviews and line comments |
| `github.checks` | `github_checks` | Check runs and the combined status of a ref |
| `github.workflow_runs` | `github_workflow_runs` | Actions runs, filtered by branch or status |
| `github.run_jobs` | `github_run_jobs` | A run's jobs and their failed steps |
| `github.job_log` | `github_job_log` | The end of a job's log |
| `github.commits` | `github_commits` | Commits by branch, path, author, date |
| `github.compare` | `github_compare` | Two refs: ahead, behind, files |
| `github.file` | `github_file` | A file at a ref |
| `github.issues` | `github_issues` | Issues, without pull requests |
| `github.releases` | `github_releases` | Recent releases |
| `github.search` | `github_search` | Code, issue and repository search |
| `github.notifications` | `github_notifications` | Unread notifications (none marked read) |
| `github.tags` | `github_tags` | Tags with their commit and whether it's on the default branch (the release timeline's mirror) |
| `github.range` | `github_range` | Commits between two commits or tags |
| `github.api` | `github_api_read` | Any REST path (GET only; relative, no `.`/`..`, no spaces) |

DashQL datasets: `github_pulls`, `github_issues`, `github_runs`, `github_releases`. They contain the
fetched rows, one per repository and number, id or tag, each with `repo`, `synced_at` and `stale`.

Fetched pull requests and Actions runs are also kept as typed tables (`GitHubPull`, `GitHubRun`)
in the plugin's own database, `github.store` in Dash's Ingest folder; `github_pulls` and
`github_runs` read them. The stored answers stay the source of truth: the tables follow them
after every fetch, and if the file can't be opened after an update it's made again from them.

Nothing here writes to GitHub, and no tool needs approval.

### For other extensions

These tools call GitHub, so Dash never gives them to Dashii or agents (`callsService`):

| Tool | Used by |
|---|---|
| `github_api_get` | GETs any REST path; answers over 100,000 characters are truncated |
| `github_sync_tags`, `github_sync_compare` | Releases: they fill the `git.tag`, `git.repo` and `git.range` mirror |

## For feature authors

The connection uses the API URL and sends `Authorization: Bearer`,
`Accept: application/vnd.github+json` and `X-GitHub-Api-Version: 2022-11-28`. Exports: `login`,
`repos` (`["owner/name"]`), `apiURL`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh GitHub   # generate the project, run GitHubPluginTests, build, zip
scripts/build-plugins.sh GitHub          # build and zip without the tests
```

The script writes `dist/github-1.8.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GitHub/Build/Products/Release/GitHubPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
