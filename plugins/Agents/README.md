# Agents

Runs Claude Code agents on Jira tickets. Each agent works in its own git worktree and branch.
It first proposes a test-first plan in read-only plan mode. Once you approve the plan, it
implements it with an extreme TDD loop: one failing test, minimum code, refactor, commit. When
you are happy with the branch, Dash pushes it and opens a draft PR. The agent itself can never
push. It is meant for engineers who want to hand a ticket to an agent and stay in the loop.

| | |
|---|---|
| Plugin id | `agents` |
| Version | 1.2.0 |
| Minimum DashKit | 1.3.0 |
| Layer | feature (provides `agents`) |
| Requires | `atlassian` (to read the ticket) |
| Optional | `github` (only for Create PR) |

## Setup

Prerequisites:

- The `claude` CLI (Claude Code), signed in. Agents use your Claude Code login, and
  `ANTHROPIC_API_KEY` is removed from the agent's environment.
- `git`, and a local clone of each repository you want agents to work in, with an `origin`
  remote. Create PR reads the GitHub `owner/name` from `origin`.
- The Atlassian integration, connected. To open PRs, also the GitHub integration.

Settings › Agents:

- **claude CLI**: path to `claude`. Empty uses Dash's own Claude Code path (Settings › Claude),
  then `PATH`.
- **Model**: a free-text model name. When set, it wins over the AI tab's choice. Empty uses the
  AI tab.
- **Worktrees folder**: default `~/Dash/worktrees`. Worktrees go in
  `<folder>/<repo>/<branch>`.
- **Repositories**: one `PROJECT=/path/to/clone` line per Jira project key, for example
  `LAF=~/code/services-presentation-api`.
- **While implementing**: **Accept edits, pre-approved commands only** (`acceptEdits`, the
  default) or **Bypass all permission checks** (`bypassPermissions`). Planning always runs in
  plan mode.
- **Pre-approved tools**: Claude Code permission rules, separated by spaces. The defaults cover
  common git (status, diff, add, commit, log), make, go, npm, pnpm, yarn, pytest, swift and
  cargo test/build commands. Any other tool call opens an "Allow Once" dialog in Dash.
  `git push` and `gh pr` are always blocked.

When an agent starts, Dash runs `git fetch origin --prune`. It then creates a branch named after
the ticket (for example `laf-1234-add-retry-to-the-fetcher`) from the remote default branch,
and adds a worktree for it.

## What it stores

Sessions are kept in Dash's local SwiftData database. The ticket text is fetched live from Jira
when the agent starts and goes into the prompt; it isn't stored separately.

- `AgentSession`: Jira key and title, repository, worktree and branch, base ref, the Claude
  Code session id (for resuming), phase (`planning` or `implementing`), status (`idle`,
  `running`, `failed`), last error, accumulated cost in USD, PR URL, and timestamps.
- `AgentMessage`: the transcript, one row per message (user, assistant, tool, error or info).

The Claude Code processes don't survive a relaunch. Sessions left running come back as idle
and resume their Claude Code session on the next message.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `agents.sessions` (Agents) | Agent sessions with ticket, title, phase, branch, status and cost. Opening one shows its chat window: follow the transcript, send messages, Implement (approve the plan), Stop, Create PR, and open the worktree in Finder or Terminal. | `showFinished`: include sessions that already have a PR (default on). Set through the widget config; the widget has no settings form. |

Jira Board's ticket sheet has a **Start Agent** button when this feature is installed and
enabled.

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `agents_list` | Lists sessions with ticket, branch, worktree, phase, status, cost, PR URL and error. | No |
| `agents_start` | Starts an agent on a Jira ticket: creates the worktree and branch, then the agent proposes a TDD plan. Takes an optional `repo_path` instead of the project mapping. | Yes |
| `agents_open` | Opens a session's chat window. | No |
| `agents_send` | Sends a message to an idle session. Read the reply with `agents_read`. | Yes |
| `agents_read` | Returns a session's recent transcript (30 messages by default). | No |

## Events

| Kind | When |
|---|---|
| `agent.turn_finished` | An agent finished a turn. The title includes the phase. |
| `agent.stopped` | A turn ended with an error result, for example after Stop. |
| `agent.failed` | An agent failed, for example the process couldn't start or crashed. Critical importance. |
| `agent.pr_opened` | Dash pushed the branch and opened a draft PR. The link is the PR. |

All four are declared in the feature's `events` list, so hooks can pick them.

## Home suggestions

Built from the stored sessions, with no network calls. Sessions that already have a PR are
skipped.

- **Agent on KEY failed** (high): asks Claude to read the last messages and explain how to
  resume.
- **Plan for KEY awaits your approval** (high): the session is idle in planning.
- **Agent on KEY is waiting for you** (normal): the session is idle in implementing. Asks
  Claude whether the work is ready for a PR.
- **Agents spent $N this week** (low): shown when sessions updated in the last 7 days cost $50
  or more. Asks for a breakdown and where a cheaper model would do.

## AI tasks

Configure these in the feature's AI tab.

| Task | Models | Efforts | Templates |
|---|---|---|---|
| `agent`: Coding agent | Opus (default), Fable, Sonnet | high (default), xhigh, max, medium | none |
| `pull-request`: Opening pull requests (on by default; turning it off disables Create PR) | Sonnet, Haiku, Opus | none | **PR title**, default `[{{issue_key}}] {{issue_title}}`. **PR description**, default `Jira: [{{issue_key}}]({{ticket_url}})` followed by `{{summary}}`. Variables: `issue_key`, `issue_title`, `ticket_url`, `summary` (the agent's final message), `branch`, `base`. |

## Knowledge graph and activity

- **Knowledge:** each session becomes `agent:<uuid>`, linked to its ticket (`works_on`) and to the draft PR it opened (`opened`).
- **Activity series:** `agents.worktrees` (worktrees created per day).

## Build & test

From the registry root. You need Xcode, XcodeGen, and the Dash repository at
`~/code/perso/dash`. The project also links `Packages/ClaudeCodeKit` from that repository,
statically.

```sh
TEST=1 scripts/build-plugins.sh Agents   # generate the project, run AgentsPluginTests, build, zip
scripts/build-plugins.sh Agents          # build and zip without the tests
```

The script writes `dist/agents-1.2.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/Agents/Build/Products/Release/AgentsPlugin.dashplugin`
into `~/Library/Application Support/Dash/Plugins`.
