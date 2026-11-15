import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

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
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shows the drafted PR before anything is pushed: the title and description are editable,
/// Dashii answers questions about them, and only Create pushes the branch and opens the PR.
struct PullRequestReview: View {
    @State var draft: PullRequestDraft
    let session: AgentSession
    let agents: AgentsExtension
    let dismiss: () -> Void
    @State private var question = ""
    @State private var answers: [(question: String, answer: String)] = []
    @State private var asking = false
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review the pull request").font(.title3.weight(.semibold))
            Text("\(draft.branch) → \(draft.base) · \(draft.repoTemplate ? "repository template" : "global template")")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.body)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if !answers.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(answers.enumerated()), id: \.offset) { _, item in
                            Text(item.question).font(.callout.weight(.medium))
                            Text(LocalizedStringKey(item.answer)).font(.callout).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
            HStack {
                TextField("Ask Dashii about the title or description…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button("Ask", systemImage: "sparkles", action: ask).disabled(question.isEmpty || asking)
                if asking { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Create pushes \(draft.branch) and opens a draft PR on GitHub.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss).keyboardShortcut(.cancelAction)
                Button("Create Draft PR") {
                    creating = true
                    error = nil
                    Task {
                        do { _ = try await agents.createPullRequest(session, draft: draft); dismiss() } catch { self.error = error.localizedDescription }
                        creating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.isEmpty || creating)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        question = ""
        Task {
            do { answers.append((text, try await agents.explain(draft, question: text, session: session))) } catch { self.error = error.localizedDescription }
            asking = false
        }
    }
}

extension PullRequestDraft: Identifiable {
    var id: String { branch }
}

/// Per-repository PR templates; repositories without one use the global template.
struct PullRequestTemplatesSection: View {
    let agents: AgentsExtension
    @Query(sort: \PullRequestTemplate.repoPath) private var templates: [PullRequestTemplate]

    var body: some View {
        Section {
            ForEach(templates) { template in
                DisclosureGroup((template.repoPath as NSString).lastPathComponent) {
                    TextField("Title", text: Bindable(template).title)
                    TextEditor(text: Bindable(template).body)
                        .font(.body.monospaced())
                        .frame(height: 90)
                    Button("Remove", role: .destructive) { template.modelContext?.delete(template) }
                }
            }
            Menu("Add Repository Template") {
                ForEach(candidates, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { add(path) }
                }
                if !candidates.isEmpty { Divider() }
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Add"
                    if panel.runModal() == .OK, let url = panel.url { add(url.standardizedFileURL.path) }
                }
            }
            .fixedSize()
        } header: {
            Text("Pull request templates")
        } footer: {
            Text("The global template is in AI › Opening pull requests. A repository's template replaces it. Placeholders: {{issue_key}}, {{issue_title}}, {{ticket_url}}, {{summary}}, {{branch}}, {{base}}.")
        }
    }

    /// Repositories agents worked in that have no template yet.
    private var candidates: [String] {
        let sessions = (try? agents.host?.context.fetch(FetchDescriptor<AgentSession>())) ?? []
        return Array(Set(sessions.map(\.repoPath))).filter { path in !templates.contains { $0.repoPath == path } }.sorted()
    }

    private func add(_ path: String) {
        guard let context = agents.host?.context, !templates.contains(where: { $0.repoPath == path }) else { return }
        let task = AgentsExtension.pullRequestTask.id
        context.insert(PullRequestTemplate(repoPath: path, title: agents.ai.template(task, "title"), body: agents.ai.template(task, "body")))
        try? context.save()
    }
}
