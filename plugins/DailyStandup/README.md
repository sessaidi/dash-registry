# Daily Standup

Your daily standup, every working day:
- **Your update:** what you did since the last standup, what you'll do today, and your
  blockers, written the way you'd say them. Each item starts with its ticket key.
- **Blockers:** carried from day to day until you mark them resolved.
- **Zoom days:** on the days the standup is on Zoom, the meeting is followed live and
  reported when it ends.

| | |
|---|---|
| Plugin id | `daily-standup` |
| Version | 1.0.0 |
| Minimum DashKit | 1.2.0 |
| Layer | feature |
| Requires | `zoom` |
| Uses when installed | `pull-requests`, `jira-board`, `agents`, `workspaces`, Notes, Knowledge |

## Your update, every working day

The update is prepared before the standup (20 minutes before by default), or whenever you
press **Prepare Now**. It is built from what Dash already stored since the previous working
day; it never calls GitHub or Jira itself:
- your commits in the clones under the code folder (`~/Codes`), all branches;
- your PRs and the reviews requested from you, with their feedback;
- the tickets you follow and their statuses;
- agent sessions, your workspaces, notes you edited, meetings;
- Dash's recent activity, and blockers still open.

| Section | What goes in it |
|---|---|
| **Yesterday I did** | What you did, by ticket: `LAF-5680 — finished the renewal endpoint and its tests (a1b2c3d, api#88)` |
| **Today I will** | Each next step, by ticket, with its kind (see below). |
| **Blockers** | What stops you, by ticket. Each one is remembered until you resolve it. |

Kinds of next step:

| Kind | Meaning |
|---|---|
| **Fix** | What broke or was flagged: changes requested, a failing workspace or agent, failing tests. |
| **Continue** | Work in progress. |
| **Waiting** | Waiting for a review or for someone. |
| **Review** | A PR someone asked you to review. |
| **Start** | The next ticket: the highest-priority followed ticket not started yet. |

**Copy** puts the update on the clipboard, ready for Slack.

## Zoom days

In Settings, pick which working days the standup is on Zoom.

**How the standup meeting is recognised:** on a Zoom day, a meeting that started within
45 minutes of the standup time, or whose title contains one of your keywords.

- **Live:** who has spoken, in order and how much, who is speaking now, who hasn't been
  heard yet, and "You're up soon".
  - Names come from Zoom's captions, through the Zoom plugin. Turn on captions or the live
    transcript in Zoom.
  - Without captions, only your own lines carry a name.
- **When it ends:** a report with each person's update, all blockers (with their owner),
  action items, and who didn't speak.
  - It is saved to your notes under `Standups/`.
  - Its blockers are added to the blocker list.
  - When captions were off, Claude attributes the lines from the conversation, and the
    report says so.

## What it stores

- `StandupDay`: one per day, with your update and what it was built from, the meeting
  report, and the path of the note.
- `StandupBlocker`: text, owner, reference, open since, last mentioned, resolved.

## Widget, tools, events

- **Widget:** `daily-standup`, with three tabs: Me, Meeting and Blockers.
- **Claude tools:** `standup_today`, `standup_prepare`, `standup_blockers`,
  `standup_history`.
- **Events:** `standup.prepared`, `standup.reported`.
- **Home suggestion:** before the standup, "Your update is ready", or "Prepare your
  update".
- **Activity series:** `daily-standup.blockers`.

## Build & test

```sh
TEST=1 scripts/build-plugins.sh DailyStandup   # writes dist/daily-standup-1.0.0.dashplugin.zip
```
