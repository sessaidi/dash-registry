import AppKit
import DashKit
import DashKitUI
import Ingestor
import SwiftUI

/// The GitHub pane in Settings: token (with a link to create one, permissions pre-filled), API
/// URL, status, and the repositories to watch, picked from the ones the token can see.
struct GitHubSettingsView: View {
    @Bindable var github: GitHubIntegration
    @State private var search = ""
    @State private var manual = ""
    @State private var confirmClear = false
    @State private var clearError: String?
    @State private var storedRevision = 0

    var body: some View {
        Form {
            Section {
                SecretField("Personal access token", placeholder: "github_pat_…", isStored: github.hasToken,
                            onSave: { github.setToken($0); Task { await github.verify(); await github.loadAvailableRepos() } },
                            onRemove: { github.setToken("") })
                HStack {
                    Text("Create a token:").foregroundStyle(.secondary)
                    if let url = github.fineGrainedTokenURL { Link("Fine-grained (recommended)", destination: url) }
                    Text("·").foregroundStyle(.tertiary)
                    if let url = github.classicTokenURL { Link("Classic", destination: url) }
                }
                .font(.callout)
                TextField("API URL", text: $github.apiURL, prompt: Text(GitHubIntegration.defaultAPI))
                HStack {
                    ConnectionStatusLabel(github.connectionState)
                    Spacer()
                    AsyncButton("Check") { await github.verify() }
                }
            } header: {
                Text("Account")
            } footer: {
                Text("The links open GitHub with Dash's name and permissions filled in: Contents, Actions, Issues and Metadata read; Pull requests read & write (only to open PRs you ask for; reviews stay in Dash). For a fine-grained token, pick the repositories or organization on that page (an organization may need to approve it). For GitHub Enterprise Server use https://<host>/api/v3.")
            }
            if github.hasToken {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your repositories", text: $search).textFieldStyle(.plain)
                        if github.loadingRepos { ProgressView().controlSize(.small) }
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await github.loadAvailableRepos() } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    if let error = github.reposError { Text(error).font(.caption).foregroundStyle(.red) }
                    if let hint = github.reposHint {
                        Label(hint, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    let results = filtered + github.searchResults
                    if results.isEmpty {
                        if !github.loadingRepos {
                            Text(github.availableRepos.isEmpty ? "No repositories loaded yet. Press ↻ to load them." : "No repository matches “\(search)”.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Up to ten rows show; more scroll.
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(results) { repo in
                                    Toggle(isOn: Binding(get: { github.repos.contains(repo.fullName) }, set: { github.setWatched(repo.fullName, $0) })) {
                                        HStack(spacing: 6) {
                                            Text(repo.fullName).font(.callout.monospaced())
                                            if repo.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                            if !repo.description.isEmpty { Text(repo.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .frame(height: Self.rowHeight, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: CGFloat(min(results.count, 10)) * Self.rowHeight)
                    }
                } header: {
                    Text("Find repositories")
                } footer: {
                    Text(github.availableRepos.isEmpty ? "Tick a repository to watch it." : "\(github.availableRepos.count) repositories visible to this token. Tick one to watch it.")
                }
            }
            Section {
                if github.repos.isEmpty {
                    Text("No repositories watched yet.").foregroundStyle(.secondary)
                }
                ForEach(github.repos, id: \.self) { repo in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(repo).font(.callout.monospaced())
                        Spacer()
                        Button("Stop Watching", systemImage: "minus.circle") { github.setWatched(repo, false) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add by name", text: $manual, prompt: Text("owner/name"))
                    Button("Add") {
                        let repo = manual.trimmingCharacters(in: .whitespaces)
                        guard repo.split(separator: "/").count == 2 else { return }
                        github.setWatched(repo, true)
                        manual = ""
                    }
                    .disabled(manual.split(separator: "/").count != 2)
                }
            } header: {
                Text("Watched repositories (\(github.repos.count))")
            } footer: {
                Text("Every GitHub feature (pull requests, reviews, CI) uses this list.")
            }
            IngestScheduleSection(github.schedule, footer: "While Dash runs, it fetches these from GitHub on their cycle, so widgets, Dashii and agents find them stored. "
                                  + "Anything else is fetched when something needs it. A used-up rate limit pauses fetching until it resets.")
            Section {
                Stepper("Fresh for \(github.freshMinutes) minutes", value: $github.freshMinutes, in: 5...240, step: 5)
                Stepper("Keep lists and searches \(github.keepDays) day\(github.keepDays == 1 ? "" : "s")", value: $github.keepDays, in: 1...30)
                LabeledContent("Stored") {
                    let stored = storedSummary
                    Text("\(stored.answers) answers, \(stored.pulls) pull requests, \(stored.runs) runs" + (stored.newest.map { " · newest \($0.relative)" } ?? ""))
                }
                Button("Clear Fetched Data…", role: .destructive) { confirmClear = true }
                    .disabled(storedSummary.answers == 0)
                if let clearError { Text(clearError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Fetched data")
            } footer: {
                Text("Dashii and agents read what Dash fetched from GitHub. Past the fresh time it's marked stale and they may fetch it again. "
                     + "Clearing deletes what was fetched and GitHub's tables; nothing on GitHub changes.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear what Dash fetched from GitHub?", isPresented: $confirmClear) {
            Button("Clear Fetched Data", role: .destructive) {
                do { try github.clearFetchedData(); clearError = nil } catch { clearError = error.localizedDescription }
                storedRevision += 1
            }
        } message: {
            Text("Widgets show nothing until it's fetched again, by the schedule or when something needs it.")
        }
        // Counts follow every fetch.
        .onReceive(NotificationCenter.default.publisher(for: IngestNotification.name)) { _ in storedRevision += 1 }
        .task { if github.hasToken && github.availableRepos.isEmpty { await github.loadAvailableRepos() } }
        // Also ask GitHub's search, so repositories the list missed can still be found.
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await github.searchRepos(search)
        }
    }

    static let rowHeight: CGFloat = 26

    private var storedSummary: (answers: Int, newest: Date?, pulls: Int, runs: Int) {
        _ = storedRevision
        return github.storedSummary
    }

    private var filtered: [GitHubIntegration.AvailableRepo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return github.availableRepos.filter { query.isEmpty || $0.fullName.lowercased().contains(query) || $0.description.lowercased().contains(query) }
    }
}
