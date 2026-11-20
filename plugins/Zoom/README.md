# Meetings (Zoom)

Transcribes your Zoom meetings on your Mac, tells the voices apart and names them, and shows who
is in the meeting. Shown in Dash as **Meetings**; the plugin id stays `zoom`. Zoom's audio and
your microphone are captured with ScreenCaptureKit and transcribed live on-device with
SpeechAnalyzer. When the meeting ends, the recording is transcribed again with stronger
on-device models, each voice apart (see [Final transcript](#final-transcript)), and Claude
summarises it into a title, a summary, decisions and action items. Participants are read from
Zoom's window through Accessibility. No Zoom account, app or API is involved. The transcript
leaves your Mac only when you summarise a meeting or ask Claude about it; audio and voices never
do.

With the calendar turned on, it also reads your upcoming Zoom meetings from the Mac's
calendars (Google, Outlook or iCloud, as synced to Calendar) through EventKit: an Upcoming
Meetings widget with a Join button, recordings named after their calendar event, and a
reminder event before each meeting.

| | |
|---|---|
| Plugin id | `zoom` |
| Version | 1.10.1 |
| Minimum DashKit | 2.2.0 |
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

The on-device speech model for your language is downloaded the first time it is needed. The
final transcript's models (about 630 MB, from Hugging Face) download once, after Dash asks.

Settings › Meetings:

- **Your name**: the speaker label for microphone audio. Defaults to your macOS full name.
- **Language**: a locale identifier, for example `en_US`. Defaults to the system locale.
- **Start transcribing when a Zoom meeting starts**: default off.
- **Summarise with Claude when the meeting ends**: default on. The summary runs at low effort,
  after the final transcript.
- **Transcribe again when the meeting ends, each voice apart**: default on. Shows whether the
  models are downloaded, how many voices you named, and **Forget All** to delete them.
- **Save the meeting's audio**: default on. When off, the audio goes to a temporary file for the
  final transcript and is deleted right after.
- **Calendar**: off by default. Turning on **Read Zoom meetings from my calendar** asks macOS for
  calendar access once (the prompt is Dash's). **Remind me … min before** (default 2) sets when
  `zoom.meeting_soon` fires.
- **Permissions**: the Accessibility status, and a link to the Screen Recording settings.

Dash checks Zoom every 5 seconds. Recording stops once the meeting window has been gone for two
checks in a row. A meeting with no transcript lines is discarded.

## Final transcript

The live transcript labels everyone in Zoom "Others", and Apple's recogniser drops a quiet
microphone. Once a meeting ends, the recording's two tracks are transcribed again on this Mac:

1. **Transcription**: Parakeet TDT Ultra (25 European languages, detected as it goes, so French
   and English can mix), on the Neural Engine. Your microphone track becomes your lines; a line
   of yours that repeats what Zoom played at the same moment (your microphone hearing your
   speakers) is dropped.
2. **Voices**: pyannote's offline diarization splits Zoom's track into voices ("Speaker 1",
   "Speaker 2"… in the order they first speak), each with a voiceprint.
3. **Names**: a voice matching one you named in an earlier meeting gets that name. Claude's
   summary then guesses unnamed voices from what was said (marked ≈, "guessed"). In the meeting
   sheet, the Transcript tab has a chip per voice: pick a participant or type a name. Naming a
   voice renames its lines and saves its voiceprint so later meetings recognise it.

The live lines are kept (marked `live`) but no longer shown. **Improve Transcript** in a past
meeting's sheet runs the same pass on its recording; **Transcribe Again** runs it once more. A
23-minute meeting takes about 30 seconds on Apple silicon.

## What it stores

Meetings are kept only in Dash's local SwiftData database. None of this comes from an online
service.

- `MeetingRecord`: title, start and end time, every participant seen, Claude's summary,
  decisions and action items (owner and task).
- `TranscriptSegment`: one transcribed line, with the meeting it belongs to, the speaker, the
  time, where it came from (`audio`, `captions`, `inferred`, `final` or `live`) and, in a final
  transcript, the voice that said it.
- `MeetingSpeaker`: a voice in a meeting's final transcript: its name and how it got it (your
  microphone, a saved voice, Claude's guess, or you), how long it spoke, and its voiceprint.
- `VoiceProfile`: a voice you named, as the average of its voiceprints, to recognise it later.
  Settings › Meetings › Forget All deletes them.

## Widgets

| Kind | Shows | Options |
|---|---|---|
| `zoom.upcoming` (Upcoming Meetings) | Calendar events with a Zoom link in the next 24 hours, soonest first, with a Join button that opens the Zoom app. Narrow: the next meeting alone. Wide and large: end times and calendars too. Without calendar access, a button to turn it on. Default size: medium. | `count`: how many meetings to list (default 6). |
| `zoom.meeting` (Meeting) | While a meeting runs: the live transcript, participants and a Stop button. Otherwise: recent meetings with their summaries, and a Transcribe button. Opening a meeting lets you summarise it again, ask Claude about it, or delete it. Default size: large. | `recentCount`: how many past meetings to list (default 5). Set through the widget config; the widget has no settings form. |

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `zoom_upcoming_meetings` | Lists the Zoom meetings in the next 24 hours from the calendar, with their join links. | No |
| `meetings_list` | Lists up to 30 recorded meetings, newest first, with summaries and action items. | No |
| `meeting_transcript` | Returns a meeting's transcript: the final one (each voice named, guesses marked) once the meeting has ended, the live one before. Defaults to the current meeting, else the latest. | No |
| `meeting_speakers` | Who spoke, in the order they first spoke, with how many lines and words, who is speaking now, and the participants not heard yet. | No |
| `meeting_participants` | Returns who is in the Zoom meeting right now, and whether Dash is recording. | No |
| `meeting_summarize` | Regenerates a meeting's title, summary, decisions and action items from its transcript. | No |

## Events

| Kind | When |
|---|---|
| `zoom.meeting_soon` | A calendar meeting with a Zoom link starts in the reminder time. The detail is its join link. Once per meeting. |
| `meeting.started` | Transcription of a Zoom meeting started. The detail lists the participants. When a calendar event is on (from 10 minutes before), the meeting is named after it and the summary keeps that name. |
| `meeting.ended` | The meeting ended or transcription stopped. |
| `meeting.summarized` | Claude's summary is ready, with counts of decisions and action items. |

## Knowledge graph and activity

- **Knowledge:** each meeting becomes `meeting:<uuid>`, with its summary and decisions as searchable text and its participants (`attended_by`). Ticket keys in them are linked by Dash.
- **Activity series:** `zoom.meetings` (meetings per day) and `zoom.hours` (hours in meetings per day).

## Third-party software

- [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.4, Apache License 2.0, linked
  into the plugin through `Packages/MeetingSpeech` (only its `Diarizer` trait: no text to speech,
  no prebuilt text-normalisation library).
- Models FluidAudio downloads at the first final transcript, into
  `~/Library/Application Support/FluidAudio/Models`:
  [Parakeet TDT Ultra](https://huggingface.co/FluidInference/parakeet-ultra-coreml) (moondream's
  post-training of NVIDIA's Parakeet TDT v3), CC BY 4.0; and the
  [pyannote speaker-diarization-community-1](https://huggingface.co/FluidInference/speaker-diarization-coreml)
  Core ML conversion, CC BY 4.0.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh Zoom   # generate the project, run ZoomPluginTests, build, zip
scripts/build-plugins.sh Zoom          # build and zip without the tests
```

The script writes `dist/zoom-1.10.1.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/Zoom/Build/Products/Release/ZoomPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
