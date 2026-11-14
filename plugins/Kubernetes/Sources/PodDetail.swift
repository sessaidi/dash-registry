import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// kubectl commands for a pod, for the clipboard or Terminal.
enum PodCommands {
    static func base(_ pod: PodSummary, context: String?) -> String {
        "kubectl" + (context.map { " --context \(quote($0))" } ?? "") + " -n \(quote(pod.namespace))"
    }

    static func logs(_ pod: PodSummary, context: String?, container: String? = nil) -> String {
        base(pod, context: context) + " logs -f \(quote(pod.name))" + (container.map { " -c \(quote($0))" } ?? "") + " --tail 200"
    }

    static func exec(_ pod: PodSummary, context: String?, container: String? = nil) -> String {
        base(pod, context: context) + " exec -it \(quote(pod.name))" + (container.map { " -c \(quote($0))" } ?? "") + " -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }

    static func describe(_ pod: PodSummary, context: String?) -> String {
        base(pod, context: context) + " describe pod \(quote(pod.name))"
    }

    /// Single-quotes a shell word unless it is plainly safe.
    static func quote(_ word: String) -> String {
        word.allSatisfy { $0.isLetter || $0.isNumber || "-_.:/@".contains($0) } ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command in a new Terminal window.
    static func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

/// One pod in depth, like k9s's describe/logs/yaml views.
struct PodDetailSheet: View {
    enum Tab: String, CaseIterable {
        case overview = "Overview", containers = "Containers", events = "Events", logs = "Logs", yaml = "YAML"
    }

    let pod: PodSummary
    /// The widget's context; nil is the one the integration uses.
    let context: String?
    let feature: PodsFeature
    let host: any ExtensionContext
    /// Called after the pod was deleted, so the list catches up at once.
    var onChange: () async -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var tab = Tab.overview
    @State private var object: JSONValue?
    @State private var events: [JSONValue] = []
    @State private var error: String?
    @State private var confirmDelete = false

    private var contextName: String? { context ?? feature.cluster?.activeContext }
    private var connection: IntegrationConnection? { feature.cluster?.connection(context: context) }
    private var current: PodSummary { object.flatMap(PodSummary.init) ?? pod }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(current.tone, help: current.status)
                Text(pod.name).font(.title3.bold().monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Badge(current.status, tone: current.tone)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text([contextName, pod.namespace, current.owner].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .overview: ScrollView { overview.frame(maxWidth: .infinity, alignment: .leading) }
                case .containers: ScrollView { containers.frame(maxWidth: .infinity, alignment: .leading) }
                case .events: eventsList
                case .logs: PodLogsView(pod: pod, containers: current.containers, connection: connection)
                case .yaml: yaml
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Shell", systemImage: "terminal") { PodCommands.runInTerminal(PodCommands.exec(pod, context: contextName)) }
                    .help("kubectl exec -it in Terminal")
                Button("Follow Logs", systemImage: "text.alignleft") { PodCommands.runInTerminal(PodCommands.logs(pod, context: contextName)) }
                    .help("kubectl logs -f in Terminal")
                Button("Ask Claude", systemImage: "sparkles") {
                    host.askClaude("Look at pod \(pod.name) in namespace \(pod.namespace) (context \(contextName ?? "current")): describe it, check its events and logs, and tell me what's wrong if anything.")
                    dismiss()
                }
                Spacer()
                AsyncButton("Reload") { await load() }
                Button("Delete Pod…", role: .destructive) { confirmDelete = true }
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .task { await load() }
        .confirmationDialog("Delete pod \(pod.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text(current.owner == nil
                 ? "This pod has no controller: it will not come back."
                 : "Its \(current.owner!.split(separator: "/").first ?? "controller") will create a replacement.")
        }
    }

    // MARK: Loading

    private var podPath: String { "/api/v1/namespaces/\(pod.namespace)/pods/\(pod.name)" }

    private func load() async {
        guard let connection else { error = "Kubernetes isn't connected."; return }
        do {
            object = try await connection.get(podPath, service: "Kubernetes")
            let selector = "involvedObject.name=\(pod.name)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let list = try await connection.get("/api/v1/namespaces/\(pod.namespace)/events?fieldSelector=\(selector)", service: "Kubernetes")
            events = (list["items"]?.array ?? []).sorted { Self.eventTime($0) > Self.eventTime($1) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let connection, let url = connection.url(podPath) else { return }
        do {
            _ = try await connection.send(try HTTP.request(url, method: "DELETE"), service: "Kubernetes")
            host.emit("pod.deleted", from: feature, title: "Deleted pod \(pod.name)", detail: "\(pod.namespace) on \(contextName ?? "the current context")", importance: .info)
            await onChange()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func eventTime(_ event: JSONValue) -> String {
        event["lastTimestamp"]?.string ?? event["eventTime"]?.string ?? event["metadata"]?["creationTimestamp"]?.string ?? ""
    }

    // MARK: Tabs

    @ViewBuilder
    private var overview: some View {
        let spec = object?["spec"]
        let status = object?["status"]
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Status", current.status)
                row("Ready", "\(current.ready)/\(current.total)")
                row("Restarts", "\(current.restarts)")
                row("Age", PodSummary.age(since: current.created) + (current.created.map { " (\($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""))
                row("Node", current.node ?? "—")
                row("Pod IP", current.podIP ?? "—")
                row("Host IP", status?["hostIP"]?.string ?? "—")
                row("QoS", status?["qosClass"]?.string ?? "—")
                row("Service account", spec?["serviceAccountName"]?.string ?? "—")
                row("Controlled by", current.owner ?? "—")
                row("Priority class", spec?["priorityClassName"]?.string ?? "—")
            }
            if let conditions = status?["conditions"]?.array, !conditions.isEmpty {
                DetailSection("Conditions") {
                    ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                        HStack(spacing: 6) {
                            StatusDot(condition["status"]?.string == "True" ? .success : .warning)
                            Text(condition["type"]?.string ?? "?").monospaced()
                            if let reason = condition["reason"]?.string { Text(reason).foregroundStyle(.secondary) }
                            if let message = condition["message"]?.string { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }
            if !current.labels.isEmpty {
                DetailSection("Labels") { tags(current.labels) }
            }
            if let annotations = object?["metadata"]?["annotations"]?.object?.compactMapValues(\.string), !annotations.isEmpty {
                DetailSection("Annotations") { tags(annotations.filter { $0.value.count < 200 }) }
            }
            if let volumes = spec?["volumes"]?.array, !volumes.isEmpty {
                DetailSection("Volumes") {
                    ForEach(Array(volumes.enumerated()), id: \.offset) { _, volume in
                        let kind = (volume.object ?? [:]).keys.first { $0 != "name" } ?? "?"
                        Text("\(volume["name"]?.string ?? "?") · \(kind)").font(.callout.monospaced())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var containers: some View {
        let specs = (object?["spec"]?["initContainers"]?.array ?? []).map { ($0, true) } + (object?["spec"]?["containers"]?.array ?? []).map { ($0, false) }
        let statuses = (object?["status"]?["initContainerStatuses"]?.array ?? []) + (object?["status"]?["containerStatuses"]?.array ?? [])
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, entry in
                let (spec, isInit) = entry
                let name = spec["name"]?.string ?? "?"
                let status = statuses.first { $0["name"]?.string == name }
                let state = Self.containerState(status)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusDot(state.tone)
                        Text(name).font(.headline.monospaced())
                        if isInit { Badge("init", tone: .neutral) }
                        Badge(state.label, tone: state.tone)
                        if let restarts = status?["restartCount"]?.int, restarts > 0 { Badge("\(restarts) restarts", tone: .warning, systemImage: "arrow.clockwise") }
                        Spacer()
                        Button("Shell") { PodCommands.runInTerminal(PodCommands.exec(pod, context: contextName, container: name)) }.controlSize(.small)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        row("Image", spec["image"]?.string ?? "—")
                        if let command = (spec["command"]?.array ?? []) + (spec["args"]?.array ?? []) as [JSONValue]?, !command.isEmpty {
                            row("Command", command.compactMap(\.string).joined(separator: " "))
                        }
                        row("Requests", Self.resources(spec["resources"]?["requests"]))
                        row("Limits", Self.resources(spec["resources"]?["limits"]))
                        if let ports = spec["ports"]?.array, !ports.isEmpty {
                            row("Ports", ports.map { "\($0["containerPort"]?.int ?? 0)/\($0["protocol"]?.string ?? "TCP")" + ($0["name"]?.string.map { " (\($0))" } ?? "") }.joined(separator: ", "))
                        }
                        if let last = status?["lastState"]?["terminated"] {
                            row("Last exit", "\(last["reason"]?.string ?? "?") · code \(last["exitCode"]?.int ?? 0)" + (last["finishedAt"]?.string.map { " · \($0)" } ?? ""))
                        }
                        if let probe = spec["readinessProbe"] { row("Readiness", Self.probe(probe)) }
                        if let probe = spec["livenessProbe"] { row("Liveness", Self.probe(probe)) }
                        let env = (spec["env"]?.array ?? []).compactMap { $0["name"]?.string }
                        if !env.isEmpty { row("Env", env.joined(separator: ", ")) }
                        let mounts = (spec["volumeMounts"]?.array ?? []).map { "\($0["name"]?.string ?? "?") → \($0["mountPath"]?.string ?? "?")" }
                        if !mounts.isEmpty { row("Mounts", mounts.joined(separator: "\n")) }
                    }
                }
                Divider()
            }
        }
    }

    private var eventsList: some View {
        Group {
            if events.isEmpty {
                StateView(.empty(title: "No events", systemImage: "checkmark.circle", message: "Kubernetes keeps events for about an hour."))
            } else {
                List(Array(events.enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusDot(event["type"]?.string == "Warning" ? .warning : .neutral)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event["reason"]?.string ?? "?").font(.callout.bold())
                                if let count = event["count"]?.int, count > 1 { Text("×\(count)").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(Self.eventTime(event)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(event["message"]?.string ?? "").font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var yaml: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(object.map { Self.yaml(Self.withoutManagedFields($0)) } ?? "Loading…")
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 6))
    }

    // MARK: Pieces

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(6)
        }
    }

    private func tags(_ values: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(values.keys.sorted(), id: \.self) { key in
                Text("\(key)=\(values[key] ?? "")").font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    nonisolated static func containerState(_ status: JSONValue?) -> (label: String, tone: Tone) {
        guard let state = status?["state"] else { return ("Unknown", .neutral) }
        if state["running"] != nil { return status?["ready"]?.bool == true ? ("Running", .success) : ("Running, not ready", .warning) }
        if let waiting = state["waiting"] {
            let reason = waiting["reason"]?.string ?? "Waiting"
            return (reason, reason.hasSuffix("BackOff") || reason.hasPrefix("Err") ? .danger : .warning)
        }
        if let terminated = state["terminated"] {
            let code = terminated["exitCode"]?.int ?? 0
            return ("\(terminated["reason"]?.string ?? "Terminated") (\(code))", code == 0 ? .neutral : .danger)
        }
        return ("Unknown", .neutral)
    }

    nonisolated static func resources(_ values: JSONValue?) -> String {
        let pairs = (values?.object ?? [:]).compactMapValues(\.string)
        return pairs.isEmpty ? "—" : pairs.keys.sorted().map { "\($0) \(pairs[$0]!)" }.joined(separator: ", ")
    }

    nonisolated static func probe(_ probe: JSONValue) -> String {
        let how: String
        if let http = probe["httpGet"] { how = "GET :\(http["port"]?.int.map(String.init) ?? http["port"]?.string ?? "?")\(http["path"]?.string ?? "/")" }
        else if let tcp = probe["tcpSocket"] { how = "TCP :\(tcp["port"]?.int.map(String.init) ?? tcp["port"]?.string ?? "?")" }
        else if let exec = probe["exec"] { how = "exec " + (exec["command"]?.array ?? []).compactMap(\.string).joined(separator: " ") }
        else if probe["grpc"] != nil { how = "gRPC" }
        else { how = "?" }
        return how + " every \(probe["periodSeconds"]?.int ?? 10)s, delay \(probe["initialDelaySeconds"]?.int ?? 0)s, failure ×\(probe["failureThreshold"]?.int ?? 3)"
    }

    nonisolated static func withoutManagedFields(_ object: JSONValue) -> JSONValue {
        guard case .object(var fields) = object, case .object(var metadata)? = fields["metadata"] else { return object }
        metadata["managedFields"] = nil
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }

    /// Block-style YAML for display (keys in order, strings quoted only when needed).
    nonisolated static func yaml(_ value: JSONValue, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .object(let fields):
            if fields.isEmpty { return pad + "{}" }
            return fields.keys.sorted().map { key in
                let child = fields[key]!
                switch child {
                case .object(let inner) where !inner.isEmpty: return "\(pad)\(scalarKey(key)):\n" + yaml(child, indent: indent + 1)
                case .array(let items) where !items.isEmpty: return "\(pad)\(scalarKey(key)):\n" + yaml(child, indent: indent)
                default: return "\(pad)\(scalarKey(key)): \(scalar(child))"
                }
            }.joined(separator: "\n")
        case .array(let items):
            if items.isEmpty { return pad + "[]" }
            return items.map { item in
                switch item {
                case .object(let inner) where !inner.isEmpty:
                    let body = yaml(item, indent: indent + 1)
                    return pad + "- " + body.dropFirst(pad.count + 2)
                case .array(let inner) where !inner.isEmpty:
                    return pad + "-\n" + yaml(item, indent: indent + 1)
                default: return pad + "- " + scalar(item)
                }
            }.joined(separator: "\n")
        default:
            return pad + scalar(value)
        }
    }

    nonisolated private static func scalarKey(_ key: String) -> String {
        key.allSatisfy { $0.isLetter || $0.isNumber || "-_./".contains($0) } ? key : "\"\(key)\""
    }

    nonisolated private static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .string(let text):
            let plain = !text.isEmpty && !text.contains(":") && !text.contains("#") && !text.contains("\n") && !text.hasPrefix(" ")
                && !["true", "false", "null", "yes", "no", "~"].contains(text.lowercased()) && Double(text) == nil
                && !"-?[]{}!*&|>'\"%@`,".contains(text.first!)
            return plain ? text : JSONValue.string(text).jsonString()
        case .object: return "{}"
        case .array: return "[]"
        @unknown default: return value.jsonString()
        }
    }
}

/// A container's logs: pick the container, the previous run, how many lines, filter, and follow (refresh every 3 s).
private struct PodLogsView: View {
    let pod: PodSummary
    let containers: [String]
    let connection: IntegrationConnection?
    @State private var container = ""
    @State private var previous = false
    @State private var tail = 500
    @State private var follow = false
    @State private var wrap = true
    @State private var filter = ""
    @State private var text = ""
    @State private var error: String?
    @State private var loading = false

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if containers.count > 1 {
                    Picker("Container", selection: $container) {
                        ForEach(containers, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
                Picker("Lines", selection: $tail) {
                    ForEach([100, 500, 2000, 10000], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Toggle("Previous", isOn: $previous).help("The run before the last restart")
                Toggle("Follow", isOn: $follow).help("Refresh every 3 seconds")
                Toggle("Wrap", isOn: $wrap)
                TextField("Filter lines", text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 140)
                if loading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption) }
            ScrollViewReader { proxy in
                ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shown.isEmpty ? (loading ? "Loading…" : "No log lines.") : shown)
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: !wrap, vertical: false)
                            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(8)
                }
                .background(.background.secondary, in: .rect(cornerRadius: 6))
                .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .task(id: "\(container)|\(previous)|\(tail)|\(follow)") {
            if container.isEmpty, let first = containers.first { container = first }
            repeat {
                await load()
                guard follow else { return }
                try? await Task.sleep(for: .seconds(3))
            } while !Task.isCancelled
        }
    }

    private func load() async {
        guard let connection else { error = "Kubernetes isn't connected."; return }
        var query = ["timestamps=true", "tailLines=\(tail)"]
        if !container.isEmpty { query.append("container=\(container)") }
        if previous { query.append("previous=true") }
        guard let url = connection.url("/api/v1/namespaces/\(pod.namespace)/pods/\(pod.name)/log?" + query.joined(separator: "&")) else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await connection.send(URLRequest(url: url), service: "Kubernetes")
            text = String(decoding: data, as: UTF8.self)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
