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
    static let defaultConfig = Config(mode: "followed", hideDone: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "mode": ["type": "string", "enum": ["board", "followed"], "description": "board: columns of the configured board. followed: issues matching the follow JQL."],
            "hideDone": ["type": "boolean", "description": "Hide issues in a Done status category."],
            "board": ["type": "integer", "description": "Board id (one of the followed boards); omit for the first."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        JiraBoardView(config: config, host: context.host, query: context.query(fields: JiraIssue.queryFields), queryText: context.queryText)
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

    static let actions = JiraBoardActions.actions
    static let queryFields = JiraIssue.queryFields

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let issues = (try? context.host.context.fetch(FetchDescriptor<JiraIssue>())) ?? []
        var config = config
        let jira = context.host.ext(JiraBoardFeature.self)
        if config.board == nil { config.board = jira?.boards.first?.id }
        let tickets = JiraTicket.visible(issues.map(JiraTicket.init), config: config)
        let keys = Set(tickets.map(\.key))
        return [
            "explanation": """
                Jira issues from Dash's local copy. mode board: the issues on a followed board, grouped in the board's \
                columns (each column holds one or more statuses); mode followed: the issues the user follows. status is the \
                issue's Jira status; status_category new = not started, indeterminate = in progress, done = finished.
                """,
            "mode": .string(config.mode),
            "board": jira?.boards.first { $0.id == config.board }.map { .string($0.name) } ?? .null,
            "columns": .array((jira?.columns(board: config.board) ?? []).map { column in
                ["name": .string(column.name), "issues": .number(Double(tickets.filter { column.statusIDs.contains($0.statusID) }.count))]
            }),
            "issues": .array(issues.filter { keys.contains($0.key) }.map(\.json)),
        ]
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
    @Binding var config: JiraBoardWidget.Config
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after the mode and Dashii's narrowing.
    let query: WidgetQuery?
    let queryText: String
    @State private var queryKeys: [String]?
    @Query(sort: \JiraIssue.updated, order: .reverse) private var issues: [JiraIssue]
    /// The issue whose detail sheet is open.
    @State private var opened: JiraTicket?
    /// The issue the user picked: highlighted, and published for linked widgets until another is
    /// picked or it's clicked again.
    @State private var selectedKey: String?
    /// What Dashii's actions changed for now (mode, board, hide done). Not saved: it resets when
    /// the widget's settings change; the settings keep their values.
    @State private var override: JiraBoardWidget.Config?
    /// What Dashii narrowed the board to (not saved): text, and a column or status.
    @State private var search = ""
    @State private var status = ""
    @State private var following = false

    private var jira: JiraBoardFeature? { host.ext(JiraBoardFeature.self) }

    /// The settings with Dashii's temporary changes on top.
    private var effective: JiraBoardWidget.Config { override ?? config }

    /// No board chosen: the first followed board.
    private var resolvedConfig: JiraBoardWidget.Config {
        var config = effective
        if config.board == nil { config.board = jira?.boards.first?.id }
        return config
    }

    /// What the board shows: the mode and Dashii's narrowing, then the DashQL query.
    private var visible: [JiraTicket] { QueryRows.ordered(narrowed, by: queryKeys) }

    private func row(_ ticket: JiraTicket) -> JSONValue {
        issues.first { $0.key == ticket.key }?.queryRow ?? ["key": .string(ticket.key), "summary": .string(ticket.summary)]
    }

    private var narrowed: [JiraTicket] {
        let config = resolvedConfig
        return JiraBoardActions.filter(JiraTicket.visible(issues.map(JiraTicket.init), config: config), search: search, status: status,
                                       columns: jira?.columns(board: config.board) ?? [])
    }

    var body: some View {
        board
            // Follow a ticket from here: key, link or a few words.
            .overlay(alignment: .topTrailing) {
                if let jira, (try? jira.client) != nil {
                    HStack(spacing: 8) {
                        QueryCount(shown: visible.count, total: narrowed.count, query: queryText)
                        // The user's own switch is saved (and drops Dashii's temporary mode).
                        Picker("Show", selection: Binding(get: { effective.mode }, set: { config.mode = $0; override = nil })) {
                            Text("Board").tag("board")
                            Text("Following \(issues.filter { $0.followed && !(effective.hideDone && $0.statusCategory == "done") }.count)").tag("followed")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                        Button("Follow a Ticket", systemImage: "plus") { following = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Follow a ticket: paste its key or link, or search")
                            .popover(isPresented: $following, arrowEdge: .bottom) { FollowTicketPopover(jira: jira) }
                    }
                    .offset(y: -34)
                }
            }
            .handlesWidgetActions { name, input in
                if name == "clear_selection" {
                    selectedKey = nil
                    return "cleared"
                }
                let columns = jira?.columns(board: resolvedConfig.board) ?? []
                // Actions change what's shown for now, never the saved settings.
                var view = effective
                let outcome = try JiraBoardActions.perform(name, input, config: &view, search: &search, status: &status,
                                                           tickets: visible, boards: (jira?.boards ?? []).map { ($0.id, $0.name) }, columns: columns)
                // `clear` also drops Dashii's temporary mode, board and hide-done.
                override = name == "clear" || view == config ? nil : view
                if let ticket = outcome.select {
                    selectedKey = ticket.key
                    opened = ticket
                }
                return outcome.reply
            }
            .onChange(of: config) { override = nil }
            .onExitCommand { selectedKey = nil }
            .reportsSelection(selectedKey.flatMap { key in issues.first { $0.key == key }?.queryRow })
            .reportsWidgetState(state)
            .task(id: QueryRows.key(queryText, narrowed, row: row)) {
                queryKeys = await QueryRows.ids(query, narrowed, row: row)
            }
    }

    private var state: JSONValue {
        let config = resolvedConfig
        let visible = visible
        return [
            "mode": .string(config.mode), "hide_done": .bool(config.hideDone),
            "board": jira?.boards.first { $0.id == config.board }.map { .string($0.name) } ?? .null,
            "search": search.isEmpty ? .null : .string(search), "status": status.isEmpty ? .null : .string(status),
            "shown": .array(visible.prefix(40).map { .string("\($0.key) [\($0.statusName)] \($0.summary)") }),
            "open_issue": opened.map { .string($0.key) } ?? .null,
            "selected": selectedKey.map(JSONValue.string) ?? .null,
            "temporary_changes": .bool(override != nil),
        ]
    }

    private var board: some View {
        let config = resolvedConfig
        let visible = visible
        return Group {
            if let jira, (try? jira.client) == nil {
                setupPrompt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if config.mode == "followed", visible.isEmpty, jira?.isSyncing != true {
                // Following nothing yet (or nothing left after hiding done): say so and offer to follow.
                ContentUnavailableView {
                    Label(jira?.followedKeys.isEmpty == false ? "Nothing to show" : "You don't follow any ticket", systemImage: "star")
                } description: {
                    Text(jira?.followedKeys.isEmpty == false
                         ? "The tickets you follow are done or hidden. Turn off “Hide done” to see them."
                         : "Follow tickets to see them here, in columns by status. Nothing changes in Jira.")
                } actions: {
                    Button("Follow a Ticket…", systemImage: "plus") { following = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView {
                    Label(jira?.isSyncing == true ? "Syncing…" : "No issues", systemImage: "checklist")
                } description: {
                    Text(jira?.lastError ?? (config.mode == "board" && jira?.boardID.isEmpty == true ? "Follow a board in Settings › Jira, or follow tickets here." : ""))
                } actions: {
                    if jira != nil { Button("Follow a Ticket…", systemImage: "plus") { following = true } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JiraBoardLayout(config: config, tickets: visible,
                                columns: config.mode == "board" ? jira?.columns(board: config.board) ?? [] : JiraBoardLayout.statusColumns(visible)) { pick($0) }
                    .environment(\.jiraSelectedKey, selectedKey)
            }
        }
        .sheet(item: $opened) { JiraIssueSheet(issue: $0, host: host) }
    }

    /// Clicking an issue selects it and opens its detail; clicking the selected one again unselects it.
    private func pick(_ ticket: JiraTicket) {
        if selectedKey == ticket.key {
            selectedKey = nil
        } else {
            selectedKey = ticket.key
            opened = ticket
        }
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
    /// Column colours from to-do (grey) through work (blue, purple) to done (green).
    static func color(_ index: Int, of count: Int) -> Color {
        guard count > 1 else { return .blue }
        if index == 0 { return .gray }
        if index == count - 1 { return .green }
        return [Color.blue, .orange, .purple, .teal, .pink, .indigo][(index - 1) % 6]
    }

    /// Followed tickets come from many boards: one column per status, to do → in progress → done.
    static func statusColumns(_ tickets: [JiraTicket]) -> [JiraClient.Column] {
        let order = ["new": 0, "indeterminate": 1, "done": 2]
        var seen: [String: (rank: Int, ids: Set<String>)] = [:]
        for ticket in tickets {
            seen[ticket.statusName, default: (order[ticket.statusCategory] ?? 1, [])].ids.insert(ticket.statusID)
        }
        return seen.sorted { ($0.value.rank, $0.key) < ($1.value.rank, $1.key) }
            .map { JiraClient.Column(name: $0.key, statusIDs: Array($0.value.ids)) }
    }

    let config: JiraBoardWidget.Config
    let tickets: [JiraTicket]
    let columns: [JiraClient.Column]
    /// nil in previews: cards aren't tappable.
    let onSelect: ((JiraTicket) -> Void)?

    var body: some View {
        if !columns.isEmpty {
            GeometryReader { geometry in
                // Columns share the width when they fit, else keep 240 pt and scroll sideways.
                let spacing = 10.0
                let width = max(240, (geometry.size.width - spacing * Double(columns.count - 1)) / Double(columns.count))
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(Array(columns.enumerated()), id: \.element.name) { index, column in
                            let cards = tickets.filter { column.statusIDs.contains($0.statusID) }
                            BoardColumn(name: column.name, color: Self.color(index, of: columns.count), cards: cards, onSelect: onSelect)
                                .frame(width: width)
                                .frame(maxHeight: geometry.size.height, alignment: .top)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
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

/// One board column: a lane with its name, count and cards.
private struct BoardColumn: View {
    let name: String
    let color: Color
    let cards: [JiraTicket]
    let onSelect: ((JiraTicket) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name.uppercased()).font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
                Text("\(cards.count)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            if cards.isEmpty {
                Text("Nothing here").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(cards) { issue in
                            IssueCard(issue: issue, accent: color).onTapGesture { onSelect?(issue) }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }
}

extension EnvironmentValues {
    /// The issue picked on the board, drawn as selected.
    @Entry var jiraSelectedKey: String? = nil
}

private struct IssueCard: View {
    let issue: JiraTicket
    var accent: Color = .accentColor
    @State private var hovering = false
    @Environment(\.jiraSelectedKey) private var selectedKey
    private var isSelected: Bool { selectedKey == issue.key }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.summary).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(issue.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let assignee = issue.assignee {
                    Text(assignee.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined())
                        .font(.caption2.bold())
                        .frame(width: 22, height: 22)
                        .background(.tint.opacity(0.22), in: .circle)
                        .help(assignee)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(.background.secondary), in: .rect(cornerRadius: 9))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 9).fill(accent.opacity(0.8)).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? AnyShapeStyle(accent) : hovering ? AnyShapeStyle(accent.opacity(0.6)) : AnyShapeStyle(.separator.opacity(0.6)),
                                                                lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 6 : 2, y: 1)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct IssueRow: View {
    let issue: JiraTicket
    @Environment(\.jiraSelectedKey) private var selectedKey

    var body: some View {
        HStack {
            StatusPill(name: issue.statusName, category: issue.statusCategory)
            VStack(alignment: .leading) {
                Text(issue.summary).lineLimit(1)
                Text("\(issue.key) · \(issue.assignee ?? "Unassigned")").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(selectedKey == issue.key ? Color.accentColor.opacity(0.18) : Color.clear)
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

/// What Dashii can do with the Jira board widget. Only what it shows changes, and only for now:
/// the widget's saved settings and Jira itself are untouched.
enum JiraBoardActions {
    static let actions = [
        WidgetAction(name: "search", description: "Narrow the board to issues whose key, summary, assignee or status contains the text. Empty clears it.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
        WidgetAction(name: "filter_status", description: "Only one column or status (e.g. In Progress, Code Review); empty shows every column.",
                     properties: ["status": JSONSchema.string("Column or status name.")], required: ["status"]),
        WidgetAction(name: "set_mode", description: "Show the board's columns, or the issues the user follows. Temporary: the widget's saved setting stays.",
                     properties: ["mode": JSONSchema.string("board or followed.", enum: ["board", "followed"])], required: ["mode"]),
        WidgetAction(name: "set_board", description: "Show another followed board, by name or id. Temporary: the widget's saved board stays.",
                     properties: ["board": JSONSchema.string("Board name or id.")], required: ["board"]),
        WidgetAction(name: "hide_done", description: "Hide (on) or show (off) finished issues. Temporary: the widget's saved setting stays.",
                     properties: ["on": JSONSchema.boolean("true to hide done issues.")], required: ["on"]),
        WidgetAction(name: "select_issue", description: "Select an issue by key and open its detail; linked widgets follow the selection.",
                     properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234.")], required: ["key"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected issue."),
        WidgetAction(name: "clear", description: "Clear the search, status filter and Dashii's temporary mode, board and hide-done (back to the widget's settings)."),
    ]

    struct Outcome {
        var reply: JSONValue
        var select: JiraTicket?
    }

    /// The tickets matching a search and a column (by name) or status name.
    static func filter(_ tickets: [JiraTicket], search: String, status: String, columns: [JiraClient.Column]) -> [JiraTicket] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = status.trimmingCharacters(in: .whitespaces).lowercased()
        let column = columns.first { $0.name.lowercased() == wanted }
        return tickets.filter { ticket in
            (text.isEmpty || [ticket.key, ticket.summary, ticket.assignee ?? "", ticket.statusName].contains { $0.lowercased().contains(text) })
                && (wanted.isEmpty || column.map { $0.statusIDs.contains(ticket.statusID) } ?? (ticket.statusName.lowercased() == wanted))
        }
    }

    static func perform(_ name: String, _ input: JSONValue, config: inout JiraBoardWidget.Config, search: inout String, status: inout String,
                        tickets: [JiraTicket], boards: [(id: Int, name: String)], columns: [JiraClient.Column]) throws -> Outcome {
        switch name {
        case "search":
            search = input["text"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return Outcome(reply: ["search": search.isEmpty ? .null : .string(search)])
        case "filter_status":
            let wanted = input["status"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            let known = columns.map(\.name) + tickets.map(\.statusName)
            if !wanted.isEmpty, !known.contains(where: { $0.lowercased() == wanted.lowercased() }) {
                throw ToolError("No column or status “\(wanted)”. Columns: \(columns.map(\.name).joined(separator: ", ")).")
            }
            status = wanted
            return Outcome(reply: ["status": wanted.isEmpty ? .null : .string(wanted)])
        case "set_mode":
            guard let mode = input["mode"]?.string, ["board", "followed"].contains(mode) else { throw ToolError("Mode is board or followed.") }
            config.mode = mode
            return Outcome(reply: ["mode": .string(mode)])
        case "set_board":
            let wanted = input["board"]?.string ?? input["board"]?.int.map(String.init) ?? ""
            guard let board = boards.first(where: { String($0.id) == wanted || $0.name.lowercased() == wanted.lowercased() })
                    ?? boards.first(where: { $0.name.lowercased().contains(wanted.lowercased()) }), !wanted.isEmpty else {
                throw ToolError("No followed board “\(wanted)”. Boards: \(boards.map(\.name).joined(separator: ", ")).")
            }
            config.mode = "board"
            config.board = board.id
            return Outcome(reply: ["board": .string(board.name)])
        case "hide_done":
            config.hideDone = input["on"]?.bool ?? true
            return Outcome(reply: ["hide_done": .bool(config.hideDone)])
        case "select_issue":
            let key = input["key"]?.string?.uppercased() ?? ""
            guard let ticket = tickets.first(where: { $0.key == key }) else { throw ToolError("\(key) isn't on this widget.") }
            return Outcome(reply: ["opened": .string(ticket.key)], select: ticket)
        case "clear":
            search = ""
            status = ""
            return Outcome(reply: "cleared")
        default:
            throw ToolError("Unknown action \(name).")
        }
    }
}

/// Follow tickets from the widget: a key, a browse link, or words to search; and the ones
/// followed, to unfollow. Following is local: nothing changes in Jira.
struct FollowTicketPopover: View {
    let jira: JiraBoardFeature
    @State private var query = ""
    @State private var results: [JiraClient.Issue] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow a ticket").font(.headline)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("LAF-1234, a Jira link, or words to search", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            if let key = directKey {
                row(key: key, title: jira.issue(key)?.summary ?? "Follow \(key)", followed: jira.followedKeys.contains(key))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(results, id: \.key) { issue in
                            row(key: issue.key, title: issue.summary, subtitle: issue.statusName, followed: jira.followedKeys.contains(issue.key))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            if !jira.followedKeys.isEmpty {
                Divider()
                Text("Following \(jira.followedKeys.count)").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(jira.followedKeys, id: \.self) { key in
                            row(key: key, title: jira.issue(key)?.summary ?? "", subtitle: jira.issue(key)?.statusName, followed: true)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            Text("Followed tickets sync into the board; nothing changes in Jira.").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 420)
        .task(id: query) {
            // Words search Jira after a pause; keys and links follow directly.
            guard directKey == nil, query.trimmingCharacters(in: .whitespaces).count >= 3 else { results = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    /// A key typed or found in a pasted link (…/browse/LAF-123, ?selectedIssue=LAF-123).
    private var directKey: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if JiraBoardFeature.isIssueKey(text) { return text }
        if let match = text.firstMatch(of: /(?:BROWSE\/|SELECTEDISSUE=)([A-Z][A-Z0-9_]+-\d+)/) { return String(match.output.1) }
        return nil
    }

    private func submit() {
        if let key = directKey {
            Task { await jira.follow(key) }
            query = ""
        } else {
            Task { await runSearch() }
        }
    }

    private func runSearch() async {
        let words = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        guard !words.isEmpty else { return }
        searching = true
        error = nil
        do {
            results = try await jira.client.search("text ~ \"\(words)\" ORDER BY updated DESC", limit: 15)
        } catch {
            self.error = error.localizedDescription
        }
        searching = false
    }

    private func row(key: String, title: String, subtitle: String? = nil, followed: Bool) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.tint.opacity(0.12), in: .capsule)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? key : title).font(.callout).lineLimit(1)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 6)
            if followed {
                Button("Unfollow") { Task { await jira.unfollow(key) } }.controlSize(.small)
            } else {
                Button("Follow") { Task { await jira.follow(key) } }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}
