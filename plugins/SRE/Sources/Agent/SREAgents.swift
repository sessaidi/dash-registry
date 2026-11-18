import DashKit

/// The SRE's agents. The user talks to Dashii; Dashii hands SRE questions to `sre.oncall`
/// (`agent sre.oncall ask "…"`), and hooks wake it when a monitor alerts or a pod crash-loops.
enum SREAgents {
    static let integrations = ["datadog", "datadog-monitors", "gcp", "kubernetes", "kubernetes-pods", "releases"]

    static var all: [AgentDefinition] { [oncall, review] }

    static let oncall = AgentDefinition(
        id: "oncall", name: "On-call SRE", summary: "Investigates alerts, failing pods and \"is prod OK?\" questions with evidence; read-only.",
        systemImage: "stethoscope", role: "senior site reliability engineer",
        specialities: ["Kubernetes and GKE", "Datadog monitors, logs and events", "Cloud Logging", "incident response", "change correlation"],
        instructions: """
            Work like a senior SRE on call. Most runs are a question Dashii asks for the user, or a wake-up from an alert.
            1. Impact first: what is broken, for whom, since when, how bad (S1 down or data loss, S2 major feature broken, \
            S3 degraded with a workaround, S4 cosmetic). `sre_status` shows what is alerting and which data is connected.
            2. Investigate with evidence: `sre_investigate` gathers monitors, pods, warning events, Datadog events and \
            recent releases and ranks likely causes with a smaller model; `sre_logs` digests logs into patterns. Hand other \
            narrow jobs to `function_run` (logs.digest, compare, rank, root_cause, sre.severity) instead of reading raw data. \
            They read what Dash fetched: when they return a `refresh` (missing or stale data), call `data_fetch` with each \
            one, then run them again.
            3. Correlate timing: deploys, releases, config and node changes just before the symptom come first.
            4. Conclude: the most likely cause with the evidence (ids, times), what would confirm it, and mitigations in \
            order of safety (roll back, scale, restart, wait) with who should act. You never act yourself.
            Say plainly what you couldn't check (a source not connected, no data in the window). Never paste secrets.
            In the report: the summary is the answer (or the incident in two sentences); one finding per real problem, \
            critical for S1/S2, warning for S3, info for notable but harmless.
            """,
        tools: ["sre_status", "sre_investigate", "sre_logs"], integrations: integrations,
        scope: "Observe and advise only; production changes are the user's.",
        schedule: AgentSchedule(events: ["datadog.alert", "pod.crashloop"]),
        models: [.strong, .deep, .balanced], defaultModel: .strong,
        precheck: { host in
            let signals = await Ops(host: host).signals()
            return signals.isQuiet ? .skip("Nothing alerting and every pod healthy.") : .run(context: signals.text)
        })

    static let review = AgentDefinition(
        id: "review", name: "Reliability review", summary: "A daily look at what alerted, what restarts and what is drifting; skipped when all is quiet.",
        systemImage: "checklist", role: "site reliability engineer",
        specialities: ["noisy monitors", "restarting workloads", "capacity"],
        instructions: """
            Review reliability over the last day: monitors that alert or flap, pods restarting or pending, recurring log \
            errors. Use sre_status, sre_logs and function_run (rank, logs.digest); when sre_logs returns a refresh, \
            data_fetch it and call sre_logs again. Report what deserves a ticket, ranked, \
            with evidence; skip what is already known and harmless.
            """,
        tools: ["sre_status", "sre_logs"], integrations: integrations,
        scope: "Observe and advise only.",
        schedule: AgentSchedule(everyMinutes: 24 * 60),
        models: [.balanced, .strong, .fast], defaultModel: .balanced,
        precheck: { host in
            let signals = await Ops(host: host).signals()
            return signals.isQuiet ? .skip("Quiet day: nothing alerting, pods healthy.") : .run(context: signals.text)
        })
}
