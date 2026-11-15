# Jira Board

Shows the Jira tickets you follow in Dash, in your board's columns or by status. Issues are synced from Jira into
Dash's local database. From the widget you can open a ticket to comment on it, move it, ask
Claude about it, or start an agent on it. Claude gets tools to list the cached issues, search
Jira live, follow tickets, comment and transition. It is meant for anyone who works from a Jira
board.

| | |
|---|---|
| Plugin id | `jira-board` (folder `JiraBoard`) |
| Version | 1.13.3 |
| Minimum DashKit | 2.0.0 |
| Layer | feature (provides `jira-board`) |
| Requires | `atlassian` |

## Setup

Prerequisite: the Atlassian integration, connected.

Settings › Jira Board:

- **Boards**: follow several boards. **Find a board** searches the boards you can see by name;
  an empty query lists them all. Each result shows its project and type, with a **Follow**
  button. Followed boards are listed with their id and column count, and each can be
  unfollowed. For each board Dash syncs the active sprint (scrum) or its open issues (kanban).
- **Tickets**: follow individual tickets by key (for example `PROJ-123`). This is local to
  Dash: nothing changes in Jira. Claude can follow tickets for you with `jira_follow`.
- **Query**: **Also follow issues matching (JQL)**. Empty by default, so the widget shows only
  the tickets you follow by hand. For example
  `(assignee = currentUser() OR watcher = currentUser()) AND statusCategory != Done` also follows
  your assigned and watched issues.
- **Refresh every N min**: 1 to 60. Default: 5.
- **Sync Now**, and the last sync time or error.

A single board id saved by an earlier version is carried over as the first followed board.

## What it stores

`JiraIssue` (SwiftData, in Dash's local database) caches every issue fetched from Jira that is
on a followed board, matches the follow JQL, or is followed by key. It holds the key, summary,
status (id, name, category), assignee, priority, type, update time, labels and URL. It also
records whether the issue is on a board, followed, pinned (followed by key), and which followed
boards it is on.

Each sync refreshes these records from Jira and deletes the ones that are no longer on a board
or followed. Board columns are kept in preferences with the followed boards.
`jira_list_issues` and the home suggestions read this cache. `jira_get_issue` and `jira_search`
query Jira live.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `jira.board` (Jira Board) | The issues you follow (by key, or through the follow JQL), in a board's columns or one column per status. Other issues of a followed board are synced but not shown. Opening a ticket shows it like Jira's issue view: comment, reply, react, edit or delete your plain-text comments, run a transition, Ask Claude, or Start Agent (when the Agents feature is enabled). Default size: wide. | **Show**: By status (`mode: "followed"`, default) or In board columns (`"board"`). **Board**: which followed board's columns to use (`board`, a board id; the first board when unset); the picker appears when you follow more than one board. **Hide done** (`hideDone`, default off). |

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `jira_list_issues` | Lists cached issues. `scope` is `board`, `followed` or `all` (default), with an optional status-name filter. | No |
| `jira_follow` | Follows (default) or unfollows a ticket by key in Dash only, then syncs. | No |
| `jira_get_issue` | Fetches one issue live, with its description and recent comments. | No |
| `jira_search` | Runs a JQL search live and returns up to 50 issues (key, summary, status, assignee). | No |
| `jira_add_comment` | Posts a comment on an issue. Blank lines separate paragraphs. | Yes |
| `jira_transition_issue` | Moves an issue through the workflow transition whose name matches, for example "In Progress". | Yes |

## Events

| Kind | When |
|---|---|
| `issue.appeared` | A ticket appeared on a followed board or in the followed list. |
| `issue.status_changed` | A cached ticket changed status. Notable for followed tickets, informational otherwise. |

## Home suggestions

Built from the cached followed issues that aren't done, with no Jira calls.

- **Urgent tickets not started** (urgent): followed issues still in the "new" status category
  with priority Highest, Blocker, Critical, High, P0 or P1. Asks Claude which to pick up first
  and how.
- **Continue KEY / N tickets in progress** (normal, or high when more than 3): asks Claude
  where each stands, or what to finish first.
- **Followed tickets changed today** (low): issues updated in the last 24 hours that aren't in
  progress.

## Knowledge graph and activity

- **Knowledge:** each synced ticket becomes `ticket:KEY`, with its type, status, priority, assignee and labels as searchable text. Commits whose subject mentions the key, PRs and meetings that mention it link to it.
- **Activity series:** `jira-board.updated` (tickets by the day they last changed).

## Build & test

From the registry root. You need Xcode, XcodeGen, and the Dash repository at `~/code/perso/dash`.

```sh
TEST=1 scripts/build-plugins.sh JiraBoard   # generate the project, run JiraBoardPluginTests, build, zip
scripts/build-plugins.sh JiraBoard          # build and zip without the tests
```

The script writes `dist/jira-board-<version>.dashplugin.zip` and regenerates `registry.json`. To
try a build in a running Dash, copy
`build/JiraBoard/Build/Products/Release/JiraBoardPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
