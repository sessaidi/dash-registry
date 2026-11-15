import DashKit

/// The SRE in DashQL: what needs attention as a dataset, and statements for its tools.
extension SREFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "signals", aliases: ["attention", "incidents_now"],
                      summary: "What needs attention now: monitors not OK and pods not healthy, worst first.",
                      fields: [.init("id", .string, "Monitor id or namespace/pod"), .init("title", .string, "What it is"),
                               .init("detail", .string, "Status, service, restarts…"), .init("level", .string, "critical, warning or unknown"),
                               .init("since", .date, "When it started or last triggered")]) { [weak self] _ in
            guard let host = self?.host else { return [] }
            let signals = await Ops(host: host).signals()
            return (signals.monitors + signals.pods).map(\.json)
        }]
    }

    var verbs: [DashQLVerb] {
        [
            DashQLVerb("sre", "status", tool: "sre_status", summary: "What's alerting and which pods are unhealthy."),
            DashQLVerb("sre", "investigate", tool: "sre_investigate", arguments: ["symptom"], summary: "Evidence and ranked likely causes (namespace=, service=, minutes=)."),
            DashQLVerb("sre", "logs", tool: "sre_logs", arguments: ["source"], summary: "Log patterns from datadog, gcp or kubernetes (query=, pod=, project=)."),
            DashQLVerb("sre", "note", tool: "sre_incident_note", arguments: ["title"], summary: "Write an incident note (markdown=; asks first)."),
        ]
    }

    var hookPresets: [HookPresetSpec] {
        [
            .wakeOn("sre.wake-on-alert", category: "SRE", "A monitor alerts: the on-call SRE investigates", dataset: "monitors",
                    where: "status = \"Alert\"", key: "id", every: 2,
                    task: "Investigate these alerting monitors: impact, likely cause with evidence, next steps."),
            .wakeOn("sre.wake-on-crashloop", category: "SRE", "A pod crash-loops: the on-call SRE investigates", dataset: "pods",
                    where: "status = \"CrashLoopBackOff\"", key: "name", every: 5,
                    task: "Find why these pods crash-loop (logs, events, recent changes) and what to do."),
            .appears("sre.notify-critical", category: "SRE", "Notify when something critical needs attention", dataset: "signals",
                     where: "level = \"critical\"", key: "id", every: 2, title: "{{count}} critical: {{first.title}}", body: "{{first.detail}}"),
        ]
    }
}
