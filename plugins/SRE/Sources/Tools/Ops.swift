import DashKit
import Foundation

/// What the SRE reads, through the other extensions only: their DashQL datasets (`monitors`,
/// `pods`, `releases`) and their readers (`k8s_events`, `datadog_events`, logs), which answer from
/// what Dash fetched. Only tools Dashii may use are called: never one that changes things, writes
/// remotely or calls a service.
@MainActor
struct Ops {
    let host: any ExtensionContext

    private var enabled: [any DashExtension] { host.extensions.filter { host.isEnabled($0) } }

    /// A reader of an enabled extension.
    func tool(_ name: String) -> DashiiTool? {
        enabled.flatMap(\.tools).first { $0.name == name && $0.isForDashii && !$0.requiresApproval }
    }

    func call(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        guard let tool = tool(name) else { throw ToolError("\(name) isn't available (its plugin is off or not installed).") }
        return try await tool.run(input)
    }

    func read(_ name: String, _ input: JSONValue = [:]) async throws -> Reading { Reading(value: try await call(name, input)) }

    /// A dataset's rows, or nil when no enabled extension offers it.
    func rows(_ dataset: String) async -> [JSONValue]? {
        guard let source = enabled.flatMap(\.datasets).first(where: { $0.name == dataset }) else { return nil }
        return try? await source.rows(nil)
    }

    // MARK: Signals

    /// What needs attention now: monitors not OK, pods not healthy.
    func signals() async -> Signals {
        var signals = Signals()
        if let monitors = await rows("monitors") {
            signals.sources.append("datadog")
            signals.monitors = monitors.compactMap(Signal.monitor).sorted { $0.rank < $1.rank }
        }
        if let pods = await rows("pods") {
            signals.sources.append("kubernetes")
            signals.pods = pods.compactMap(Signal.pod).sorted { $0.rank < $1.rank }
        }
        return signals
    }

    // MARK: Evidence

    /// Signals, warning events, recent changes and releases as numbered evidence for `root_cause`,
    /// what couldn't be checked, and the fetches that would bring missing or stale data.
    func evidence(namespace: String?, service: String?, minutes: Int) async -> (items: [DashiiFunctions.Evidence], gaps: [String], refresh: [JSONValue]) {
        var items: [DashiiFunctions.Evidence] = []
        var gaps: [String] = []
        var refresh: [JSONValue] = []
        func note(_ what: String, _ reading: Reading) {
            guard let fetch = reading.refresh else { return }
            refresh.append(fetch)
            let fetcher = fetch["fetcher"]?.string ?? "its fetcher"
            gaps.append(reading.fetched ? "\(what): as of \(reading.syncedAt ?? "an earlier fetch"), stale (data_fetch \(fetcher) for current data)."
                                        : "\(what): not in Dash yet (data_fetch \(fetcher), then investigate again).")
        }
        func add(_ source: String, _ detail: String, at: String? = nil) {
            guard items.count < 60 else { return }
            items.append(.init(id: "e\(items.count + 1)", source: source, detail: String(detail.prefix(300)), at: at))
        }

        let signals = await signals()
        for monitor in signals.monitors.prefix(15) { add("datadog monitor \(monitor.id)", "\(monitor.title): \(monitor.detail)", at: monitor.since) }
        for pod in signals.pods.prefix(15) { add("pod \(pod.id)", "\(pod.title): \(pod.detail)", at: pod.since) }
        if signals.sources.isEmpty { gaps.append("No monitors or pods dataset: turn on Datadog Monitors or Kubernetes Pods.") }

        if tool("k8s_events") != nil {
            var input: [String: JSONValue] = ["warningsOnly": true]
            if let namespace { input["namespace"] = .string(namespace) }
            do {
                let reading = try await read("k8s_events", .object(input))
                note("Kubernetes events", reading)
                for event in reading.rows.prefix(20) {
                    add("k8s event \(event["object"]?.string ?? "")", "\(event["reason"]?.string ?? ""): \(event["message"]?.string ?? "")",
                        at: event["lastSeen"]?.string)
                }
            } catch { gaps.append("Kubernetes events: \(error.localizedDescription)") }
        } else {
            gaps.append("Kubernetes events: the Kubernetes plugin is off.")
        }

        if tool("datadog_events") != nil {
            let query = service.map { "service:\($0)" } ?? ""
            do {
                let reading = try await read("datadog_events", ["query": .string(query), "minutes": .number(Double(minutes)), "limit": 30])
                note("Datadog events", reading)
                for event in reading.rows.prefix(20) {
                    let attributes = event["attributes"] ?? event
                    let text = attributes["title"]?.string ?? attributes["message"]?.string ?? attributes["attributes"]?["title"]?.string ?? ""
                    guard !text.isEmpty else { continue }
                    add("datadog event", text, at: attributes["timestamp"]?.string)
                }
            } catch { gaps.append("Datadog events: \(error.localizedDescription)") }
        }

        if let releases = await rows("releases") {
            let cutoff = Date.now.addingTimeInterval(-Double(max(minutes, 60) * 4) * 60)
            for release in releases where (DashDate.parse(release["date"] ?? .null) ?? .distantPast) >= cutoff {
                add("release \(release["tag"]?.string ?? release["name"]?.string ?? "")",
                    "\(release["repo"]?.string ?? "") \(release["train"]?.string ?? "")".trimmingCharacters(in: .whitespaces),
                    at: release["date"]?.string)
            }
        }
        return (items, gaps, refresh)
    }

    // MARK: Logs

    /// Log lines from Datadog, Cloud Logging or a pod, newest first, at most `limit`, with the
    /// reader's answer (whether Dash has them, and how fresh).
    func logLines(source: String, query: String?, project: String?, namespace: String?, pod: String?, minutes: Int, limit: Int = 300) async throws -> (lines: [String], reading: Reading) {
        let raw: JSONValue
        switch source {
        case "datadog":
            raw = try await call("datadog_logs_search", ["query": .string(query ?? "status:error"), "from": .string("now-\(minutes)m"), "limit": 200])
        case "gcp":
            guard let project else { throw ToolError("Give the GCP project for Cloud Logging.") }
            var input: [String: JSONValue] = ["project": .string(project), "since": .string("\(minutes)m"), "minSeverity": "WARNING"]
            if let query { input["text"] = .string(query) }
            if let namespace { input["namespace"] = .string(namespace) }
            if let pod { input["pod"] = .string(pod) }
            raw = try await call("gcp_logs_query", .object(input))
        case "kubernetes":
            guard let pod else { throw ToolError("Give the pod for Kubernetes logs.") }
            var input: [String: JSONValue] = ["pod": .string(pod), "tail": .number(Double(limit)), "sinceSeconds": .number(Double(minutes * 60))]
            if let namespace { input["namespace"] = .string(namespace) }
            raw = try await call("k8s_logs", .object(input))
        default:
            throw ToolError("Logs come from datadog, gcp or kubernetes.")
        }
        let reading = Reading(value: raw)
        guard reading.fetched else { return ([], reading) }
        let lines = Self.lines(raw)
        if source == "kubernetes", let query, !query.isEmpty { return (Array(lines.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(limit)), reading) }
        return (Array(lines.prefix(limit)), reading)
    }

    /// Text lines from whatever a log tool returns: text, entries with a message, or JSON.
    static func lines(_ value: JSONValue) -> [String] {
        switch value {
        case .string(let text): return text.split(whereSeparator: \.isNewline).map(String.init).reversed()
        case .array(let entries):
            return entries.map { entry in
                let message = entry["message"]?.string ?? entry["textPayload"]?.string ?? entry["jsonPayload"]?["message"]?.string
                    ?? entry["attributes"]?["message"]?.string ?? entry.string ?? entry.jsonString()
                let status = entry["status"]?.string ?? entry["severity"]?.string
                return [status, message].compactMap { $0 }.joined(separator: " ")
            }
        case .object(let object):
            for key in ["entries", "data", "logs", "lines", "items", "text"] where object[key] != nil { return lines(object[key]!) }
            return [value.jsonString()]
        default: return []
        }
    }
}

/// What a reader answered: its rows (a list, `items`, or Datadog's `data`), when Dash fetched
/// them, and the `data_fetch` call to make when they're missing or stale.
struct Reading: Sendable, Equatable {
    let value: JSONValue

    var fetched: Bool { value["fetched"] != false }
    var stale: Bool { value["stale"] == true }
    var syncedAt: String? { value["synced_at"]?.string }
    /// `{fetcher, input}` when the data is missing or stale; nil when it's current.
    var refresh: JSONValue? { fetched && !stale ? nil : value["refresh"] }
    var rows: [JSONValue] { value.array ?? value["items"]?.array ?? value["data"]?.array ?? [] }
}

/// Monitors and pods that need attention, worst first.
struct Signals: Sendable, Equatable {
    var monitors: [Signal] = []
    var pods: [Signal] = []
    /// The data that was there to look at.
    var sources: [String] = []

    var isQuiet: Bool { monitors.isEmpty && pods.isEmpty }

    var json: JSONValue {
        ["monitors": .array(monitors.map(\.json)), "unhealthy_pods": .array(pods.map(\.json)), "sources": .array(sources.map(JSONValue.string)),
         "quiet": .bool(isQuiet)]
    }

    /// One line per signal, for an agent's prompt.
    var text: String {
        (monitors + pods).map { "- \($0.title): \($0.detail)" }.joined(separator: "\n")
    }
}

struct Signal: Sendable, Equatable, Identifiable {
    enum Level: Int, Sendable, Comparable {
        case critical, warning, unknown
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let title: String
    let detail: String
    let level: Level
    let since: String?

    var rank: Level { level }

    var json: JSONValue {
        ["id": .string(id), "title": .string(title), "detail": .string(detail), "level": .string("\(level)"), "since": since.map(JSONValue.string) ?? .null]
    }

    /// A monitor row (`from monitors`) that isn't OK.
    static func monitor(_ row: JSONValue) -> Signal? {
        let status = row["status"]?.string ?? ""
        guard !["OK", ""].contains(status) else { return nil }
        let level: Level = status == "Alert" ? .critical : status == "Warn" ? .warning : .unknown
        let tags = [row["service"]?.string.map { "service \($0)" }, row["env"]?.string.map { "env \($0)" }].compactMap { $0 }
        return Signal(id: row["id"].map { $0.int.map(String.init) ?? $0.string ?? "" } ?? "", title: row["name"]?.string ?? "Monitor",
                      detail: ([status] + tags).joined(separator: " · "), level: level, since: row["last_triggered"]?.string)
    }

    /// A pod row (`from pods`) that isn't healthy.
    static func pod(_ row: JSONValue) -> Signal? {
        guard row["healthy"]?.bool == false else { return nil }
        let status = row["status"]?.string ?? "?"
        let restarts = row["restarts"]?.int ?? 0
        let level: Level = ["CrashLoopBackOff", "Error", "OOMKilled", "ImagePullBackOff", "ErrImagePull"].contains(status) || restarts >= 5 ? .critical : .warning
        let namespace = row["namespace"]?.string ?? ""
        let warnings = row["warnings"]?.array?.compactMap(\.string) ?? []
        return Signal(id: "\(namespace)/\(row["name"]?.string ?? "")", title: "Pod \(row["name"]?.string ?? "")",
                      detail: (["\(status) in \(namespace)", "\(restarts) restarts"] + warnings.prefix(3)).joined(separator: " · "),
                      level: level, since: row["created"]?.string)
    }
}
