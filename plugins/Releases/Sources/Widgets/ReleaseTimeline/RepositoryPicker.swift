import DashKit
import DashKitUI
import SwiftUI

/// The widget's repository: one already set up in Releases, or one the GitHub or GitLab
/// integration watches (added when picked), or every configured one.
struct RepositoryPicker: View {
    let feature: ReleasesFeature
    let host: any ExtensionContext
    @Binding var selection: String?
    @State private var adding: String?

    private var remotes: [RemoteRepository] {
        let added = Set(feature.repositories.compactMap(\.source))
        return RemoteRepository.available(host: host).filter { !added.contains($0.source) }
    }

    var body: some View {
        LabeledContent("Repository") {
            HStack(spacing: 6) {
                if adding != nil { ProgressView().controlSize(.small) }
                Menu(label) {
                    if !feature.repositories.isEmpty {
                        Button { selection = nil } label: { check(selection == nil, "All repositories") }
                        Section("Set up in Releases") {
                            ForEach(feature.repositories) { repository in
                                Button { selection = repository.id } label: {
                                    check(selection == repository.id, repository.name + (repository.isRemote ? " · \(repository.service == "gitlab" ? "GitLab" : "GitHub")" : ""))
                                }
                            }
                        }
                    }
                    let github = remotes.filter { $0.service == "github" }
                    let gitlab = remotes.filter { $0.service == "gitlab" }
                    if !github.isEmpty { Section("GitHub") { ForEach(github) { remote in Button(remote.slug) { add(remote) } } } }
                    if !gitlab.isEmpty { Section("GitLab") { ForEach(gitlab) { remote in Button(remote.slug) { add(remote) } } } }
                    Divider()
                    Button("Add a Local Checkout…") { host.openManager("releases") }
                }
                .fixedSize()
            }
        }
    }

    private var label: String {
        if let adding { return "Adding \(adding)…" }
        guard let selection else { return feature.repositories.isEmpty ? "Choose…" : "All repositories" }
        return feature.repositories.first { $0.id == selection }?.name ?? "Choose…"
    }

    @ViewBuilder private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func add(_ remote: RemoteRepository) {
        adding = remote.name
        Task {
            selection = await feature.addRemote(remote)
            adding = nil
        }
    }
}
