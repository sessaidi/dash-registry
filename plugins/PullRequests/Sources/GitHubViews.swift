import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct PullRequestsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// owner/name, or empty for every watched repository.
        var repo: String
        /// all, review_requested, mine
        var filter: String
    }

    static let kind = "github.pulls"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 24)
    static let displayName = "Pull Requests"
    static let summary = "Open PRs on watched repositories with Claude's review verdict and risk. Open one to read the review, comment, approve or merge."
    static let systemImage = "arrow.triangle.pull"
    static let defaultSize = WidgetSize.large
    static let defaultConfig = Config(repo: "", filter: "all")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "repo": ["type": "string", "description": "owner/name to show, or empty for all watched repositories."],
            "filter": ["type": "string", "enum": ["all", "review_requested", "mine"]],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        PullRequestList(config: config.wrappedValue, host: context.host)
    }

    /// Sample PRs and a sample review; no network, no store.
    static func preview(config: Config) -> some View {
        let pulls = PullRequestSamples.pulls().filter { matches($0, config) }
        let reviews = Dictionary(PullRequestSamples.reviews().map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
        return PullRequestRows(pulls: pulls, reviews: reviews, onSelect: nil)
    }

    /// The widget's repo and filter applied to one PR.
    static func matches(_ pr: PullRequest, _ config: Config) -> Bool {
        (config.repo.isEmpty || pr.repo == config.repo)
            && (config.filter != "review_requested" || pr.reviewRequested)
            && (config.filter != "mine" || pr.isMine)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        TextField("Repository", text: config.repo, prompt: Text("All watched"))
        Picker("Show", selection: config.filter) {
            Text("All open").tag("all")
            Text("Review requested").tag("review_requested")
            Text("Mine").tag("mine")
        }
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let github = context.host.ext(PullRequestsFeature.self),
              let tool = github.tools.first(where: { $0.name == "github_list_prs" }) else { return [] }
        let input: JSONValue = ["repo": config.repo.isEmpty ? .null : .string(config.repo), "filter": .string(config.filter)]
        return (try? await tool.run(input)) ?? []
    }
}

private struct PullRequestList: View {
    let config: PullRequestsWidget.Config
    let host: any ExtensionContext
    @Query(sort: \PullRequest.updatedAt, order: .reverse) private var pulls: [PullRequest]
    @Query(sort: \PRReview.createdAt, order: .reverse) private var reviews: [PRReview]
    @State private var selected: PullRequest?

    var body: some View {
        let github = host.ext(PullRequestsFeature.self)
        let visible = pulls.filter { PullRequestsWidget.matches($0, config) }
        let latest = Dictionary(reviews.map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
        Group {
            if github?.github?.isConnected != true {
                ContentUnavailableView {
                    Label("Connect GitHub", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("Add a token and the repositories to watch in Settings › GitHub.")
                } actions: {
                    Button("Connect GitHub…") { host.openManager("github") }
                }
            } else if visible.isEmpty {
                ContentUnavailableView(
                    github?.isSyncing == true ? "Checking…" : "No open PRs", systemImage: "checkmark.circle",
                    description: Text(github?.lastError ?? (github?.repos.isEmpty == true ? "Add repositories in Settings › GitHub." : "")))
            } else {
                PullRequestRows(pulls: visible, reviews: latest) { selected = $0 }
            }
        }
        .sheet(item: $selected) { PullRequestSheet(pr: $0, host: host) }
    }
}

/// The list itself, fed plain values so the gallery preview can draw sample PRs.
private struct PullRequestRows: View {
    let pulls: [PullRequest]
    /// Latest review per PR uid.
    let reviews: [String: PRReview]
    /// nil: rows don't open (previews).
    let onSelect: ((PullRequest) -> Void)?

    var body: some View {
        List(pulls) { pr in
            PullRequestRow(pr: pr, review: reviews[pr.uid])
                .contentShape(.rect)
                .onTapGesture { onSelect?(pr) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

private struct PullRequestRow: View {
    let pr: PullRequest
    let review: PRReview?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ReviewBadge(review: review)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if pr.isDraft { Text("Draft").font(.caption2).foregroundStyle(.secondary) }
                    Text(pr.title).lineLimit(1)
                }
                Text("\(pr.repo)#\(pr.number) · \(pr.author) · \(pr.updatedAt.relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pr.reviewRequested {
                Image(systemName: "eye").foregroundStyle(.orange).help("Your review is requested")
            }
        }
    }
}

struct ReviewBadge: View {
    let review: PRReview?

    var body: some View {
        Group {
            switch review?.status {
            case "done":
                Image(systemName: review?.verdict == "approve" ? "checkmark.seal.fill" : review?.verdict == "request_changes" ? "xmark.seal.fill" : "text.bubble.fill")
                    .foregroundStyle(riskColor)
            case "running", "queued":
                ProgressView().controlSize(.small)
            case "failed":
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            default:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
        .help(review.map { "\($0.status) · \($0.verdict) · risk \($0.risk)" } ?? "Not reviewed")
    }

    private var riskColor: Color {
        switch review?.risk {
        case "high": .red
        case "medium": .orange
        default: .green
        }
    }
}

struct PullRequestSheet: View {
    let pr: PullRequest
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @Query private var reviews: [PRReview]
    @State private var error: String?
    @State private var busy = false
    @State private var confirmMerge = false

    init(pr: PullRequest, host: any ExtensionContext) {
        self.pr = pr
        self.host = host
        let uid = pr.uid
        _reviews = Query(filter: #Predicate<PRReview> { $0.prUID == uid }, sort: \.createdAt, order: .reverse)
    }

    private var github: PullRequestsFeature? { host.ext(PullRequestsFeature.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(pr.repo)#\(pr.number)").font(.headline.monospaced())
                if pr.isDraft { Text("Draft").foregroundStyle(.secondary) }
                Spacer()
                Link("Open on GitHub", destination: URL(string: pr.url) ?? URL(string: "https://github.com")!)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(pr.title).font(.title3.bold())
            Text("\(pr.author) wants to merge \(pr.headRef) into \(pr.baseRef)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let review = reviews.first { ReviewView(review: review) } else { Text("No Claude review yet.").foregroundStyle(.secondary) }
                    if !pr.body.isEmpty {
                        Divider()
                        InlineMarkdown(pr.body)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            // Claude's reviews are for you only: Dash never comments on or reviews the pull request.
            Label("Reviews stay in Dash. Nothing is posted to the pull request.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let review = reviews.first, review.status == "done" {
                    Button("Copy Review", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(review.markdown, forType: .string)
                    }
                    .help("Copy Claude's review as Markdown, to use however you like")
                }
                Button("Re-review", systemImage: "arrow.clockwise") { github?.requestReview(pr) }
                Button("Ask Claude", systemImage: "sparkles") {
                    host.askClaude("Let's discuss PR \(pr.repo)#\(pr.number). Read it and its Claude review first.")
                    dismiss()
                }
                Spacer()
                Button("Merge…") { confirmMerge = true }.disabled(busy || pr.isDraft)
            }
        }
        .padding(20)
        .frame(width: 700, height: 640)
        .confirmationDialog("Merge \(pr.repo)#\(pr.number)?", isPresented: $confirmMerge) {
            Button("Squash and Merge") { run { try await github?.client.merge(pr.repo, pr.number, method: "squash"); await github?.sync() } }
            Button("Merge Commit") { run { try await github?.client.merge(pr.repo, pr.number, method: "merge"); await github?.sync() } }
            Button("Rebase and Merge") { run { try await github?.client.merge(pr.repo, pr.number, method: "rebase"); await github?.sync() } }
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

private struct ReviewView: View {
    let review: PRReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ReviewBadge(review: review)
                Text("Claude review").font(.headline)
                if review.status == "done" {
                    Text("\(review.verdict.replacing("_", with: " ")) · risk \(review.risk)").foregroundStyle(.secondary)
                } else {
                    Text(review.status).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(review.headSHA.prefix(7)) · \(review.createdAt.relative)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let error = review.error { Text(error).foregroundStyle(.red) }
            if !review.summary.isEmpty { Text(review.summary).textSelection(.enabled) }
            ForEach(review.findings, id: \.self) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(finding.severity.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(finding.severity == "blocker" || finding.severity == "major" ? .red : .orange)
                        Text(finding.title).bold()
                    }
                    Text(finding.line > 0 ? "\(finding.file):\(finding.line)" : finding.file).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(finding.detail).font(.callout).textSelection(.enabled)
                    if !finding.suggestion.isEmpty { Text("→ \(finding.suggestion)").font(.callout).foregroundStyle(.secondary) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
            if !review.testing.isEmpty {
                Text("Testing: \(review.testing)").font(.callout)
            }
        }
    }
}

/// The PR description with inline Markdown (bold, code, links); Dash's block renderer is app-internal.
private struct InlineMarkdown: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
