import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftData
import SwiftUI

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
        tags: ["jira", "board"], homepage: "https://github.com/sessaidi/dash-extensions", minimumDashKit: "2.0.0")
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
    /// Stop following a ticket once it's done and its PRs are merged.
    var autoUnfollow: Bool { didSet { defaults.set(autoUnfollow, forKey: "jira-board.autoUnfollow") } }
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
        autoUnfollow = defaults.object(forKey: "jira-board.autoUnfollow") as? Bool ?? true
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
            var pinned = try await pinnedIssues(client)
            pinned = await unfollowFinished(pinned, client: client)
            upsert(boards: onBoards, followed: followed, pinned: pinned, client: client, context: host.context)
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stops following tickets that are done and whose pull requests are merged (or that have
    /// none linked); a ticket done with a PR still open stays. Returns the ones still followed.
    func unfollowFinished(_ pinned: [JiraClient.Issue], client: JiraClient) async -> [JiraClient.Issue] {
        guard autoUnfollow else { return pinned }
        var kept: [JiraClient.Issue] = []
        for issue in pinned {
            guard issue.statusCategory == "done", !issue.id.isEmpty,
                  let pulls = try? await client.pullRequests(issueID: issue.id), Self.isFinished(pulls) else {
                kept.append(issue)
                continue
            }
            followedKeys.removeAll { $0 == issue.key }
            _ = host?.emit("jira.unfollowed", from: self, title: "Stopped following \(issue.key)",
                       detail: pulls.count == 0 ? "Done" : "Done and its PR merged", link: client.browseURL(issue.key).absoluteString, importance: .info)
        }
        return kept
    }

    /// No open pull request: all merged (or declined), or none linked.
    nonisolated static func isFinished(_ pulls: (count: Int, state: String?)) -> Bool {
        pulls.count == 0 || pulls.state?.uppercased() != "OPEN"
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
}
