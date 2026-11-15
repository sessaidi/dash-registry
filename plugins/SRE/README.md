# SRE

A senior on-call SRE inside Dash. You don't talk to it directly: ask Dashii ("is prod OK?",
"why is api throwing 5xx?") and Dashii hands the question to the **On-call SRE** agent, which
answers with evidence.

- **Investigates with evidence** from the plugins you have on: Datadog monitors, events and
  logs; Kubernetes pods, events and logs; Google Cloud Logging; recent releases.
- **Hands narrow jobs to smaller models** (Dashii functions): log patterns, ranking likely
  causes, severity. The lead model reads conclusions, not raw logs.
- **Wakes up on its own** when a monitor alerts or a pod crash-loops (hook presets in
  Settings › Automation › Hooks), and skips runs while everything is healthy.
- **Read-only.** It proposes mitigations (roll back, scale, restart) and who should act; it
  never changes anything. An incident note is written only when you ask, after you approve.

Also: the **SRE Status** widget (is prod OK, what needs attention, the SRE's latest finding;
hover a monitor or pod for **Explain this** or **Ask the SRE to investigate** that item alone,
right-click a finding for more on it),
`from signals` in DashQL, `sre status | investigate | logs | note` statements, and the
`sre.severity` function (S1–S4, page or not) for other plugins and agents.
