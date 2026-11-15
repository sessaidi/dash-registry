# Atlassian

Connects Dash to an Atlassian Cloud site (Jira and Confluence) with one email and API
token. Features such as Jira Board and Agents reach Jira through this integration and never
see the token. Claude gets tools to search and read Confluence pages and to list your open
Jira issues. Install it if your team uses Jira or Confluence Cloud.

| | |
|---|---|
| Plugin id | `atlassian` |
| Version | 1.1.0 |
| Minimum DashKit | 1.0.0 |
| Layer | integration (provides `atlassian`) |
| Requires | nothing |

## Setup

Prerequisite: an Atlassian API token, created at
<https://id.atlassian.com/manage-profile/security/api-tokens>. The same token is used for Jira
and Confluence.

Settings › Atlassian:

- **Site**: your site URL, for example `https://your-team.atlassian.net`. It must be `https`.
- **Email**: the account email.
- **API token**: stored in the Keychain.
- **Check**: calls `/rest/api/3/myself`. The status shows the account's display name.

Sites and emails saved by earlier Dash builds under the old `jira.*` keys are picked up, and so
is the old Keychain token.

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `confluence_search` | Searches Confluence pages by text (CQL `siteSearch`), optionally limited to one space. Returns up to 15 results with id, title, space, excerpt and URL. | No |
| `confluence_get_page` | Returns a page's title, space, version and text, by page id. Text over 60,000 characters is truncated. | No |
| `jira_myself_issues` | Lists up to 50 open Jira issues assigned to you (not Done), most recently updated first, with key, summary, status and URL. | No |

## For feature authors

The connection points at the site and sends `Authorization: Basic base64(email:token)` and
`Accept: application/json`. Exports: `site`, `email`, `accountName`.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Atlassian   # generate the project, run AtlassianPluginTests, build, zip
scripts/build-plugins.sh Atlassian          # build and zip without the tests
```

The script writes `dist/atlassian-1.1.0.dashplugin.zip` and regenerates `registry.json`. To
try a build in a running Dash, copy
`build/Atlassian/Build/Products/Release/AtlassianPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
