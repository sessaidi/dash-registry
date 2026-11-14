import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct JiraBoardWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// "board" shows the board's columns; "followed" lists the issues you follow.
        var mode: String
        var hideDone: Bool
        /// Which followed board ("board" mode); nil is the first one.
        var board: Int?
    }

    static let kind = "jira.board"
    static let sizeLimits = GridLimits(minW: 4, minH: 6, maxW: 12, maxH: 24)
    static let displayName = "Jira Board"
    static let summary = "Your Jira board's columns, or the issues you follow. Open a ticket to comment, move it, or start an agent on it."
    static let systemImage = "checklist"
    static let defaultSize = WidgetSize.wide
    static let defaultConfig = Config(mode: "board", hideDone: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "mode": ["type": "string", "enum": ["board", "followed"], "description": "board: columns of the configured board. followed: issues matching the follow JQL."],
            "hideDone": ["type": "boolean", "description": "Hide issues in a Done status category."],
            "board": ["type": "integer", "description": "Board id (one of the followed boards); omit for the first."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        JiraBoardView(config: config.wrappedValue, host: context.host)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Picker("Show", selection: config.mode) {
            Text("Board columns").tag("board")
            Text("Issues I follow").tag("followed")
        }
        if config.wrappedValue.mode == "board", let jira = context.host.ext(JiraBoardFeature.self), jira.boards.count > 1 {
            Picker("Board", selection: config.board) {
                ForEach(jira.boards) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        Toggle("Hide done", isOn: config.hideDone)
    }

    /// Sample tickets on a three-column board; no store, network or account.
    static func preview(config: Config) -> some View {
        JiraBoardLayout(
            config: config, tickets: JiraTicket.visible(JiraTicket.samples, config: config),
            columns: JiraClient.Column.samples, onSelect: nil)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let issues = (try? context.host.context.fetch(FetchDescriptor<JiraIssue>())) ?? []
        var config = config
        if config.board == nil { config.board = context.host.ext(JiraBoardFeature.self)?.boards.first?.id }
        let tickets = JiraTicket.visible(issues.map(JiraTicket.init), config: config)
        let keys = Set(tickets.map(\.key))
        return .array(issues.filter { keys.contains($0.key) }.map(\.json))
    }
}

/// What the board draws for one issue: a value copy of `JiraIssue`, so previews can use sample data.
struct JiraTicket: Identifiable, Hashable, Sendable {
    let key: String
    let summary: String
    let statusID: String
    let statusName: String
    let statusCategory: String
    let assignee: String?
    let onBoard: Bool
    let followed: Bool
    let url: String
    var boardIDs: [Int] = []

    var id: String { key }

    init(key: String, summary: String, statusID: String, statusName: String, statusCategory: String,
         assignee: String?, onBoard: Bool, followed: Bool, url: String) {
        self.key = key
        self.summary = summary
        self.statusID = statusID
        self.statusName = statusName
        self.statusCategory = statusCategory
        self.assignee = assignee
        self.onBoard = onBoard
        self.followed = followed
        self.url = url
    }

    @MainActor
    init(_ issue: JiraIssue) {
        self.init(key: issue.key, summary: issue.summary, statusID: issue.statusID, statusName: issue.statusName,
                  statusCategory: issue.statusCategory, assignee: issue.assignee, onBoard: issue.onBoard,
                  followed: issue.followed, url: issue.url)
        boardIDs = issue.boardIDs
    }

    /// The tickets a widget with `config` shows.
    static func visible(_ tickets: [JiraTicket], config: JiraBoardWidget.Config) -> [JiraTicket] {
        tickets.filter { ticket in
            let shown = config.mode != "board" ? ticket.followed
                : config.board.map { ticket.boardIDs.contains($0) } ?? ticket.onBoard
            return shown && !(config.hideDone && ticket.statusCategory == "done")
        }
    }

    static let samples: [JiraTicket] = [
        sample("WEB-482", "Checkout button stays disabled after editing the shipping address", "1", "To Do", "new", "Maya Chen", followed: true),
        sample("WEB-479", "Add rate limiting to the password reset endpoint", "1", "To Do", "new", nil),
        sample("WEB-475", "Migrate order history to the paginated orders API", "3", "In Progress", "indeterminate", "Sam Ortiz", followed: true),
        sample("WEB-471", "Flaky snapshot test in the invoice PDF renderer", "3", "In Progress", "indeterminate", "Priya Natarajan"),
        sample("WEB-466", "Dark mode colours for the account settings page", "10002", "Code Review", "indeterminate", "Maya Chen", followed: true),
        sample("WEB-460", "Upgrade the image CDN client to v4", "10001", "Done", "done", "Leo Martin"),
        sample("OPS-212", "Rotate the staging database credentials", "3", "In Progress", "indeterminate", "Maya Chen", onBoard: false, followed: true),
    ]

    private static func sample(_ key: String, _ summary: String, _ statusID: String, _ statusName: String, _ category: String,
                               _ assignee: String?, onBoard: Bool = true, followed: Bool = false) -> JiraTicket {
        JiraTicket(key: key, summary: summary, statusID: statusID, statusName: statusName, statusCategory: category,
                   assignee: assignee, onBoard: onBoard, followed: followed, url: "https://example.atlassian.net/browse/\(key)")
    }
}

extension JiraClient.Column {
    static let samples = [
        JiraClient.Column(name: "To Do", statusIDs: ["1"]),
        JiraClient.Column(name: "In Progress", statusIDs: ["3"]),
        JiraClient.Column(name: "Review", statusIDs: ["10002"]),
        JiraClient.Column(name: "Done", statusIDs: ["10001"]),
    ]
}

private struct JiraBoardView: View {
    let config: JiraBoardWidget.Config
    let host: any ExtensionContext
    @Query(sort: \JiraIssue.updated, order: .reverse) private var issues: [JiraIssue]
    @State private var selected: JiraTicket?

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// No board chosen: the first followed board.
    private var resolvedConfig: JiraBoardWidget.Config {
        var config = config
        if config.board == nil { config.board = jira?.boards.first?.id }
        return config
    }

    var body: some View {
        let config = resolvedConfig
        let visible = JiraTicket.visible(issues.map(JiraTicket.init), config: config)
        Group {
            if let jira, (try? jira.client) == nil {
                setupPrompt
            } else if visible.isEmpty {
                ContentUnavailableView(
                    jira?.isSyncing == true ? "Syncing…" : "No issues", systemImage: "checklist",
                    description: Text(jira?.lastError ?? (config.mode == "board" && jira?.boardID.isEmpty == true ? "Follow a board in Settings › Jira." : "")))
            } else {
                JiraBoardLayout(config: config, tickets: visible, columns: jira?.columns(board: config.board) ?? []) { selected = $0 }
            }
        }
        .sheet(item: $selected) { JiraIssueSheet(issue: $0, host: host) }
    }

    private var setupPrompt: some View {
        ContentUnavailableView {
            Label("Connect Jira", systemImage: "checklist")
        } description: {
            Text("Add your site, email and API token.")
        } actions: {
            Button("Connect Atlassian…") { host.openManager("atlassian") }
        }
    }
}

/// Columns (board mode with a known column layout) or a list; shared by the widget and its preview.
private struct JiraBoardLayout: View {
    let config: JiraBoardWidget.Config
    let tickets: [JiraTicket]
    let columns: [JiraClient.Column]
    /// nil in previews: cards aren't tappable.
    let onSelect: ((JiraTicket) -> Void)?

    var body: some View {
        if config.mode == "board", !columns.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(columns, id: \.name) { column in
                        let cards = tickets.filter { column.statusIDs.contains($0.statusID) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(column.name.uppercased())  \(cards.count)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(cards) { issue in IssueCard(issue: issue).onTapGesture { onSelect?(issue) } }
                                }
                            }
                        }
                        .frame(width: 220)
                    }
                }
            }
        } else {
            List(tickets) { issue in
                IssueRow(issue: issue).contentShape(.rect).onTapGesture { onSelect?(issue) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct IssueCard: View {
    let issue: JiraTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue.summary).font(.callout).lineLimit(3)
            HStack {
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let assignee = issue.assignee {
                    Text(assignee.split(separator: " ").compactMap(\.first).map(String.init).joined())
                        .font(.caption2.bold())
                        .padding(4)
                        .background(.tint.opacity(0.2), in: .circle)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }
}

private struct IssueRow: View {
    let issue: JiraTicket

    var body: some View {
        HStack {
            StatusPill(name: issue.statusName, category: issue.statusCategory)
            VStack(alignment: .leading) {
                Text(issue.summary).lineLimit(1)
                Text("\(issue.key) · \(issue.assignee ?? "Unassigned")").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    let name: String
    let category: String

    var body: some View {
        Badge(name, tone: category == "done" ? .success : category == "indeterminate" ? .info : .neutral)
    }
}

struct JiraIssueSheet: View {
    let issue: JiraTicket
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @State private var detail: JSONValue?
    @State private var transitions: [(id: String, name: String)] = []
    @State private var comment = ""
    @State private var error: String?
    @State private var busy = false

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// The Agents feature's tools, reached by id so this plugin doesn't link another plugin.
    private func agentsTool(_ name: String) -> ClaudeTool? {
        host.extensions.first { $0.id == "agents" && host.isEnabled($0) }?.tools.first { $0.name == name }
    }

    private var startAgent: ClaudeTool? { agentsTool("agents_start") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(issue.key).font(.headline.monospaced())
                StatusPill(name: issue.statusName, category: issue.statusCategory)
                Spacer()
                if let url = URL(string: issue.url) { Link("Open in Jira", destination: url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(issue.summary).font(.title3.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail {
                        Text(detail["description"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "No description.")
                            .textSelection(.enabled)
                        if let comments = detail["comments"]?.array, !comments.isEmpty {
                            Divider()
                            ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(comment["author"]?.string ?? "").font(.caption.bold())
                                    Text(comment["body"]?.string ?? "").font(.callout).textSelection(.enabled)
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                TextField("Comment", text: $comment)
                Button("Post") { run { try await jira?.client.comment(issue.key, text: comment); comment = "" } }
                    .disabled(comment.isEmpty || busy)
            }
            HStack {
                Menu("Move to") {
                    ForEach(transitions, id: \.id) { transition in
                        Button(transition.name) { run { _ = try await jira?.move(issue.key, toStatus: transition.name) } }
                    }
                }
                .fixedSize()
                .disabled(transitions.isEmpty || busy)
                Button("Ask Claude", systemImage: "sparkles") {
                    host.askClaude("Look at Jira issue \(issue.key) and suggest how to approach it.")
                    dismiss()
                }
                Spacer()
                Button("Start Agent", systemImage: "hammer") {
                    run {
                        guard let startAgent else { return }
                        let session = try await startAgent.run(["issue_key": .string(issue.key)])
                        dismiss()
                        // The Agents plugin owns its chat windows; ask it to open this one.
                        if let id = session["id"]?.string {
                            _ = try? await agentsTool("agents_open")?.run(["session_id": .string(id)])
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || startAgent == nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            guard let client = try? jira?.client else { return }
            detail = try? await client.issueDetail(issue.key)
            transitions = (try? await client.transitions(issue.key)) ?? []
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await action() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
