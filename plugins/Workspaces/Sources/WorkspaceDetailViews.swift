import AppKit
import DashKit
import DashKitUI
import SwiftUI
import WorkspaceKit

/// The tabs of a workspace's window besides its overview.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview, train, logs, cloud, diagnose, config, commands
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .train: "Train"
        case .logs: "Logs"
        case .cloud: "Cloud Logs"
        case .diagnose: "Diagnose"
        case .config: "Config"
        case .commands: "Commands"
        }
    }
}

/// Copyable command block.
struct CommandBlock: View {
    let label: String
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
    }
}

// MARK: Logs

struct WorkspaceLogsView: View {
    let name: String
    let feature: WorkspacesFeature
    @State private var pods: [WorkspaceDiagnosis.Pod] = []
    @State private var pod = ""
    @State private var container = ""
    @State private var previous = false
    @State private var follow = false
    @State private var filter = ""
    @State private var onlyErrors = false
    @State private var text = ""
    @State private var error: String?
    @State private var explanation: String?
    @State private var explaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Pod", selection: $pod) {
                    ForEach(pods, id: \.name) { Text("\($0.name)\($0.containers.contains { $0.restarts > 0 } ? " ⟳" : "")").tag($0.name) }
                }
                .frame(maxWidth: 280)
                Picker("Container", selection: $container) {
                    ForEach(pods.first { $0.name == pod }?.containers.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 200)
                Toggle("Before last restart", isOn: $previous)
                Toggle("Follow", isOn: $follow)
            }
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Errors only", isOn: $onlyErrors)
                Spacer()
                Button("Explain", systemImage: "sparkles") { explain() }.disabled(text.isEmpty || explaining)
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let explanation {
                ScrollView { Text(explanation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 160).padding(8).background(.tint.opacity(0.08), in: .rect(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(Self.isError(line) ? .red : Self.isWarning(line) ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            if !pod.isEmpty, let context = feature.connectedClient?.kube.contextName {
                CommandBlock(label: "Same logs in a terminal",
                             command: "kubectl --context \(context) logs -n \(name) \(pod)\(container.isEmpty ? "" : " -c \(container)") --tail=1000 --timestamps\(previous ? " --previous" : "")\(follow ? " -f" : "")")
            }
        }
        .task {
            if let diagnosis = try? await feature.diagnose(name) {
                pods = diagnosis.pods
                // Start on the pod that restarted most.
                let worst = pods.max { a, b in a.containers.map(\.restarts).reduce(0, +) < b.containers.map(\.restarts).reduce(0, +) }
                pod = worst?.name ?? pods.first?.name ?? ""
                container = worst?.containers.first?.name ?? ""
                await load()
            }
        }
        .onChange(of: pod) { container = pods.first { $0.name == pod }?.containers.first?.name ?? ""; Task { await load() } }
        .onChange(of: container) { Task { await load() } }
        .onChange(of: previous) { Task { await load() } }
        .task(id: follow) {
            while follow && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
    }

    private var visibleLines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
            (filter.isEmpty || line.localizedCaseInsensitiveContains(filter)) && (!onlyErrors || Self.isError(line) || Self.isWarning(line))
        }.suffix(3000)
    }

    static func isError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("\"level\":\"error\"") || lower.contains("level=error") || lower.contains(" error ") || lower.contains("panic") || lower.contains("fatal")
    }

    static func isWarning(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("\"level\":\"warn") || lower.contains("level=warn") || lower.contains(" warn")
    }

    private func load() async {
        guard !pod.isEmpty else { return }
        do {
            text = try await feature.logs(name, pod: pod, container: container.isEmpty ? nil : container, previous: previous, tail: 1000)
            error = nil
        } catch {
            self.error = WorkspacesFeature.describe(error)
        }
    }

    /// Claude reads the visible lines and explains them, quoting the lines that matter.
    private func explain() {
        guard let host = feature.host else { return }
        explaining = true
        let excerpt = visibleLines.suffix(400).joined(separator: "\n")
        Task {
            explanation = (try? await host.claude.complete(
                task: WorkspacesFeature.explainTask.id, settings: host.aiSettings(.extension(feature.id), tasks: feature.aiTasks),
                system: "You explain service logs to the engineer who owns the service. Say what happened, in order, and why; quote the exact lines (with their timestamps) that show it; then what to do. Be brief.",
                prompt: "Workspace \(name), pod \(pod), container \(container)\(previous ? " (run before the last restart)" : ""):\n\n\(excerpt)")) ?? "Claude couldn't explain these logs."
            explaining = false
        }
    }
}

// MARK: Cloud Logging

struct WorkspaceCloudLogsView: View {
    let name: String
    let feature: WorkspacesFeature
    @State private var since = "6h"
    @State private var severity = "WARNING"
    @State private var text = ""
    @State private var result: JSONValue?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Since", selection: $since) { ForEach(["30m", "1h", "6h", "24h", "7d"], id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 140)
                Picker("At least", selection: $severity) { ForEach(["DEFAULT", "INFO", "WARNING", "ERROR"], id: \.self) { Text($0.capitalized).tag($0) } }.frame(maxWidth: 180)
                TextField("Contains", text: $text).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                Button("Search") { Task { await load() } }.disabled(loading)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            List(Array((result?["entries"]?.array ?? []).enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry["severity"]?.string ?? "").font(.caption.bold()).foregroundStyle(entry["severity"]?.string == "ERROR" || entry["severity"]?.string == "CRITICAL" ? .red : .orange)
                        Text(entry["timestamp"]?.string ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text("\(entry["pod"]?.string ?? "")/\(entry["container"]?.string ?? "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(entry["message"]?.string ?? "").font(.caption.monospaced()).textSelection(.enabled).lineLimit(8)
                }
            }
            if let command = result?["gcloud"]?.string { CommandBlock(label: "gcloud", command: command) }
            if let command = result?["command"]?.string { CommandBlock(label: "Exact request (same entries)", command: command) }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            result = try await feature.cloudLogs(name, minSeverity: severity, text: text, since: since)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Diagnose

struct WorkspaceDiagnoseView: View {
    let name: String
    let feature: WorkspacesFeature
    @State private var diagnosis: WorkspaceDiagnosis?
    @State private var report: AgentReport?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Findings").font(.headline)
                    Spacer()
                    Button {
                        runDoctor()
                    } label: {
                        if running { ProgressView().controlSize(.small) } else { Label("Ask the Workspace Doctor", systemImage: "stethoscope") }
                    }
                    .disabled(running)
                    .help("An agent reads Kubernetes status, logs before restarts, Cloud Logging and metrics, and explains the root cause with references and the verbatim evidence.")
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if let report {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Workspace Doctor: \(report.summary)", systemImage: "stethoscope").font(.callout.bold())
                        ForEach(report.findings) { finding in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(finding.severity.rawValue.uppercased()) · \(finding.title)").font(.callout.bold())
                                    .foregroundStyle(finding.severity == .critical ? .red : finding.severity == .warning ? .orange : .primary)
                                if !finding.target.isEmpty { Text(finding.target).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                Text(finding.detail).font(.caption.monospaced()).textSelection(.enabled)
                                    .padding(6).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                                if !finding.suggestion.isEmpty { Text("→ \(finding.suggestion)").font(.callout) }
                            }
                        }
                    }
                    .padding(10).background(.tint.opacity(0.06), in: .rect(cornerRadius: 10))
                }
                if let diagnosis {
                    if diagnosis.findings.isEmpty { Text("No problem found in the pods, events and nodes.").foregroundStyle(.secondary) }
                    ForEach(Array(diagnosis.findings.enumerated()), id: \.offset) { _, finding in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.title).font(.callout.bold()).foregroundStyle(finding.severity == "critical" ? .red : .orange)
                            Text(finding.reference).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(finding.evidence).font(.caption.monospaced()).textSelection(.enabled)
                                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                            if !finding.hint.isEmpty { Text(finding.hint).font(.caption) }
                        }
                    }
                    Text("Containers").font(.headline)
                    ForEach(diagnosis.pods, id: \.name) { pod in
                        ForEach(pod.containers, id: \.name) { container in
                            HStack {
                                Text("\(pod.name)/\(container.name)").font(.caption.monospaced())
                                Text(container.state).font(.caption)
                                Spacer()
                                Text("↻\(container.restarts) · mem \(container.usage["memory"] ?? "?") / \(container.limits["memory"] ?? "∞") · cpu \(container.usage["cpu"] ?? "?") / \(container.limits["cpu"] ?? "∞")")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !diagnosis.events.isEmpty {
                        Text("Events").font(.headline)
                        ForEach(Array(diagnosis.events.prefix(30).enumerated()), id: \.offset) { _, event in
                            Text("\(event.lastSeen?.formatted(date: .omitted, time: .standard) ?? "") \(event.type) \(event.reason) \(event.object) ×\(event.count): \(event.message)")
                                .font(.caption.monospaced()).foregroundStyle(event.type == "Warning" ? .orange : .secondary).textSelection(.enabled)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            do { diagnosis = try await feature.diagnose(name) } catch { self.error = WorkspacesFeature.describe(error) }
        }
    }

    private func runDoctor() {
        guard let host = feature.host else { return }
        running = true
        Task {
            do { report = try await host.runAgent("workspaces.doctor", reason: "the user asked about workspace \(name)") }
            catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

// MARK: Config

struct WorkspaceConfigView: View {
    let name: String
    let feature: WorkspacesFeature
    @State private var changes: [WorkspaceChange]?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let folder = feature.folder(for: name)
            HStack {
                Label(folder.url.path, systemImage: "folder").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }.disabled(!folder.exists)
                Button("Check") { Task { await check() } }.disabled(working || !folder.exists)
                Button("Apply") { apply() }.disabled(working || (changes?.allSatisfy { $0.kind == .unchanged } ?? true))
                    .keyboardShortcut(.defaultAction)
            }
            if !folder.exists {
                Text("No local configuration yet. It's written when you create the workspace from Dash (in the linked worktree, like up-toolbox).")
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let changes {
                let pending = changes.filter { $0.kind != .unchanged }
                if pending.isEmpty { Label("The workspace matches the files.", systemImage: "checkmark.circle").foregroundStyle(.green) }
                List(pending) { change in
                    VStack(alignment: .leading) {
                        Text("\(change.kind == .create ? "Create" : "Update") \(change.id)").font(.callout.bold())
                        if !change.differences.isEmpty { Text(change.differences.prefix(8).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
            }
            if let context = feature.connectedClient?.kube.contextName {
                CommandBlock(label: "Same check and apply in a terminal",
                             command: "kubectl --context \(context) diff -k \(Shell.quote(folder.url.path)) -n \(name)\nkubectl --context \(context) apply -k \(Shell.quote(folder.url.path)) -n \(name)")
            }
            Spacer()
        }
        .task { if feature.folder(for: name).exists { await check() } }
    }

    private func check() async {
        working = true
        defer { working = false }
        do { changes = try await feature.pendingChanges(name); error = nil } catch { self.error = WorkspacesFeature.describe(error) }
    }

    private func apply() {
        working = true
        Task {
            do { _ = try await feature.applyConfig(name); await check() } catch { self.error = WorkspacesFeature.describe(error) }
            working = false
        }
    }
}

// MARK: Commands

struct WorkspaceCommandsView: View {
    let name: String
    let feature: WorkspacesFeature

    var body: some View {
        let steps = feature.commands(for: name)
        if steps.isEmpty {
            ContentUnavailableView("Nothing yet", systemImage: "terminal", description: Text("Each thing Dash does here shows up with the command that does the same thing."))
        } else {
            List(steps) { step in
                DisclosureGroup {
                    CommandBlock(label: "Exact (same output)", command: step.command)
                    if let familiar = step.familiar { CommandBlock(label: "Usual command", command: familiar) }
                    if !step.output.isEmpty {
                        Text(step.output).font(.caption.monospaced()).lineLimit(30).textSelection(.enabled)
                    }
                } label: {
                    HStack {
                        Image(systemName: step.failed ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(step.failed ? .red : .green)
                        Text(step.title).font(.callout)
                        Spacer()
                        Text(step.at, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: Train (one workspace)

struct WorkspaceTrainView: View {
    let name: String
    let feature: WorkspacesFeature

    var body: some View {
        let cars = feature.train(workspace: name).map { car in
            TrainCar(id: car.id.uuidString, workspace: car.workspace, kind: car.kind, app: car.app, version: car.commit.isEmpty ? car.tag : car.commit,
                     branch: car.branch, by: car.by, at: car.startedAt, duration: car.duration, status: car.status, error: car.error)
        }
        if cars.isEmpty {
            ContentUnavailableView("No deployments yet", systemImage: "tram")
        } else {
            TrainList(cars: cars)
        }
    }
}

// MARK: Create

struct CreateWorkspaceSheet: View {
    let feature: WorkspacesFeature
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profile = "default"
    @State private var worktrees: [KnownWorktree] = []
    @State private var worktree = ""
    @State private var service = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Workspace") {
                TextField("Name", text: $name, prompt: Text("laf-5680"))
                Picker("Profile", selection: $profile) {
                    ForEach(feature.profiles) { Text("\($0.name): \($0.services.joined(separator: ", "))").tag($0.name) }
                }
                LabeledContent("Environment", value: "\(feature.env.rawValue) / \(feature.region.rawValue)")
            }
            Section("Code") {
                Picker("Worktree", selection: $worktree) {
                    Text("None").tag("")
                    ForEach(worktrees) { Text("\($0.issue.isEmpty ? $0.branch : $0.issue) · \(($0.path as NSString).abbreviatingWithTildeInPath)").tag($0.path) }
                }
                Button("Choose a Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url {
                        worktrees.append(KnownWorktree(path: url.path, branch: "", issue: ""))
                        worktree = url.path
                    }
                }
                let services = worktree.isEmpty ? [] : WorktreeBuild.services(in: URL(fileURLWithPath: worktree))
                if services.count > 1 {
                    Picker("Service to build", selection: $service) { ForEach(services, id: \.path) { Text($0.lastPathComponent).tag($0.path) } }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            let services = feature.profiles.first { $0.name == profile }?.services ?? []
            CommandBlock(label: "Same thing with up-toolbox",
                         command: "up-toolbox workspace generate --name \(name.isEmpty ? "<name>" : name.lowercased()) --env \(feature.env.rawValue) --region \(feature.region.rawValue) --services \(services.joined(separator: ","))\nup-toolbox workspace up --name \(name.isEmpty ? "<name>" : name.lowercased()) --env \(feature.env.rawValue) --region \(feature.region.rawValue)")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Create") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (try? WorkspaceGenerator.validate(name)) == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .task {
            worktrees = await feature.worktrees()
            if let first = worktrees.first, name.isEmpty {
                worktree = first.path
                name = first.suggestedName
            }
        }
        .onChange(of: worktree) {
            service = WorktreeBuild.services(in: URL(fileURLWithPath: worktree)).first?.path ?? ""
            if let known = worktrees.first(where: { $0.path == worktree }), !known.suggestedName.isEmpty { name = known.suggestedName }
        }
    }

    private func create() {
        working = true
        error = nil
        let services = feature.profiles.first { $0.name == profile }?.services ?? WorkspaceProfile.defaults[0].services
        Task {
            do {
                try await feature.create(name: name, services: services, worktree: worktree.isEmpty ? nil : worktree, service: service.isEmpty ? nil : service)
                dismiss()
            } catch {
                self.error = WorkspacesFeature.describe(error)
            }
            working = false
        }
    }
}

/// Profiles editor (Settings).
struct ProfilesEditor: View {
    @Bindable var feature: WorkspacesFeature
    @State private var newName = ""

    var body: some View {
        ForEach(feature.profiles) { profile in
            HStack {
                Text(profile.name).bold().frame(width: 90, alignment: .leading)
                TextField("Services", text: Binding(
                    get: { profile.services.joined(separator: ", ") },
                    set: { text in
                        var all = feature.profiles
                        if let index = all.firstIndex(where: { $0.name == profile.name }) {
                            all[index].services = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            feature.profiles = all
                        }
                    }))
                Button("Remove", systemImage: "minus.circle") { feature.profiles.removeAll { $0.name == profile.name } }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(profile.name == "default")
            }
        }
        HStack {
            TextField("New profile", text: $newName, prompt: Text("name"))
            Button("Add") {
                let name = newName.trimmingCharacters(in: .whitespaces).lowercased()
                guard !name.isEmpty, !feature.profiles.contains(where: { $0.name == name }) else { return }
                feature.profiles.append(WorkspaceProfile(name: name, services: ["capig", "papi"]))
                newName = ""
            }
        }
        Text("Services are comma-separated: names in the default namespace, or capig, papi, vapi, vapihb.").font(.caption).foregroundStyle(.secondary)
    }
}
