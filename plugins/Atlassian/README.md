# Atlassian

Connects Dash to an Atlassian Cloud site (Jira and Confluence) with one email and API
token. Features such as Jira Board and Agents reach Jira through this integration and never
see the token. Dash fetches Jira issues and Confluence pages into its database when Dashii
needs them, and Dashii reads them there. Install it if your team uses Jira or Confluence Cloud.

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
- **Fetched data is fresh for**: 15 minutes by default. Older data is marked stale and Dashii
  may fetch it again. The section also counts what's stored and can clear it.

Sites and emails saved by earlier Dash builds under the old `jira.*` keys are picked up, and so
is the old Keychain token.

## Fetch, then read

Dashii and agents never call Jira or Confluence. They read what Dash has stored. When it's
missing or stale, they ask the integration to fetch it with `data_fetch`, then read it again.
Each fetcher calls the site and stores a compact, sanitized answer (at most 200 KB) in Dash's
database, per site, then returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`.
Each reader has the old tool's name and input. It returns the stored answer with `synced_at`,
`stale` and `refresh` (the `data_fetch` call that refreshes it). If nothing is stored yet, it
returns `{"fetched": false, "hint", "refresh"}`. Search answers are kept for a day; pages,
issues and lists are kept until you clear them.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What |
|---|---|---|
| `confluence.search` | `confluence_search` | Pages matching some words (CQL `siteSearch`), optionally in one space: id, title, space, excerpt, URL |
| `confluence.page` | `confluence_get_page` | A page by id: title, space, version, labels, breadcrumb, the body as Markdown (cut at 60,000 characters) |
| `confluence.children` | `confluence_page_children` | A page's child pages |
| `confluence.attachments` | `confluence_page_attachments` | A page's attachments (metadata only) |
| `confluence.spaces` | `confluence_spaces` | Spaces |
| `jira.my_issues` | `jira_myself_issues` | Up to 50 open issues assigned to you, most recently updated first |
| `jira.search` | `jira_jql_search` | Issues matching a JQL query (up to 50) |
| `jira.issue` | `jira_issue` | An issue by key: fields, description as text, links, subtasks, latest comments |
| `jira.comments` | `jira_issue_comments` | An issue's comments, newest first |
| `jira.changelog` | `jira_issue_changelog` | An issue's field changes, newest first |
| `jira.projects` | `jira_projects` | Projects with their lead |
| `confluence.pages` | knowledge search (kind `doc`), `from confluence_docs` | Pages that mention some words (a repository, a service), kept for the knowledge graph and linked to the repository. Dash asks for the pages about each of your repositories. |

`atlassian_cached` searches everything stored by text (pages, issues, search hits, lists),
without going online. DashQL datasets: `confluence` (pages, else search hits), `confluence_docs`
and `jira_cache` (issues, else search hits), each row with `synced_at` and `stale`.

Nothing here writes to Jira or Confluence, and no tool needs approval.

## For feature authors

The connection points at the site and sends `Authorization: Basic base64(email:token)` and
`Accept: application/json`. Exports: `site`, `email`, `accountName`. A feature that reads Jira
for Dashii reads through these readers (Jira Board's `jira_get_issue` and `jira_search` do)
rather than calling the site from a tool.

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
