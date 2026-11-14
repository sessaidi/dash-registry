import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The GitHub pane in Settings: token (with a link to create one, permissions pre-filled), API
/// URL, status, and the repositories to watch, picked from the ones the token can see.
struct GitHubSettingsView: View {
    @Bindable var github: GitHubIntegration
    @State private var search = ""
    @State private var manual = ""

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
                Text("The links open GitHub with Dash's name and permissions filled in: Contents, Actions, Issues and Metadata read; Pull requests read & write (reviews, PRs). For a fine-grained token, pick the repositories or organization on that page (an organization may need to approve it). For GitHub Enterprise Server use https://<host>/api/v3.")
            }
            Section {
                if !github.repos.isEmpty {
                    ForEach(github.repos, id: \.self) { repo in
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(repo).font(.callout.monospaced())
                            Spacer()
                            Button("Stop Watching", systemImage: "minus.circle") { github.setWatched(repo, false) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                }
                if github.hasToken {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your repositories", text: $search).textFieldStyle(.plain)
                        if github.loadingRepos { ProgressView().controlSize(.small) }
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await github.loadAvailableRepos() } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    if let error = github.reposError { Text(error).font(.caption).foregroundStyle(.red) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filtered) { repo in
                                Toggle(isOn: Binding(get: { github.repos.contains(repo.fullName) }, set: { github.setWatched(repo.fullName, $0) })) {
                                    HStack(spacing: 6) {
                                        Text(repo.fullName).font(.callout.monospaced())
                                        if repo.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                                        if !repo.description.isEmpty { Text(repo.description).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                            if filtered.isEmpty && !github.loadingRepos {
                                Text(github.availableRepos.isEmpty ? "No repositories loaded yet." : "No repository matches “\(search)”.").foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
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
        }
        .formStyle(.grouped)
        .task { if github.hasToken && github.availableRepos.isEmpty { await github.loadAvailableRepos() } }
    }

    private var filtered: [GitHubIntegration.AvailableRepo] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return github.availableRepos.filter { query.isEmpty || $0.fullName.lowercased().contains(query) || $0.description.lowercased().contains(query) }
    }
}
