# GitHub

Holds your GitHub account (token and API URL) and the list of repositories you watch. Pull
Requests and other GitHub features build on it: they use its authenticated connection and
share its watched-repository list. The Agents feature also uses it, optionally, to open draft
PRs. It works with github.com and with GitHub Enterprise Server.

| | |
|---|---|
| Plugin id | `github` |
| Version | 1.1.0 |
| Minimum DashKit | 1.0.0 |
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

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `github_api_get` | GETs any GitHub REST path under the API root, for example `/repos/owner/name/actions/runs?per_page=10`. The path must be relative, with no `.` or `..` segments and no spaces. Responses longer than 100,000 characters are truncated. | No |

## For feature authors

The connection uses the API URL and sends `Authorization: Bearer`,
`Accept: application/vnd.github+json` and `X-GitHub-Api-Version: 2022-11-28`. Exports: `login`,
`repos` (`["owner/name"]`), `apiURL`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and the Dash repository at `~/code/perso/dash`.

```sh
TEST=1 scripts/build-plugins.sh GitHub   # generate the project, run GitHubPluginTests, build, zip
scripts/build-plugins.sh GitHub          # build and zip without the tests
```

The script writes `dist/github-1.1.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/GitHub/Build/Products/Release/GitHubPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
