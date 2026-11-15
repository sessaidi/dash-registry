import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Same entity name and attributes as the built-in feature's model, so existing stores keep their issues.
@Model
final class JiraIssue {
    @Attribute(.unique) var key: String
    var summary: String
    var statusID: String
    var statusName: String
    var statusCategory: String
    var assignee: String?
    var priority: String?
    var issueType: String?
    var updated: Date?
    var labels: [String]
    /// On the configured board (active sprint for scrum boards).
    var onBoard: Bool
    /// Matched the "following" JQL (assigned to or watched by you, by default), or followed by key.
    var followed: Bool
    /// The followed boards it's on.
    var boardIDs: [Int] = []
    /// Followed one by one (by key), not through the JQL.
    var pinned: Bool = false
    var url: String

    init(_ issue: JiraClient.Issue, url: URL) {
        key = issue.key
        summary = issue.summary
        statusID = issue.statusID
        statusName = issue.statusName
        statusCategory = issue.statusCategory
        assignee = issue.assignee
        priority = issue.priority
        issueType = issue.issueType
        updated = issue.updated
        labels = issue.labels
        onBoard = false
        followed = false
        self.url = url.absoluteString
    }

    func apply(_ issue: JiraClient.Issue) {
        if summary != issue.summary { summary = issue.summary }
        if statusID != issue.statusID { statusID = issue.statusID }
        if statusName != issue.statusName { statusName = issue.statusName }
        if statusCategory != issue.statusCategory { statusCategory = issue.statusCategory }
        if assignee != issue.assignee { assignee = issue.assignee }
        if priority != issue.priority { priority = issue.priority }
        if issueType != issue.issueType { issueType = issue.issueType }
        if updated != issue.updated { updated = issue.updated }
        if labels != issue.labels { labels = issue.labels }
    }

    var json: JSONValue {
        ["key": .string(key), "summary": .string(summary), "status": .string(statusName),
         "statusCategory": .string(statusCategory), "assignee": .string(assignee ?? "Unassigned"),
         "priority": .string(priority ?? ""), "type": .string(issueType ?? ""),
         "updated": .string(updated?.formatted(.iso8601) ?? ""), "onBoard": .bool(onBoard), "followed": .bool(followed)]
    }
}

/// Layer 2 on Jira: your board and followed issues, synced into SwiftData,
/// plus Claude tools to search, comment and transition.
@MainActor
@Observable
final class JiraBoardFeature: DashExtension {
    let id = "jira-board"
    let name = "Jira Board"
    let systemImage = "checklist"
    let metadata = ExtensionMetadata(
        version: "1.2.0", author: .dash, summary: "Your Jira board and the issues you follow.", category: .projectManagement,
        tags: ["jira", "board"], homepage: "https://github.com/sessaidi/dash-extensions", minimumDashKit: "1.0.0")
    let requires = ["atlassian"]

    /// A followed board, with the columns it had at the last sync.
    struct Board: Codable, Hashable, Identifiable, Sendable {
        let id: Int
        var name: String
        var columns: [JiraClient.Column] = []
    }

    var boards: [Board] { didSet { defaults.set(try? JSONEncoder().encode(boards), forKey: "jira-board.boards") } }
    /// Tickets followed one by one, e.g. "PROJ-123".
    var followedKeys: [String] { didSet { defaults.set(followedKeys, forKey: "jira-board.keys") } }
    /// The first board's id, as text (the setting before several boards could be followed).
    var boardID: String {
        get { boards.first.map { String($0.id) } ?? "" }
        set { boards = Int(newValue.trimmingCharacters(in: .whitespaces)).map { [Board(id: $0, name: "Board \($0)")] } ?? [] }
    }
    var followJQL: String { didSet { defaults.set(followJQL, forKey: "jira-board.jql") } }
    var pollMinutes: Int { didSet { defaults.set(pollMinutes, forKey: "jira-board.poll") } }

    /// The first board's columns.
    var columns: [JiraClient.Column] { boards.first?.columns ?? [] }
    func columns(board: Int?) -> [JiraClient.Column] { boards.first { $0.id == board }?.columns ?? columns }
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    static let defaultJQL = "(assignee = currentUser() OR watcher = currentUser()) AND statusCategory != Done ORDER BY updated DESC"

    /// `defaults` is injectable for tests; Dash uses the standard suite (the built-in feature's keys).
    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "jira-board.boards"), let saved = try? JSONDecoder().decode([Board].self, from: data) {
            boards = saved
        } else if let old = Int(defaults.string(forKey: "jira-board.boardID") ?? "") {
            // One board, from before several could be followed; keep its cached columns.
            let columns = defaults.data(forKey: "jira-board.columns").flatMap { try? JSONDecoder().decode([JiraClient.Column].self, from: $0) }
            boards = [Board(id: old, name: "Board \(old)", columns: columns ?? [])]
        } else {
            boards = []
        }
        followedKeys = defaults.stringArray(forKey: "jira-board.keys") ?? []
        followJQL = defaults.string(forKey: "jira-board.jql") ?? Self.defaultJQL
        pollMinutes = defaults.object(forKey: "jira-board.poll") as? Int ?? 5
    }

    var models: [any PersistentModel.Type] { [JiraIssue.self] }
    var widgets: [WidgetType] { [WidgetType(JiraBoardWidget.self)] }
    func prepare(host: any ExtensionContext) async throws {
        await sync()
        if let lastError { throw ToolError(lastError) }
    }

    func settingsView() -> AnyView { AnyView(JiraBoardSettings(jira: self)) }

    /// The `atlassian` integration (built in or a plugin), found by id.
    var atlassian: (any Integration)? { host?.integration("atlassian") }

    var client: JiraClient {
        get throws {
            guard let atlassian else { throw ToolError("The Atlassian integration is not installed.") }
            guard let connection = atlassian.connection else { throw ToolError("Connect Atlassian in Settings › Integrations.") }
            return JiraClient(connection: connection)
        }
    }

    func start(host: any ExtensionContext) {
        self.host = host
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(Double(max(self?.pollMinutes ?? 5, 1)) * 60))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func sync() async {
        guard let host, !isSyncing, let client = try? client else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var refreshed = boards
            var onBoards: [Int: [JiraClient.Issue]] = [:]
            for index in refreshed.indices {
                let id = refreshed[index].id
                refreshed[index].columns = try await client.boardColumns(id)
                onBoards[id] = try await client.boardIssues(id)
            }
            if refreshed != boards { boards = refreshed }
            let followed = followJQL.isEmpty ? [] : try await client.search(followJQL)
            let pinned = try await pinnedIssues(client)
            upsert(boards: onBoards, followed: followed, pinned: pinned, client: client, context: host.context)
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The tickets followed by key. One query for all of them; if Jira rejects it (a key that
    /// no longer exists fails the whole JQL), one query per key, skipping the missing ones.
    private func pinnedIssues(_ client: JiraClient) async throws -> [JiraClient.Issue] {
        guard !followedKeys.isEmpty else { return [] }
        if let all = try? await client.search("key in (\(followedKeys.joined(separator: ",")))") { return all }
        var found: [JiraClient.Issue] = []
        for key in followedKeys { found += (try? await client.search("key = \(key)")) ?? [] }
        return found
    }

    private func upsert(boards onBoards: [Int: [JiraClient.Issue]], followed: [JiraClient.Issue], pinned: [JiraClient.Issue],
                        client: JiraClient, context: ModelContext) {
        let existing = Dictionary(
            ((try? context.fetch(FetchDescriptor<JiraIssue>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let board = onBoards.keys.sorted().flatMap { onBoards[$0] ?? [] }
        let boardKeys = Set(board.map(\.key))
        let pinnedKeys = Set(pinned.map(\.key))
        let followedKeys = Set(followed.map(\.key)).union(pinnedKeys)
        for issue in board + followed + pinned {
            let record = existing[issue.key] ?? {
                let record = JiraIssue(issue, url: client.browseURL(issue.key))
                context.insert(record)
                return record
            }()
            if existing[issue.key] != nil, record.statusName != issue.statusName {
                host?.emit("issue.status_changed", from: self, title: "\(issue.key) moved to \(issue.statusName)", detail: issue.summary,
                           link: record.url, importance: followedKeys.contains(issue.key) ? .notable : .info)
            } else if existing[issue.key] == nil, boardKeys.contains(issue.key) || followedKeys.contains(issue.key) {
                host?.emit("issue.appeared", from: self, title: "\(issue.key) on your board: \(issue.summary)", link: record.url)
            }
            record.apply(issue)
            if record.onBoard != boardKeys.contains(issue.key) { record.onBoard = boardKeys.contains(issue.key) }
            if record.followed != followedKeys.contains(issue.key) { record.followed = followedKeys.contains(issue.key) }
            let ids = onBoards.keys.sorted().filter { id in onBoards[id]?.contains { $0.key == issue.key } == true }
            if record.boardIDs != ids { record.boardIDs = ids }
            if record.pinned != pinnedKeys.contains(issue.key) { record.pinned = pinnedKeys.contains(issue.key) }
        }
        for (key, record) in existing where !boardKeys.contains(key) && !followedKeys.contains(key) {
            context.delete(record)
        }
        try? context.save()
    }

    /// Follows a ticket by key (stored locally; nothing changes in Jira).
    func follow(_ key: String) async {
        let key = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.isIssueKey(key), !followedKeys.contains(key) else { return }
        followedKeys.append(key)
        await sync()
    }

    func unfollow(_ key: String) async {
        followedKeys.removeAll { $0 == key.uppercased() }
        await sync()
    }

    static func isIssueKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Z][A-Z0-9_]+-\d+$"#, options: .regularExpression) != nil
    }

    /// Follows a board (its columns and issues arrive with the next sync).
    func follow(board: JiraClient.BoardInfo) async {
        guard !boards.contains(where: { $0.id == board.id }) else { return }
        boards.append(Board(id: board.id, name: board.name))
        await sync()
    }

    func issue(_ key: String) -> JiraIssue? {
        let descriptor = FetchDescriptor<JiraIssue>(predicate: #Predicate { $0.key == key })
        return try? host?.context.fetch(descriptor).first
    }

    /// Moves an issue to the transition whose name or target status matches `name`.
    func move(_ key: String, toStatus name: String) async throws -> String {
        let client = try client
        let options = try await client.transitions(key)
        guard let match = options.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            ?? options.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
            throw ToolError("No transition named \"\(name)\" for \(key). Available: \(options.map(\.name).joined(separator: ", ")).")
        }
        try await client.transition(key, to: match.id)
        await sync()
        return match.name
    }

    // MARK: Claude tools

    private struct KeyInput: Decodable { let key: String }
    private struct ListInput: Decodable { let scope: String?; let status: String? }
    private struct CommentInput: Decodable { let key: String; let text: String }
    private struct TransitionInput: Decodable { let key: String; let status: String }
    private struct SearchInput: Decodable { let jql: String }
    private struct FollowInput: Decodable { let key: String; let follow: Bool? }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "jira_list_issues",
                description: "List cached Jira issues from the user's board and the issues they follow. Use this for questions like \"what's on my plate\" or \"what's in review\".",
                properties: [
                    "scope": JSONSchema.string("Which issues: board, followed, or all (default).", enum: ["board", "followed", "all"]),
                    "status": JSONSchema.string("Optional status name filter, e.g. \"In Progress\"."),
                ]
            ) { [weak self] input in
                guard let self, let host else { return [] }
                let request = try input.toolInput(ListInput.self)
                let issues = (try? host.context.fetch(FetchDescriptor<JiraIssue>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? []
                return .array(issues.filter { issue in
                    switch request.scope {
                    case "board": issue.onBoard
                    case "followed": issue.followed
                    default: true
                    }
                }.filter { request.status == nil || $0.statusName.localizedCaseInsensitiveCompare(request.status!) == .orderedSame }.map(\.json))
            },
            ClaudeTool(
                name: "jira_follow",
                description: "Follow or unfollow a Jira ticket in Dash (local only; nothing changes in Jira). Followed tickets sync into the cache and show in \"Issues I follow\".",
                properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234."),
                             "follow": JSONSchema.boolean("true to follow (default), false to unfollow.")],
                required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(FollowInput.self)
                let key = request.key.uppercased()
                guard Self.isIssueKey(key) else { throw ToolError("\(request.key) is not an issue key.") }
                if request.follow ?? true { await follow(key) } else { await unfollow(key) }
                return ["key": .string(key), "following": .bool(followedKeys.contains(key))]
            },
            ClaudeTool(
                name: "jira_get_issue",
                description: "Fetch one Jira issue live, with its description and recent comments.",
                properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234.")], required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                return try await client.issueDetail(input.toolInput(KeyInput.self).key.uppercased())
            },
            ClaudeTool(
                name: "jira_search",
                description: "Run a JQL search against Jira (live, up to 50 results).",
                properties: ["jql": JSONSchema.string("JQL query.")], required: ["jql"]
            ) { [weak self] input in
                guard let self else { return nil }
                let issues = try await client.search(input.toolInput(SearchInput.self).jql, limit: 50)
                return .array(issues.prefix(50).map { ["key": .string($0.key), "summary": .string($0.summary), "status": .string($0.statusName), "assignee": .string($0.assignee ?? "Unassigned")] })
            },
            ClaudeTool(
                name: "jira_add_comment",
                description: "Post a comment on a Jira issue.",
                properties: ["key": JSONSchema.string("Issue key."), "text": JSONSchema.string("Comment text. Blank lines separate paragraphs.")],
                required: ["key", "text"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CommentInput.self)
                try await client.comment(request.key, text: request.text)
                return "commented"
            },
            ClaudeTool(
                name: "jira_transition_issue",
                description: "Move a Jira issue to another status using one of its workflow transitions (for example \"In Progress\" or \"Code Review\").",
                properties: ["key": JSONSchema.string("Issue key."), "status": JSONSchema.string("Transition or status name.")],
                required: ["key", "status"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(TransitionInput.self)
                return .string("Moved via \"\(try await move(request.key, toStatus: request.status))\".")
            },
        ]
    }
}

private struct JiraBoardSettings: View {
    @Bindable var jira: JiraBoardFeature
    @State private var boardQuery = ""
    @State private var found: [JiraClient.BoardInfo] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var newKey = ""

    var body: some View {
        Form {
            Section {
                if jira.boards.isEmpty { Text("No boards yet. Search for one below.").foregroundStyle(.secondary) }
                ForEach(jira.boards) { board in
                    HStack {
                        Label(board.name, systemImage: "rectangle.split.3x1")
                        Text("#\(board.id) · \(board.columns.count) columns").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Unfollow", systemImage: "minus.circle") {
                            jira.boards.removeAll { $0.id == board.id }
                            Task { await jira.sync() }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Find a board", text: $boardQuery, prompt: Text("Board name, or empty to list all")).onSubmit(search)
                    Button("Search", action: search).disabled(searching)
                }
                if let searchError { Text(searchError).font(.caption).foregroundStyle(.red) }
                ForEach(found.filter { board in !jira.boards.contains { $0.id == board.id } }) { board in
                    HStack {
                        Text(board.name)
                        Text([board.project, board.type].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Follow") { Task { await jira.follow(board: board) } }
                    }
                }
            } header: {
                Text("Boards")
            } footer: {
                Text("Each board's active sprint (scrum) or open issues (kanban). Uses the Atlassian integration.")
            }
            Section {
                ForEach(jira.followedKeys, id: \.self) { key in
                    HStack {
                        Text(key).monospaced()
                        if let issue = jira.issue(key) { Text(issue.summary).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Button("Unfollow", systemImage: "minus.circle") { Task { await jira.unfollow(key) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Follow a ticket", text: $newKey, prompt: Text("PROJ-123")).onSubmit(addKey)
                    Button("Follow", action: addKey).disabled(!JiraBoardFeature.isIssueKey(newKey.trimmingCharacters(in: .whitespaces).uppercased()))
                }
            } header: {
                Text("Tickets")
            } footer: {
                Text("Followed here only; nothing changes in Jira. Dashii can follow tickets for you too.")
            }
            Section("Query") {
                TextField("Also follow issues matching (JQL)", text: $jira.followJQL, axis: .vertical)
                Stepper("Refresh every \(jira.pollMinutes) min", value: $jira.pollMinutes, in: 1...60)
            }
            Section {
                HStack {
                    if let error = jira.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if let lastSync = jira.lastSync {
                        Text("Synced \(lastSync.relative)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sync Now") { Task { await jira.sync() } }.disabled(jira.isSyncing)
                }
            }
        }
    }

    private func search() {
        searching = true
        searchError = nil
        Task {
            do { found = try await jira.client.boards(matching: boardQuery.trimmingCharacters(in: .whitespaces)) }
            catch { searchError = error.localizedDescription }
            searching = false
        }
    }

    private func addKey() {
        let key = newKey.trimmingCharacters(in: .whitespaces).uppercased()
        guard JiraBoardFeature.isIssueKey(key) else { return }
        newKey = ""
        Task { await jira.follow(key) }
    }
}
