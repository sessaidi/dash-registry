# Pull Requests

Tracks open pull requests on your GitHub repositories and has Claude review them
automatically. Each new PR and each new push gets a structured review: verdict, risk, summary,
testing notes and file/line findings. The feature also watches feedback on your own PRs, so you
know when someone approves, requests changes or comments. From the widget you can comment,
approve, request changes, post Claude's review, re-review or merge. It is meant for engineers
who review and ship PRs every day.

| | |
|---|---|
| Plugin id | `pull-requests` (folder `PullRequests`) |
| Version | 1.17.0 |
| Minimum DashKit | 2.4.0 |
| Layer | feature (provides `pull-requests`) |
| Requires | `github` |

## Setup

Prerequisites:

- The GitHub integration, connected, with its watched repositories set.
- Claude available in Dash, for the reviews.

Settings › Pull Requests:

- **Repositories**
  - Each repository listed by the GitHub integration has a toggle. Unticked repositories are
    excluded and never checked.
  - **Add a repository** (`owner/name`) watches extra repositories that the integration
    doesn't list. Each extra one can be removed.
  - **Check every N min**: 1 to 30. Default: 2.
- **What to follow** (all on by default). PRs outside these choices aren't kept.
  - PRs waiting for my review
  - My PRs
  - Everyone else's PRs
  - Draft PRs
  - Feedback on my PRs (approvals, change requests, comments). Available only while "My PRs"
    is on.
- **Claude reviews**
  - **Review automatically on new PRs and new pushes**: default on.
  - Which PRs get automatic reviews. All are on by default except drafts:
    - PRs waiting for my review
    - My PRs (before reviewers see them)
    - Everyone else's PRs
    - Drafts too (off by default)
  - **Model** and **Effort**: the review task's choices. They are saved in the same place as
    the AI tab, so the two always agree.
  - **Review instructions**: your house rules, appended to the reviewer prompt.
- **Check Now**, and the last check time or error.

## What it stores

PRs and reviews are kept in Dash's local SwiftData database. PRs are fetched from GitHub on
every poll, using ETags so unchanged repositories cost nothing.

- `PullRequest`: one open PR. It holds the repository, number, title, author, body, URL, head
  SHA and branches, draft flag, dates, and whether your review is requested or the PR is yours.
  For your PRs it also holds the approvals and change requests counted from each reviewer's
  latest decision, plus the latest feedback author and time.
- `PRReview`: one Claude review of one head commit. It holds the status (queued, running, done,
  failed), the model, verdict (`approve`, `comment`, `request_changes`), risk, summary, testing
  notes, findings (file, line, severity, title, detail, suggestion), any error, and whether it
  was posted to GitHub.

PRs that are merged or closed, fall outside "what to follow", or belong to repositories you
stop watching are deleted from the database. Reviews interrupted by a quit are queued again at
the next launch. Diffs over 600,000 characters are reviewed partially, and the review says so.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `github.pulls` (Pull Requests) | Open PRs with Claude's verdict and risk. Opening one shows the review. From there you can comment, approve, request changes, post Claude's review as a comment, re-review, ask Claude, or merge (squash, merge commit or rebase). Default size: large. | **Repository** (`repo`, empty for all watched). **Show**: All open (`all`, default), Review requested (`review_requested`), Mine (`mine`). |

The sheet's **Overview** numbers (files, lines, commits, checks, merge state, comments) and its
**Changes** tab come from what the GitHub integration stored (`github.pull`, `github.checks` and
`github.pull_files`). Opening the sheet shows them straight away and fetches them again in the
background when they're missing or stale; "Synced … ago" and its refresh button say how recent
they are. A very large pull request shows the files that fit in the stored copy, and says how
many there are in all.

## Answering reviewers (you only)

The sheet's **Reviews** tab shows the PR's conversation from GitHub: threads on the code (open
first, resolved on request), general comments and reviews. From there you reply to a thread,
resolve or unresolve it, comment, and approve, request changes or comment as a review (started
from your Review with Dashii notes). Each send asks you to confirm: it posts on GitHub as you.

**Improve with Dashii** under any of these suggests clearer wording, checked against the diff and
the thread, with notes on what changed or what looks wrong. You use it or not, and you send it.

None of this is a Dashii tool or a widget action: Dashii and agents can't reply, resolve, approve
or request changes. The GitHub token needs **Pull requests: Read and write** (the token link in
Settings › GitHub asks for it).

## Fetch, then read

Dashii and agents never call GitHub. Open PRs come from the background sync above. A PR's details
and diff are fetched on request: when Dashii's reader says they're missing or stale, it asks
for them with `data_fetch`, then reads them again. Each fetcher calls GitHub and stores a
sanitized answer (at most 200 KB) in Dash's database, then returns a receipt: `{stored, unchanged,
keys, synced_at, read_with}`. Each reader returns the stored answer with `synced_at`, `stale`
(after 10 minutes) and `refresh` (the `data_fetch` call that refreshes it). If nothing is stored
yet, it returns `{"fetched": false, "hint", "refresh"}`.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What |
|---|---|---|
| `github.pr` (repo, number) | `github_get_pr` | Description, state, branches, changed files, human reviews, the last 20 comments. The reader adds the latest Dashii review with its findings, from Dash. |
| `github.pr_diff` (repo, number) | `github_get_diff` | The unified diff. Diffs over 190,000 characters are cut and marked as truncated. |
| `github.branch_pulls` (repo, branch) | `github_branch_pulls` | A branch's pull requests, open, closed or merged. The Agents plugin asks for it to tell whether a worktree's PR was merged; the receipt also lists them in `pulls`. |

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `github_list_prs` | Lists the stored open PRs with their latest Claude review status, verdict and risk, and the last sync time (`synced_at`). Optional repository filter, and `review_requested`, `mine` or `all`. | No |
| `github_get_pr`, `github_get_diff`, `github_branch_pulls` | Readers of the fetchers above. | No |
| `github_rerun_review` | Queues a fresh Claude review of a watched PR's current head commit. | No |
| `pull_request_save_review` | Saves a review Dashii did with you in the chat on the PR, in Dash only: verdict, risk, summary, findings. It shows in the PR's sheet next to the automatic reviews. Nothing is posted to GitHub. | No |
| `github_create_pr` | Opens a PR from a branch that is already pushed. Draft by default; the base defaults to the repository's default branch. Writes to GitHub as you, so Dash never gives it to Dashii or agents. | Yes |

## Events

| Kind | When |
|---|---|
| `pr.opened` | A PR appeared on a watched repository. Notable when your review is requested. |
| `pr.updated` | A PR got new commits. |
| `pr.closed` | A PR was merged or closed. |
| `pr.feedback` | Someone approved, requested changes on, or commented on one of your PRs. Critical for change requests. |
| `review.completed` | Claude finished a review. Critical for high risk or `request_changes`. |
| `review.failed` | Claude's review of a PR failed. |

## Home suggestions

Built from the stored PRs and reviews, with no GitHub calls.

- **PRs waiting for your review** (high, or urgent from 3): asks Claude to rank them using its
  verdicts.
- **Claude flagged your PR** (high for high risk, otherwise normal): your PR's latest review of
  the current head is `request_changes` or high risk.
- **Changes requested on your PR** (high): links the PR and asks Claude to list what to change.
- **Your PR is approved** (normal): approved with no change requests and not a draft. Asks
  Claude to check CI and conflicts before merging.
- **PR reviews failed** (low): offers to rerun them.
- **Your PRs idle for 3+ days** (normal): asks what each one needs to move.

## AI tasks

| Task | Models | Efforts | Templates |
|---|---|---|---|
| `review`: PR review | Opus (default), Sonnet, Fable, Haiku | medium, high (default), xhigh, max | **Extra review instructions** (multiline, empty by default). Variables: `repo`, `author`, `base`. |

## Knowledge graph and activity

- **Knowledge:** each followed PR becomes `pr:owner/name#N`, linked to its repository (`in_repo`), its author (`authored_by`) and the files Claude's review commented on (`touches`). Ticket keys in the title, body or branch are linked by Dash. Claude's verdict and summary are part of the searchable text.
- **Activity series:** `pull-requests.opened` (PRs opened per day, among the open PRs Dash follows; closed PRs are not kept, so history is partial) and `pull-requests.reviews` (Claude reviews per day).

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh PullRequests   # generate the project, run PullRequestsPluginTests, build, zip
scripts/build-plugins.sh PullRequests          # build and zip without the tests
```

The script writes `dist/pull-requests-1.17.0.dashplugin.zip` and regenerates `registry.json`.
To try a build in a running Dash, copy
`build/PullRequests/Build/Products/Release/PullRequestsPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
