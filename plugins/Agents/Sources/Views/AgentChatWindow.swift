import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// An agent session's conversation: messages, the composer, and opening a draft PR.
struct AgentChatWindow: View {
    let sessionID: UUID
    let agents: AgentsExtension
    @Query private var sessions: [AgentSession]
    @Query private var messages: [AgentMessage]
    @State private var draft = ""
    @State private var error: String?
    @State private var creatingPR = false
    @State private var reviewing: PullRequestDraft?

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        do { reviewing = try await agents.draftPullRequest(session) } catch { self.error = error.localizedDescription }
                        creatingPR = false
                    }
                }
                .disabled(session.status == "running" || creatingPR)
                .help("Draft the PR, review its title and description, then confirm to push and open it")
                .sheet(item: $reviewing) { draft in
                    PullRequestReview(draft: draft, session: session, agents: agents) { reviewing = nil }
                }
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

/// One message, styled by role.
struct AgentMessageView: View {
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
