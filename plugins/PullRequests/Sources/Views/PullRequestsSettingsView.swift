import DashKit
import DashKitUI
import SwiftUI

struct PullRequestsSettingsView: View {
    @Bindable var pulls: PullRequestsFeature
    @State private var newRepo = ""

    var body: some View {
        Form {
            Section {
                if pulls.availableRepos.isEmpty && pulls.extraRepos.isEmpty {
                    Text("The GitHub integration lists no repositories yet. Add them in Settings › GitHub, or below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(pulls.availableRepos, id: \.self) { repo in
                    Toggle(repo, isOn: Binding(
                        get: { !pulls.excludedRepos.contains(repo) },
                        set: { if $0 { pulls.excludedRepos.remove(repo) } else { pulls.excludedRepos.insert(repo) } }))
                }
                ForEach(pulls.extraRepos, id: \.self) { repo in
                    HStack {
                        Text(repo)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { pulls.extraRepos.removeAll { $0 == repo } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a repository", text: $newRepo, prompt: Text("owner/name")).onSubmit(addRepo)
                    Button("Add", action: addRepo).disabled(!isRepoName(newRepo))
                }
                Stepper("Check every \(pulls.pollMinutes) min", value: $pulls.pollMinutes, in: 1...30)
            } header: {
                Text("Repositories")
            } footer: {
                Text("Uses the GitHub integration's token. Unticked repositories are not checked.")
            }
            Section("What to follow") {
                Toggle("PRs waiting for my review", isOn: $pulls.trackRequested)
                Toggle("My PRs", isOn: $pulls.trackMine)
                Toggle("Everyone else's PRs", isOn: $pulls.trackOthers)
                Toggle("Draft PRs", isOn: $pulls.trackDrafts)
                Toggle("Feedback on my PRs (approvals, change requests, comments)", isOn: $pulls.followFeedback)
                    .disabled(!pulls.trackMine)
            }
            Section {
                Toggle("Review automatically on new PRs and new pushes", isOn: $pulls.autoReview)
                Group {
                    Toggle("PRs waiting for my review", isOn: $pulls.reviewRequestedPRs)
                    Toggle("My PRs (before reviewers see them)", isOn: $pulls.reviewMyPRs)
                    Toggle("Everyone else's PRs", isOn: $pulls.reviewOtherPRs)
                    Toggle("Drafts too", isOn: $pulls.reviewDrafts)
                }
                .disabled(!pulls.autoReview)
                .padding(.leading, 12)
                modelPickers
                TextField("Review instructions", text: $pulls.reviewInstructions,
                          prompt: Text("e.g. We use Go; flag missing context propagation and unchecked errors."), axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Dashii reviews")
            } footer: {
                Text("Reviews are for you only: they stay in Dash and are never posted to GitHub as comments or reviews.")
            }
            Section {
                HStack {
                    if let error = pulls.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if let lastSync = pulls.lastSync {
                        Text("Checked \(lastSync.relative)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { Task { await pulls.sync() } }.disabled(pulls.isSyncing)
                }
            }
        }
    }

    /// The review task's model and effort, saved where the AI tab saves them.
    @ViewBuilder private var modelPickers: some View {
        let task = PullRequestsFeature.reviewTask
        let settings = pulls.ai ?? AISettings(tasks: pulls.aiTasks)
        Picker("Model", selection: Binding(get: { settings.model(task.id) }, set: { model in
            var choice = settings.choices[task.id] ?? AITaskChoice()
            choice.model = model
            pulls.host?.setAIChoice(choice, task: task.id, scope: .extension(pulls.id))
        })) {
            ForEach(task.models) { Text($0.displayName).tag($0) }
        }
        Picker("Effort", selection: Binding(get: { settings.effort(task.id) ?? task.defaultEffort ?? .high }, set: { effort in
            var choice = settings.choices[task.id] ?? AITaskChoice()
            choice.effort = effort
            pulls.host?.setAIChoice(choice, task: task.id, scope: .extension(pulls.id))
        })) {
            ForEach(task.efforts) { Text($0.displayName).tag($0) }
        }
    }

    private func isRepoName(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    private func addRepo() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard isRepoName(repo), !pulls.repos.contains(repo) else { return }
        pulls.extraRepos.append(repo)
        newRepo = ""
    }
}
