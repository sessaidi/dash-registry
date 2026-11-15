import AppKit
import DashKit
import DashKitUI
import Foundation
import SwiftData
import SwiftUI

/// Your own review of a pull request, worked through with Dashii. It stays in Dash: nothing here
/// is ever posted to GitHub.
@Model
final class PRDiscussion {
    @Attribute(.unique) var prUID: String
    var entriesData: Data
    /// Your review notes, with the feedback you kept.
    var draft: String
    var updatedAt: Date

    init(prUID: String) {
        self.prUID = prUID
        entriesData = Data("[]".utf8)
        draft = ""
        updatedAt = .now
    }

    struct Point: Codable, Hashable, Sendable, Identifiable {
        /// agree, correction, suggestion, question, risk
        let kind: String
        let text: String
        let file: String?
        let line: Int?
        /// nil until you decide: kept or set aside.
        var kept: Bool?
        var id: String { kind + text }
    }

    struct Entry: Codable, Hashable, Sendable, Identifiable {
        let id: UUID
        /// "me" or "dashii"
        let author: String
        let text: String
        var points: [Point]
        let at: Date
    }

    var entries: [Entry] {
        get { (try? JSONDecoder().decode([Entry].self, from: entriesData)) ?? [] }
        set { entriesData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8); updatedAt = .now }
    }
}

extension PullRequestsFeature {
    func discussion(_ prUID: String) -> PRDiscussion? {
        guard let host else { return nil }
        if let found = try? host.context.fetch(FetchDescriptor<PRDiscussion>(predicate: #Predicate { $0.prUID == prUID })).first { return found }
        let created = PRDiscussion(prUID: prUID)
        host.context.insert(created)
        return created
    }

    static let discussionSchema: JSONValue = [
        "type": "object", "additionalProperties": false, "required": ["reply", "points"],
        "properties": [
            "reply": ["type": "string", "description": "A short answer to what the user said, in Markdown."],
            "points": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false, "required": ["kind", "text", "file", "line"],
                    "properties": [
                        "kind": ["type": "string", "enum": ["agree", "correction", "suggestion", "question", "risk"]],
                        "text": ["type": "string"],
                        "file": ["type": ["string", "null"]],
                        "line": ["type": ["integer", "null"]],
                    ],
                ],
            ],
        ],
    ]

    /// Dashii's answer to your latest note: agreement, corrections of what you got wrong, and
    /// what you may have missed, grounded in the diff and Claude's automatic review.
    func discuss(_ pr: PullRequest, discussion: PRDiscussion, message: String) async throws {
        guard let host else { return }
        var entries = discussion.entries
        entries.append(.init(id: UUID(), author: "me", text: message, points: [], at: .now))
        discussion.entries = entries
        try? host.context.save()

        let diff = (try? await client.diff(pr.repo, pr.number)) ?? ""
        let review = latestReview(pr.uid)
        let history = entries.suffix(12).map { "\($0.author == "me" ? "Me" : "Dashii"): \($0.text)" }.joined(separator: "\n\n")
        let prompt = """
            Pull request \(pr.repo)#\(pr.number) “\(pr.title)” by \(pr.author), \(pr.headRef) → \(pr.baseRef).

            <description>
            \(pr.body.prefix(4000))
            </description>

            <automatic-review>
            \(review?.markdown.prefix(6000) ?? "none")
            </automatic-review>

            <diff>
            \(diff.prefix(60_000))
            </diff>

            <conversation>
            \(history)
            </conversation>

            I'm reviewing this pull request myself. Answer my latest message. Give points I can keep or set aside: \
            agree when I'm right, correction when I'm wrong or misread the code (say why, with the file and line), \
            suggestion or risk for what I missed, question when something needs the author. Be direct and brief; no praise.
            """
        let text = try await host.dashii.complete(
            system: "You help an engineer review a colleague's pull request. You check their reasoning against the actual diff and correct them when needed.",
            prompt: prompt, outputSchema: Self.discussionSchema, effort: "medium")
        let result = try JSONValue.parse(text)
        let points = (result["points"]?.array ?? []).compactMap { point -> PRDiscussion.Point? in
            guard let kind = point["kind"]?.string, let text = point["text"]?.string else { return nil }
            return .init(kind: kind, text: text, file: point["file"]?.string, line: point["line"]?.int, kept: nil)
        }
        entries.append(.init(id: UUID(), author: "dashii", text: result["reply"]?.string ?? "", points: points, at: .now))
        discussion.entries = entries
        try? host.context.save()
    }

    /// The workspaces deployed from a branch in dev and qa, through the Workspaces plugin when installed.
    func workspaces(forBranch branch: String) async -> (found: [JSONValue], note: String?) {
        guard let host, let workspaces = host.extensions.first(where: { $0.id == "workspaces" }), host.isEnabled(workspaces) else {
            return ([], "Install the Workspaces plugin to see workspaces for this branch.")
        }
        guard let tool = workspaces.tools.first(where: { $0.name == "workspaces_for_branch" }) else { return ([], "Update the Workspaces plugin to look workspaces up.") }
        do {
            let result = try await tool.run(["branch": .string(branch)])
            let errors = (result["errors"]?.object ?? [:]).map { "\($0.key): \($0.value.string ?? "")" }
            return (result["workspaces"]?.array ?? [], errors.isEmpty ? nil : "Couldn't check " + errors.joined(separator: "; "))
        } catch {
            return ([], error.localizedDescription)
        }
    }
}

/// A pull request in full: what it is and where it runs, its changes, the reviews, and your
/// own review worked through with Dashii.
struct PullRequestSheet: View {
    enum Tab: String, CaseIterable { case overview = "Overview", changes = "Changes", reviews = "Reviews", discuss = "Review with Dashii" }

    let pr: PullRequest
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @Query private var reviews: [PRReview]
    @State private var tab = Tab.overview
    @State private var error: String?
    @State private var busy = false
    @State private var confirmMerge = false
    @State private var workspaces: [JSONValue]?
    @State private var workspaceNote: String?
    @State private var files: [JSONValue]?
    @State private var human: (reviews: [JSONValue], comments: [JSONValue])?

    init(pr: PullRequest, host: any ExtensionContext) {
        self.pr = pr
        self.host = host
        let uid = pr.uid
        _reviews = Query(filter: #Predicate<PRReview> { $0.prUID == uid }, sort: \.createdAt, order: .reverse)
    }

    private var github: PullRequestsFeature? { host.ext(PullRequestsFeature.self) }
    /// "owner/services-user" → "services-user": the service the PR changes.
    private var service: String { String(pr.repo.split(separator: "/").last ?? Substring(pr.repo)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            Group {
                switch tab {
                case .overview: ScrollView { overview.frame(maxWidth: .infinity, alignment: .leading) }
                case .changes: changes
                case .reviews: ScrollView { reviewsTab.frame(maxWidth: .infinity, alignment: .leading) }
                case .discuss:
                    if let github, let discussion = github.discussion(pr.uid) {
                        PRDiscussionView(pr: pr, feature: github, discussion: discussion)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Label("Reviews stay in Dash. Nothing is posted to the pull request.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Re-review", systemImage: "arrow.clockwise") { github?.requestReview(pr) }
                Button("Ask Dashii", systemImage: "sparkles") {
                    host.askDashii("Let's discuss PR \(pr.repo)#\(pr.number). Read it and its Dashii review first.")
                    dismiss()
                }
                Button("Merge…") { confirmMerge = true }.disabled(busy || pr.isDraft)
            }
        }
        .padding(20)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 640, idealHeight: 760)
        .task { await loadWorkspaces() }
        .confirmationDialog("Merge \(pr.repo)#\(pr.number)?", isPresented: $confirmMerge) {
            Button("Squash and Merge") { run { try await github?.client.merge(pr.repo, pr.number, method: "squash"); await github?.sync() } }
            Button("Merge Commit") { run { try await github?.client.merge(pr.repo, pr.number, method: "merge"); await github?.sync() } }
            Button("Rebase and Merge") { run { try await github?.client.merge(pr.repo, pr.number, method: "rebase"); await github?.sync() } }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Badge(service, tone: .info, systemImage: "shippingbox")
                Text("#\(pr.number)").font(.headline.monospaced()).foregroundStyle(.secondary)
                if pr.isDraft { Badge("Draft", tone: .neutral) }
                Spacer()
                Link("Open on GitHub", destination: URL(string: pr.url) ?? URL(string: "https://github.com")!)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(pr.title).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(pr.author).font(.callout.weight(.medium))
                Text("wants to merge").foregroundStyle(.secondary)
                branch(pr.headRef)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                branch(pr.baseRef)
                Text("· updated \(pr.updatedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack(spacing: 6) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                if let workspaces {
                    if workspaces.isEmpty {
                        Text(workspaceNote ?? "No workspace runs this branch in dev or qa.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(workspaces.enumerated()), id: \.offset) { _, workspace in
                            let env = workspace["environment"]?.string ?? "?"
                            Link(destination: URL(string: workspace["url"]?.string ?? "") ?? URL(string: "https://fubo.tv")!) {
                                Badge("\(workspace["name"]?.string ?? "workspace") · \(env)", tone: env == "qa" ? .warning : .success, systemImage: "network")
                            }
                            .help("Deployed by \(workspace["deployed_by"]?.string ?? "?")\(workspace["deployed_at"]?.string.map { " at \($0)" } ?? "")")
                        }
                        if let workspaceNote { Text(workspaceNote).font(.caption).foregroundStyle(.orange) }
                    }
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Looking for workspaces in dev and qa…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func branch(_ name: String) -> some View {
        Text(name).font(.callout.monospaced()).padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 5))
            .textSelection(.enabled)
            .contextMenu { Button("Copy Branch Name") { copy(name) } }
    }

    // MARK: Tabs

    @ViewBuilder
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSection("Description") {
                if pr.body.isEmpty { Text("No description.").foregroundStyle(.secondary) } else { InlineMarkdown(pr.body) }
            }
            DetailSection("Claude's review") {
                if let review = reviews.first { ReviewView(review: review) } else { Text("No Claude review yet.").foregroundStyle(.secondary) }
            }
        }
    }

    private var changes: some View {
        Group {
            if let files {
                List(Array(files.enumerated()), id: \.offset) { _, file in
                    DisclosureGroup {
                        Text(file["patch"]?.string ?? "No textual diff (binary or too large).")
                            .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack {
                            Text(file["filename"]?.string ?? "?").font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("+\(file["additions"]?.int ?? 0)").foregroundStyle(.green).font(.caption.monospacedDigit())
                            Text("−\(file["deletions"]?.int ?? 0)").foregroundStyle(.red).font(.caption.monospacedDigit())
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
                    .task { files = (try? await github?.client.files(pr.repo, pr.number)) ?? [] }
            }
        }
    }

    @ViewBuilder
    private var reviewsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSection("From reviewers") {
                if let human {
                    if human.reviews.isEmpty && human.comments.isEmpty { Text("No reviews yet.").foregroundStyle(.secondary) }
                    ForEach(Array(human.reviews.enumerated()), id: \.offset) { _, review in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(review["user"]?["login"]?.string ?? "?").bold()
                                let state = review["state"]?.string ?? ""
                                Badge(state.replacingOccurrences(of: "_", with: " ").capitalized,
                                      tone: state == "APPROVED" ? .success : state == "CHANGES_REQUESTED" ? .danger : .neutral)
                            }
                            if let body = review["body"]?.string, !body.isEmpty { InlineMarkdown(body) }
                        }
                    }
                    ForEach(Array(human.comments.suffix(30).enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(comment["user"]?["login"]?.string ?? "?") on \(comment["path"]?.string ?? "")\(comment["line"]?.int.map { ":\($0)" } ?? "")")
                                .font(.caption.weight(.semibold))
                            Text(comment["body"]?.string ?? "").font(.callout).textSelection(.enabled)
                        }
                    }
                } else {
                    ProgressView().task {
                        guard let github else { return }
                        let repo = pr.repo, number = pr.number
                        let reviews = (try? await github.client.reviews(repo, number)) ?? []
                        let comments = (try? await github.client.get("/repos/\(repo)/pulls/\(number)/comments?per_page=100"))?.json.array ?? []
                        human = (reviews, comments)
                    }
                }
            }
            DetailSection("Claude's reviews (\(reviews.count))") {
                ForEach(reviews) { review in
                    DisclosureGroup("\(review.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(review.verdict.isEmpty ? review.status : review.verdict)") {
                        ReviewView(review: review)
                    }
                }
            }
        }
    }

    private func loadWorkspaces() async {
        guard let github else { workspaces = []; return }
        let result = await github.workspaces(forBranch: pr.headRef)
        workspaces = result.found
        workspaceNote = result.note
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

/// Your review, worked through with Dashii: write what you think, Dashii answers with points you
/// keep (added to your notes) or set aside. All local.
private struct PRDiscussionView: View {
    let pr: PullRequest
    let feature: PullRequestsFeature
    @Bindable var discussion: PRDiscussion
    @State private var message = ""
    @State private var thinking = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if discussion.entries.isEmpty {
                                Text("Write what you think of this PR: a concern, a question, your verdict. Dashii checks it against the diff, tells you where you're right or wrong, and points out what you missed.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(discussion.entries) { entry in
                                entryView(entry)
                            }
                            if thinking { HStack { ProgressView().controlSize(.small); Text("Dashii is reading the diff…").foregroundStyle(.secondary) } }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(4)
                    }
                    .onChange(of: discussion.entries.count) { proxy.scrollTo("end") }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack(alignment: .bottom) {
                    TextField("Your thoughts on this PR…", text: $message, axis: .vertical).lineLimit(1...6).textFieldStyle(.roundedBorder)
                    Button("Send") { send() }.keyboardShortcut(.return, modifiers: .command).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thinking)
                }
            }
            .frame(minWidth: 420)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("My review notes").font(.headline)
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(discussion.draft, forType: .string)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy your notes")
                }
                TextEditor(text: $discussion.draft).font(.callout).scrollContentBackground(.hidden)
                    .padding(6).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                Text("Points you keep land here. Only you see this.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 260, idealWidth: 320)
            .padding(.leading, 8)
        }
    }

    @ViewBuilder
    private func entryView(_ entry: PRDiscussion.Entry) -> some View {
        if entry.author == "me" {
            HStack {
                Spacer(minLength: 60)
                Text(entry.text).textSelection(.enabled).padding(10).background(.tint.opacity(0.15), in: .rect(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !entry.text.isEmpty { Text(.init(entry.text)).textSelection(.enabled) }
                ForEach(entry.points) { point in
                    HStack(alignment: .top, spacing: 8) {
                        Badge(point.kind.capitalized, tone: tone(point.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let file = point.file { Text(file + (point.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        switch point.kept {
                        case true?: Label("Kept", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                        case false?: Text("Set aside").font(.caption).foregroundStyle(.secondary)
                        case nil:
                            Button("Keep") { decide(entry, point, keep: true) }.controlSize(.small)
                            Button("Set Aside") { decide(entry, point, keep: false) }.controlSize(.small)
                        }
                    }
                    .opacity(point.kept == false ? 0.5 : 1)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
        }
    }

    private func tone(_ kind: String) -> Tone {
        switch kind {
        case "agree": .success
        case "correction": .danger
        case "risk": .warning
        case "question": .info
        default: .neutral
        }
    }

    private func decide(_ entry: PRDiscussion.Entry, _ point: PRDiscussion.Point, keep: Bool) {
        var entries = discussion.entries
        guard let e = entries.firstIndex(where: { $0.id == entry.id }), let p = entries[e].points.firstIndex(where: { $0.id == point.id }) else { return }
        entries[e].points[p].kept = keep
        discussion.entries = entries
        if keep {
            let location = point.file.map { " (\($0)\(point.line.map { ":\($0)" } ?? ""))" } ?? ""
            discussion.draft += (discussion.draft.isEmpty || discussion.draft.hasSuffix("\n") ? "" : "\n") + "- \(point.text)\(location)\n"
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = ""
        thinking = true
        error = nil
        Task {
            do { try await feature.discuss(pr, discussion: discussion, message: text) } catch { self.error = error.localizedDescription }
            thinking = false
        }
    }
}
