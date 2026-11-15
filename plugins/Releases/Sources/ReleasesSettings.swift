import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Settings › Releases: the repositories and how to read their tags, and the events lane.
struct ReleasesSettingsView: View {
    @Bindable var feature: ReleasesFeature
    @State private var checkouts: [String] = []
    @State private var expanded: Set<String> = []
    @State private var newEvent = ReleaseEvent(date: .now, kind: .launch, title: "")

    var body: some View {
        Form {
            Section {
                if feature.repositories.isEmpty {
                    Text("No repositories yet. Add a local checkout: its release tags become the timeline.").foregroundStyle(.secondary)
                }
                ForEach($feature.repositories) { $repository in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(repository.id) }, set: { open in
                        if open { expanded.insert(repository.id) } else { expanded.remove(repository.id) }
                    })) {
                        RepositoryEditor(repository: $repository)
                            // Re-read the tags once edits settle.
                            .task(id: repository) {
                                try? await Task.sleep(for: .milliseconds(800))
                                guard !Task.isCancelled else { return }
                                await feature.refresh(repository.id)
                            }
                    } label: {
                        repositoryLabel(repository)
                    }
                }
                HStack {
                    Button("Add Repository…", systemImage: "plus") { choose() }
                    Menu("Add a Checkout") {
                        let added = Set(feature.repositories.map(\.url.path))
                        let candidates = checkouts.filter { !added.contains(($0 as NSString).expandingTildeInPath) }
                        if candidates.isEmpty { Text("No other git checkouts under ~/code") }
                        ForEach(candidates, id: \.self) { path in
                            Button(path) { Task { await feature.addRepository(path: path) } }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    AsyncButton("Refresh") { await feature.refresh() }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("A local checkout is read with read-only git commands; a repository from GitHub or GitLab without one is read from the mirror its integration keeps in Dash (reads only). Each is checked for changes on its own interval (10 minutes by default). Tags matching the pattern are grouped into releases (builds .01, .02…) and trains (-eu, -us…). A build whose commit isn't on the base branch is a hotfix.")
            }
            Section {
                ForEach(feature.timelineEvents.sorted { $0.date > $1.date }) { event in
                    HStack {
                        Image(systemName: event.kind.systemImage).foregroundStyle(event.kind == .incident ? .red : event.kind == .launch ? .green : .purple)
                        VStack(alignment: .leading) {
                            Text(event.title)
                            Text([event.date.formatted(date: .abbreviated, time: .omitted), repositoryName(event.repository), event.note].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) { feature.timelineEvents.removeAll { $0.id == event.id } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    DatePicker("", selection: $newEvent.date, displayedComponents: .date).labelsHidden()
                    Picker("", selection: $newEvent.kind) {
                        ForEach(ReleaseEvent.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("Title", text: $newEvent.title)
                    Button("Add") {
                        feature.timelineEvents.append(newEvent)
                        newEvent = ReleaseEvent(date: newEvent.date, kind: newEvent.kind, title: "")
                    }
                    .disabled(newEvent.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Note (optional)", text: $newEvent.note)
                Picker("Repository", selection: $newEvent.repository) {
                    Text("Every repository").tag(String?.none)
                    ForEach(feature.repositories) { Text($0.name).tag(String?.some($0.id)) }
                }
            } header: {
                Text("Events")
            } footer: {
                Text("Launches, incidents and milestones on the timeline's events lane. Claude can add them too (with your approval).")
            }
        }
        .formStyle(.grouped)
        .task { checkouts = await Self.findCheckouts() }
    }

    private func repositoryLabel(_ repository: RepositoryConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                Text(status(repository)).font(.caption).foregroundStyle(feature.errors[repository.id] == nil ? Color.secondary : Tone.danger.color).lineLimit(2)
            }
            Spacer()
            if feature.loading.contains(repository.id) { ProgressView().controlSize(.small) }
            Button("Remove", systemImage: "minus.circle", role: .destructive) { feature.repositories.removeAll { $0.id == repository.id } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove \(repository.name)")
        }
    }

    private func status(_ repository: RepositoryConfig) -> String {
        if let error = feature.errors[repository.id] { return error }
        let place = repository.isRemote ? "\(repository.slug ?? "") via \(repository.service == "gitlab" ? "GitLab" : "GitHub")" : repository.path
        guard let timeline = feature.timelines[repository.id] else { return place }
        let trains = timeline.trains.map(timeline.trainTitle).joined(separator: ", ")
        return "\(place) · \(timeline.releases.count) releases · \(trains.isEmpty ? "no matching tags" : trains)"
    }

    private func repositoryName(_ id: String?) -> String {
        id.flatMap { id in feature.repositories.first { $0.id == id }?.name } ?? ""
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a git checkout with release tags."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        Task { await feature.addRepository(path: path) }
    }

    /// Git checkouts up to three levels under ~/code, as "~/code/…".
    nonisolated static func findCheckouts() async -> [String] {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        var found: [String] = []
        func scan(_ url: URL, depth: Int) {
            guard depth <= 3, let children = try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if files.fileExists(atPath: child.appending(path: ".git").path) {
                    found.append("~" + child.path.dropFirst(home.path.count))
                } else {
                    scan(child, depth: depth + 1)
                }
            }
        }
        scan(home.appending(path: "code"), depth: 1)
        return found.sorted()
    }
}

/// How one repository's tags are read.
private struct RepositoryEditor: View {
    @Binding var repository: RepositoryConfig

    var body: some View {
        TextField("Name", text: $repository.name)
        TextField("Checkout", text: $repository.path, prompt: Text(repository.source.map { "Empty: read \($0) from the integration" } ?? "~/code/my-service"))
        Picker("Check for changes", selection: Binding(get: { repository.refreshMinutes ?? 10 }, set: { repository.refreshMinutes = $0 })) {
            ForEach([1, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 60 ? "Every hour" : "Every \($0) min").tag($0) }
        }
        TextField("Tag pattern", text: $repository.tagPattern, prompt: Text("release-* or v*, or a regex starting with ^"))
        HStack {
            Button("release-* builds") { apply(.releaseTags) }
            Button("Semver (v*)") { apply(.semver) }
        }
        .controlSize(.small)
        Picker("Trains", selection: $repository.trainRule) {
            ForEach(RepositoryConfig.TrainRule.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if repository.trainRule == .regex {
            TextField("Train regex", text: $repository.trainRegex, prompt: Text("-(eu|us)\\.\\d+$ (first group is the train)"))
        }
        Picker("Builds", selection: $repository.buildRule) {
            ForEach(RepositoryConfig.BuildRule.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        TextField("Base branch", text: $repository.baseBranch, prompt: Text("origin's HEAD"))
        Stepper("A quiet train ends after \(repository.idleDays) days", value: $repository.idleDays, in: 1...365)
    }

    private func apply(_ scheme: TagScheme) {
        repository.tagPattern = scheme.pattern
        repository.trainRule = scheme.train
        repository.buildRule = scheme.build
    }
}
