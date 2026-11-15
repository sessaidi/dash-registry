import DashKit
import Foundation

/// What Dashii can do with the Pull Requests widget. Only what it shows changes: nothing is
/// commented, approved or merged.
enum PullRequestsWidgetActions {
    static let actions = [
        WidgetAction(name: "search", description: "Narrow the list to PRs whose title, author, branch or repository contains the text (or \"#123\"). Empty clears it.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
        WidgetAction(name: "set_filter", description: "Show all open PRs, the ones the user is asked to review, or the user's own. Temporary: the widget's saved filter stays.",
                     properties: ["filter": JSONSchema.string("all, review_requested or mine.", enum: ["all", "review_requested", "mine"])], required: ["filter"]),
        WidgetAction(name: "set_repo", description: "Show one repository (owner/name), or \"\" for every watched one. Temporary: the widget's saved repository stays.",
                     properties: ["repo": JSONSchema.string("owner/name.")], required: ["repo"]),
        WidgetAction(name: "select", description: "Select a PR and open its detail (Dashii's review, diff, checks); linked widgets follow the selection. owner/name#123, #123, 123, or a unique part of its title.",
                     properties: ["pr": JSONSchema.string("Which PR.")], required: ["pr"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected PR."),
        WidgetAction(name: "clear", description: "Clear the search and Dashii's temporary repository and filter (back to the widget's settings)."),
    ]

    struct Outcome {
        var reply: JSONValue
        var select: PullRequest?
    }

    static func matches(_ pr: PullRequest, search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        if text.hasPrefix("#"), let number = Int(text.dropFirst()) { return pr.number == number }
        return [pr.title, pr.author, pr.headRef, pr.repo].contains { $0.lowercased().contains(text) }
    }

    /// owner/name#123, #123, 123, or the only PR whose title contains the text.
    static func find(_ text: String, in pulls: [PullRequest]) -> PullRequest? {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if let hash = wanted.lastIndex(of: "#"), let number = Int(wanted[wanted.index(after: hash)...]) {
            let repo = String(wanted[..<hash]).lowercased()
            return pulls.first { $0.number == number && (repo.isEmpty || $0.repo.lowercased() == repo) }
        }
        if let number = Int(wanted) { return pulls.first { $0.number == number } }
        let hits = pulls.filter { $0.title.lowercased().contains(wanted.lowercased()) }
        return hits.count == 1 ? hits[0] : nil
    }

    static func perform(_ name: String, _ input: JSONValue, config: inout PullRequestsWidget.Config, search: inout String,
                        pulls: [PullRequest]) throws -> Outcome {
        switch name {
        case "search":
            search = input["text"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return Outcome(reply: ["search": search.isEmpty ? .null : .string(search),
                                   "matches": .number(Double(pulls.filter { matches($0, search: search) }.count))])
        case "set_filter":
            guard let filter = input["filter"]?.string, ["all", "review_requested", "mine"].contains(filter) else {
                throw ToolError("Filter is all, review_requested or mine.")
            }
            config.filter = filter
            return Outcome(reply: ["filter": .string(filter)])
        case "set_repo":
            config.repo = input["repo"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return Outcome(reply: ["repo": config.repo.isEmpty ? "all watched" : .string(config.repo)])
        case "select":
            guard let pr = find(input["pr"]?.string ?? "", in: pulls) else {
                throw ToolError("No single shown PR matches “\(input["pr"]?.string ?? "")”.")
            }
            return Outcome(reply: ["opened": .string("\(pr.repo)#\(pr.number)")], select: pr)
        case "clear":
            search = ""
            config.repo = ""
            config.filter = "all"
            return Outcome(reply: "cleared")
        default:
            throw ToolError("Unknown action \(name).")
        }
    }
}
