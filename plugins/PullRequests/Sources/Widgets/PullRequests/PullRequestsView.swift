import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The live widget: PRs and reviews from the store (`@Query`), so syncs and reviews show as they land;
/// handles Dashii's actions and publishes the selection for linked widgets.
struct PullRequestList: View {
    @Binding var config: PullRequestsWidget.Config
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after the repo, filter and search.
    let query: WidgetQuery?
    let queryText: String
    @State private var queryIDs: [PullRequest.ID]?
    @Query(sort: \PullRequest.updatedAt, order: .reverse) private var pulls: [PullRequest]
    @Query(sort: \PRReview.createdAt, order: .reverse) private var reviews: [PRReview]
    /// The PR whose detail sheet is open.
    @State private var opened: PullRequest?
    /// The PR the user picked: highlighted and published for linked widgets until another is
    /// picked or it's clicked again.
    @State private var selectedUID: String?
    /// A search Dashii typed (title, author, branch, repo or #number); not saved.
    @State private var search = ""
    /// What Dashii's actions changed for now (repo, filter); the saved settings stay. Resets when
    /// they change.
    @State private var override: PullRequestsWidget.Config?

    private var effective: PullRequestsWidget.Config { override ?? config }

    private var narrowed: [PullRequest] {
        let config = effective
        return pulls.filter { PullRequestsWidget.matches($0, config) && PullRequestsWidgetActions.matches($0, search: search) }
    }

    /// What the widget lists: the repo, filter and search, then the DashQL query.
    private var visible: [PullRequest] { QueryRows.ordered(narrowed, by: queryIDs) }

    private func row(_ pr: PullRequest) -> JSONValue { pr.queryRow(review: reviews.first { $0.prUID == pr.uid }) }

    var body: some View {
        list
            .handlesWidgetActions { name, input in
                if name == "clear_selection" {
                    selectedUID = nil
                    return "cleared"
                }
                if name == "clear" {
                    // Back to the widget's own settings.
                    search = ""
                    override = nil
                    return "cleared"
                }
                // Actions change what's shown for now, never the saved settings.
                var view = effective
                let outcome = try PullRequestsWidgetActions.perform(name, input, config: &view, search: &search, pulls: visible)
                override = view == config ? nil : view
                if let pr = outcome.select {
                    selectedUID = pr.uid
                    opened = pr
                }
                return outcome.reply
            }
            .onChange(of: config) { override = nil }
            .onExitCommand { selectedUID = nil }
            .reportsSelection(selectedUID.flatMap { uid in pulls.first { $0.uid == uid }.map(row) })
            .reportsWidgetState([
                "repo": effective.repo.isEmpty ? "all watched" : .string(effective.repo), "filter": .string(effective.filter),
                "selected": selectedUID.flatMap { uid in pulls.first { $0.uid == uid }.map { .string("\($0.repo)#\($0.number)") } } ?? .null,
                "temporary_changes": .bool(override != nil),
                "search": search.isEmpty ? .null : .string(search),
                "shown": .array(visible.prefix(30).map { .string("\($0.repo)#\($0.number) \($0.title)") }),
                "open_pr": opened.map { .string("\($0.repo)#\($0.number)") } ?? .null,
            ])
            .task(id: QueryRows.key(queryText, narrowed, row: row)) {
                queryIDs = await QueryRows.ids(query, narrowed, row: row)
            }
    }

    private var list: some View {
        let github = host.ext(PullRequestsFeature.self)
        let visible = visible
        let latest = Dictionary(reviews.map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
        return Group {
            if github?.github?.isConnected != true {
                ContentUnavailableView {
                    Label("Connect GitHub", systemImage: "arrow.triangle.pull")
                } description: {
                    Text("Add a token and the repositories to watch in Settings › GitHub.")
                } actions: {
                    Button("Connect GitHub…") { host.openManager("github") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(
                    github?.isSyncing == true ? "Checking…" : "No open PRs", systemImage: "checkmark.circle",
                    description: Text(github?.lastError ?? (github?.repos.isEmpty == true ? "Add repositories in Settings › GitHub." : "")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    QueryCount(shown: visible.count, total: narrowed.count, query: queryText)
                    PullRequestRows(pulls: visible, reviews: latest, selectedUID: selectedUID) { pick($0) }
                }
            }
        }
        .sheet(item: $opened) { PullRequestSheet(pr: $0, host: host) }
    }

    /// Clicking a PR selects it and opens its detail; clicking the selected one again unselects it.
    private func pick(_ pr: PullRequest) {
        if selectedUID == pr.uid {
            selectedUID = nil
        } else {
            selectedUID = pr.uid
            opened = pr
        }
    }
}

/// The list itself, fed plain values so the gallery preview can draw sample PRs.
struct PullRequestRows: View {
    let pulls: [PullRequest]
    /// Latest review per PR uid.
    let reviews: [String: PRReview]
    var selectedUID: String? = nil
    /// nil: rows don't open (previews).
    let onSelect: ((PullRequest) -> Void)?

    var body: some View {
        List(pulls) { pr in
            PullRequestRow(pr: pr, review: reviews[pr.uid])
                .contentShape(.rect)
                .onTapGesture { onSelect?(pr) }
                .listRowBackground(selectedUID == pr.uid ? Color.accentColor.opacity(0.18) : Color.clear)
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
