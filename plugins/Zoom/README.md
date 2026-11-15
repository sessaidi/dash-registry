# Zoom

Transcribes your Zoom meetings on your Mac and shows who is in the meeting. When the meeting
ends, Claude can summarise it into a title, a summary, decisions and action items. Zoom's
audio and your microphone are captured with ScreenCaptureKit and transcribed on-device with
SpeechAnalyzer. Participants are read from Zoom's window through Accessibility. No Zoom
account, app or API is involved. The transcript leaves your Mac only when you summarise a
meeting or ask Claude about it.

| | |
|---|---|
| Plugin id | `zoom` |
| Version | 1.2.0 |
| Minimum DashKit | 1.2.0 |
| Layer | feature (provides `zoom`) |
| Requires | nothing |

## Setup

Prerequisites: the Zoom desktop app, and these macOS permissions for Dash. Dash asks for each
one the first time you transcribe.

- **Screen & System Audio Recording**: required to capture Zoom's audio. After granting it,
  quit and reopen Dash.
- **Microphone** (optional): your own lines are labelled with your name. Without it, they mix
  into "Others".
- **Accessibility** (optional): lets Dash read Zoom's meeting window and Participants panel.
  Keep the Participants panel open so the list stays complete.

The on-device speech model for your language is downloaded the first time it is needed.

Settings › Zoom:

- **Your name**: the speaker label for microphone audio. Defaults to your macOS full name.
- **Language**: a locale identifier, for example `en_US`. Defaults to the system locale.
- **Start transcribing when a Zoom meeting starts**: default off.
- **Summarise with Claude when the meeting ends**: default on. The summary runs at low effort.
- **Permissions**: the Accessibility status, and a link to the Screen Recording settings.

Dash checks Zoom every 5 seconds. Recording stops once the meeting window has been gone for two
checks in a row. A meeting with no transcript lines is discarded.

## What it stores

Meetings are kept only in Dash's local SwiftData database. None of this comes from an online
service.

- `MeetingRecord`: title, start and end time, every participant seen, Claude's summary,
  decisions and action items (owner and task).
- `TranscriptSegment`: one transcribed line, with the meeting it belongs to, the speaker (your
  name or "Others") and the time.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `zoom.meeting` (Meeting) | While a meeting runs: the live transcript, participants and a Stop button. Otherwise: recent meetings with their summaries, and a Transcribe button. Opening a meeting lets you summarise it again, ask Claude about it, or delete it. Default size: large. | `recentCount`: how many past meetings to list (default 5). Set through the widget config; the widget has no settings form. |

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `meetings_list` | Lists up to 30 recorded meetings, newest first, with summaries and action items. | No |
| `meeting_transcript` | Returns a meeting's transcript, with lines attributed to you or "Others". Defaults to the current meeting, else the latest. | No |
| `meeting_participants` | Returns who is in the Zoom meeting right now, and whether Dash is recording. | No |
| `meeting_summarize` | Regenerates a meeting's title, summary, decisions and action items from its transcript. | No |

## Events

| Kind | When |
|---|---|
| `meeting.started` | Transcription of a Zoom meeting started. The detail lists the participants. |
| `meeting.ended` | The meeting ended or transcription stopped. |
| `meeting.summarized` | Claude's summary is ready, with counts of decisions and action items. |

## Knowledge graph and activity

- **Knowledge:** each meeting becomes `meeting:<uuid>`, with its summary and decisions as searchable text and its participants (`attended_by`). Ticket keys in them are linked by Dash.
- **Activity series:** `zoom.meetings` (meetings per day) and `zoom.hours` (hours in meetings per day).

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Zoom   # generate the project, run ZoomPluginTests, build, zip
scripts/build-plugins.sh Zoom          # build and zip without the tests
```

The script writes `dist/zoom-1.2.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/Zoom/Build/Products/Release/ZoomPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
