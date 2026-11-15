import DashKit
import DashKitUI
import SwiftUI

struct JiraBoardSettings: View {
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
                Toggle(isOn: $jira.autoUnfollow) {
                    Text("Stop following a ticket once it's done and its PRs are merged")
                    Text("Checked at each sync from Jira's development panel; a done ticket with an open PR stays.")
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
