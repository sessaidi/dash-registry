import DashKit
import DashKitUI
import AppKit
import SwiftData
import SwiftUI

struct AgentsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var showFinished: Bool
    }

    static let kind = "agents.sessions"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let displayName = "Agents"
    static let summary = "Claude Code agents working on Jira tickets in their own git worktrees. Open one to discuss the plan and follow its TDD progress."
    static let systemImage = "hammer"
    static let defaultConfig = Config(showFinished: true)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["showFinished": ["type": "boolean", "description": "Include sessions that already have a PR."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        AgentList(showFinished: config.wrappedValue.showFinished, host: context.host)
    }

    static func preview(config: Config) -> some View {
        AgentRows(rows: AgentSummary.visible(AgentSummary.samples, showFinished: config.showFinished), open: { _ in })
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let sessions = (try? context.host.context.fetch(FetchDescriptor<AgentSession>())) ?? []
        return .array(sessions.filter { config.showFinished || $0.prURL == nil }.map(\.json))
    }
}

private struct AgentList: View {
    let showFinished: Bool
    let host: any ExtensionContext
    @Query(sort: \AgentSession.updatedAt, order: .reverse) private var sessions: [AgentSession]

    var body: some View {
        AgentRows(rows: AgentSummary.visible(sessions.map(AgentSummary.init), showFinished: showFinished)) { id in
            host.ext(AgentsExtension.self)?.openWindow(id)
        }
    }
}

/// The session list, fed by the store or by samples.
private struct AgentRows: View {
    let rows: [AgentSummary]
    let open: (UUID) -> Void

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("No agents", systemImage: "hammer", description: Text("Open a Jira ticket and choose Start Agent."))
        } else {
            List(rows) { row in
                HStack {
                    AgentStatusDot(status: row.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.issueKey) · \(row.title)").lineLimit(1)
                        Text("\(row.phase) · \(row.branch) · $\(row.costUSD, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if row.hasPullRequest { Image(systemName: "arrow.triangle.pull").foregroundStyle(.green) }
                }
                .contentShape(.rect)
                .onTapGesture { open(row.id) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct AgentStatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(status == "running" ? Color.blue : status == "failed" ? .red : .green)
            .frame(width: 8, height: 8)
            .help(status)
    }
}

/// One AppKit window per agent session. Plugins can't add SwiftUI scenes to Dash, so the
/// chat lives in an `NSWindow` sharing the host's model context.
@MainActor
final class AgentWindows {
    static let shared = AgentWindows()
    private var windows: [UUID: NSWindow] = [:]

    func open(sessionID: UUID, agents: AgentsExtension, host: any ExtensionContext) {
        if let window = windows[sessionID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = AgentWorkspaceWindow(sessionID: sessionID, agents: agents).modelContext(host.context)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        let session = agents.session(sessionID)
        window.title = session.map { "\($0.issueKey) — \($0.title)" } ?? "Agent"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("agent-workspace-\(sessionID.uuidString)")
        windows[sessionID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct AgentChatWindow: View {
    let sessionID: UUID
    let agents: AgentsExtension
    @Query private var sessions: [AgentSession]
    @Query private var messages: [AgentMessage]
    @State private var draft = ""
    @State private var error: String?
    @State private var creatingPR = false

    init(sessionID: UUID, agents: AgentsExtension) {
        self.sessionID = sessionID
        self.agents = agents
        _sessions = Query(filter: #Predicate<AgentSession> { $0.id == sessionID })
        _messages = Query(filter: #Predicate<AgentMessage> { $0.sessionID == sessionID }, sort: \.sequence)
    }

    var body: some View {
        if let session = sessions.first {
            VStack(spacing: 0) {
                header(session)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { AgentMessageView(message: $0) }
                            if session.status == "running" {
                                ProgressView().controlSize(.small).id("progress")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                    }
                    .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout).padding(8) }
                Divider()
                composer(session)
            }
            .navigationTitle("\(session.issueKey) — \(session.title)")
            .frame(minWidth: 560, minHeight: 480)
        } else {
            ContentUnavailableView("Agent not found", systemImage: "hammer")
        }
    }

    private func header(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            AgentStatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.branch).font(.callout.monospaced())
                Text("\(session.phase) · from \(session.baseRef) · $\(session.costUSD, specifier: "%.2f")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: session.worktreePath)])
            }
            Button("Terminal", systemImage: "terminal") {
                if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                    NSWorkspace.shared.open([URL(filePath: session.worktreePath)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            if session.phase == "planning" {
                Button("Implement", systemImage: "play.fill") { agents.implement(session) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.status == "running")
                    .help("Agree the plan and start the TDD loop")
            }
            if let url = session.prURL.flatMap(URL.init(string:)) {
                Link("Open PR", destination: url)
            } else {
                Button("Create PR", systemImage: "arrow.triangle.pull") {
                    creatingPR = true
                    error = nil
                    Task {
                        do { _ = try await agents.createPullRequest(session) } catch { self.error = error.localizedDescription }
                        creatingPR = false
                    }
                }
                .disabled(session.status == "running" || creatingPR)
                .help("Push the branch and open a draft PR")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(12)
    }

    private func composer(_ session: AgentSession) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(session.phase == "planning" ? "Discuss the plan…" : "Steer the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onSubmit { send(session) }
            if session.status == "running" {
                Button("Stop", systemImage: "stop.circle.fill") { agents.cancel(session) }
                    .labelStyle(.iconOnly).font(.title2).buttonStyle(.borderless)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send(session) }
                    .labelStyle(.iconOnly).font(.title2).buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func send(_ session: AgentSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session.status != "running" else { return }
        agents.send(session, message: text)
        draft = ""
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        case "tool":
            Label(message.text, systemImage: "wrench.and.screwdriver")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case "error":
            Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case "info":
            Label(message.text, systemImage: "info.circle").foregroundStyle(.secondary)
        default:
            // Dash's block-level MarkdownText is app-internal; inline Markdown keeps line breaks.
            Text(Self.markdown(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}


/// An agent's window: the worktree's files on the left (changes marked), and the conversation,
/// the changes against the base, and the selected file on the right. Clicking a changed line
/// shows that file in the tree and opens it at the line.
struct AgentWorkspaceWindow: View {
    let sessionID: UUID
    let agents: AgentsExtension
    @Query private var sessions: [AgentSession]
    @State private var state: WorktreeState?
    @State private var tab = "chat"
    @State private var onlyChanged = false

    init(sessionID: UUID, agents: AgentsExtension) {
        self.sessionID = sessionID
        self.agents = agents
        _sessions = Query(filter: #Predicate<AgentSession> { $0.id == sessionID })
    }

    var body: some View {
        if let session = sessions.first {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Files", selection: $onlyChanged) {
                            Text("All").tag(false)
                            Text("Changed (\(state?.diffs.count ?? 0))").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await state?.reload() } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    .padding(8)
                    if let state { FileTreeView(state: state, onlyChanged: onlyChanged) } else { Spacer() }
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                VStack(spacing: 0) {
                    Picker("View", selection: $tab) {
                        Text("Chat").tag("chat")
                        Text("Changes\(state.map { $0.diffs.isEmpty ? "" : " (\($0.diffs.count))" } ?? "")").tag("changes")
                        Text(state?.selectedFile.map { ($0 as NSString).lastPathComponent } ?? "File").tag("file")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(8)
                    Divider()
                    switch tab {
                    case "changes":
                        if let state {
                            ChangesView(state: state) { path, line in
                                state.reveal(path, line: line)
                                tab = "file"
                            }
                        }
                    case "file":
                        if let state, let path = state.selectedFile {
                            FileContentView(state: state, path: path)
                        } else {
                            ContentUnavailableView("Pick a file", systemImage: "doc.text", description: Text("In the tree, or click a changed line."))
                        }
                    default:
                        AgentChatWindow(sessionID: sessionID, agents: agents)
                    }
                }
                .frame(minWidth: 520)
            }
            .onChange(of: state?.selectedFile) { if tab == "chat", state?.selectedFile != nil { tab = "file" } }
            .task(id: session.worktreePath) {
                let model = WorktreeState(root: URL(fileURLWithPath: session.worktreePath), base: session.baseRef)
                state = model
                await model.reload()
            }
            // Refresh while the agent works and when a turn ends.
            .task(id: session.status) {
                while !Task.isCancelled {
                    await state?.reload()
                    guard session.status == "running" else { break }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } else {
            ContentUnavailableView("Agent not found", systemImage: "hammer")
        }
    }
}
