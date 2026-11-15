import DashKit
import DashKitUI
import SwiftUI

/// Pull Requests: open PRs on the watched repositories with Dashii's review verdict and risk.
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
    static let summary = "Open PRs on watched repositories with Dashii's review verdict and risk. Open one to read the review, diff and checks; merging stays your click."
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
        PullRequestList(config: config, host: context.host, query: context.query(fields: PullRequest.queryFields), queryText: context.queryText)
    }

    /// Sample PRs and reviews in the same responsive view as the widget; no network, no store.
    static func preview(config: Config) -> some View {
        let pulls = PullRequestSamples.pulls().filter { matches($0, config) }
        let reviews = Dictionary(PullRequestSamples.reviews().map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
        return PullRequestsContent(pulls: pulls, reviews: reviews, onSelect: nil)
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

    static let actions = PullRequestsWidgetActions.actions
    static let queryFields = PullRequest.queryFields

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let github = context.host.ext(PullRequestsFeature.self),
              let tool = github.tools.first(where: { $0.name == "github_list_prs" }) else { return [] }
        let input: JSONValue = ["repo": config.repo.isEmpty ? .null : .string(config.repo), "filter": .string(config.filter)]
        return [
            "explanation": """
                Open pull requests on the watched repositories (filter: all, review_requested = someone asked the user to \
                review, mine = the user's own). Each has Dashii's automatic review when one ran: a verdict (approve, comment, \
                request changes) and a risk level; approvals and changes_requested count human reviews. Drafts aren't ready \
                for review yet.
                """,
            "pull_requests": (try? await tool.run(input)) ?? [],
        ]
    }
}
