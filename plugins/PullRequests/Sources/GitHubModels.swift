import DashKit
import DashKitUI
import Foundation
import SwiftData

@Model
final class PullRequest {
    /// "owner/repo#123"
    @Attribute(.unique) var uid: String
    var repo: String
    var number: Int
    var title: String
    var author: String
    var body: String
    var url: String
    var headSHA: String
    var headRef: String
    var baseRef: String
    var isDraft: Bool
    var createdAt: Date
    var updatedAt: Date
    /// Your review was requested on this PR.
    var reviewRequested: Bool
    var isMine: Bool
    /// Feedback on your own PRs: reviewers whose latest decision is approve / request changes.
    var approvals: Int = 0
    var changesRequested: Int = 0
    /// The newest review from someone else, and who left it.
    var feedbackAt: Date?
    var feedbackFrom: String = ""
    /// Reviews were fetched at least once (the first fetch doesn't announce old feedback).
    var feedbackChecked: Bool = false

    init(uid: String, repo: String, number: Int) {
        self.uid = uid
        self.repo = repo
        self.number = number
        title = ""
        author = ""
        body = ""
        url = ""
        headSHA = ""
        headRef = ""
        baseRef = ""
        isDraft = false
        createdAt = .now
        updatedAt = .now
        reviewRequested = false
        isMine = false
    }

    static func uid(_ repo: String, _ number: Int) -> String { "\(repo)#\(number)" }

    /// Applies a pulls-list item. Returns true when the head commit changed.
    @discardableResult
    func apply(_ json: JSONValue, viewer: String) -> Bool {
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PullRequest, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        let sha = json["head"]?["sha"]?.string ?? ""
        let changed = sha != headSHA
        set(\.title, json["title"]?.string ?? "")
        set(\.author, json["user"]?["login"]?.string ?? "")
        set(\.body, json["body"]?.string ?? "")
        set(\.url, json["html_url"]?.string ?? "")
        set(\.headSHA, sha)
        set(\.headRef, json["head"]?["ref"]?.string ?? "")
        set(\.baseRef, json["base"]?["ref"]?.string ?? "")
        set(\.isDraft, json["draft"]?.bool ?? false)
        set(\.createdAt, ISO8601DateFormatter.date(json["created_at"]?.string) ?? .now)
        set(\.updatedAt, ISO8601DateFormatter.date(json["updated_at"]?.string) ?? .now)
        let requested = json["requested_reviewers"]?.array?.contains { $0["login"]?.string == viewer } ?? false
        set(\.reviewRequested, requested)
        set(\.isMine, author == viewer)
        return changed
    }
}

/// A Claude review of one PR at one head commit.
@Model
final class PRReview {
    /// "owner/repo#123@sha"
    @Attribute(.unique) var uid: String
    var prUID: String
    var headSHA: String
    var createdAt: Date
    /// queued, running, done, failed
    var status: String
    var model: String
    var verdict: String
    var risk: String
    var summary: String
    var findingsData: Data
    var testing: String
    var error: String?
    var postedToGitHub: Bool

    init(prUID: String, headSHA: String, model: String) {
        uid = "\(prUID)@\(headSHA)"
        self.prUID = prUID
        self.headSHA = headSHA
        self.model = model
        createdAt = .now
        status = "queued"
        verdict = ""
        risk = ""
        summary = ""
        findingsData = Data("[]".utf8)
        testing = ""
        postedToGitHub = false
    }

    struct Finding: Codable, Hashable, Sendable {
        let file: String
        let line: Int
        let severity: String
        let title: String
        let detail: String
        let suggestion: String
    }

    var findings: [Finding] {
        get { (try? JSONDecoder().decode([Finding].self, from: findingsData)) ?? [] }
        set { findingsData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }

    var json: JSONValue {
        ["status": .string(status), "verdict": .string(verdict), "risk": .string(risk), "summary": .string(summary),
         "testing": .string(testing), "headSHA": .string(headSHA), "error": error.map(JSONValue.string) ?? .null,
         "findings": (try? JSONValue(encoding: findings)) ?? []]
    }

    /// Markdown body for posting the review to GitHub.
    var markdown: String {
        var lines = ["### Claude review — \(verdict.replacing("_", with: " ")) · risk \(risk)", "", summary, ""]
        if !findings.isEmpty {
            lines.append("| Severity | Where | Finding |")
            lines.append("|---|---|---|")
            for finding in findings {
                let place = finding.line > 0 ? "`\(finding.file):\(finding.line)`" : "`\(finding.file)`"
                let text = "**\(finding.title)** \(finding.detail)" + (finding.suggestion.isEmpty ? "" : " _Suggestion:_ \(finding.suggestion)")
                lines.append("| \(finding.severity) | \(place) | \(text.replacing("\n", with: " ").replacing("|", with: "\\|")) |")
            }
            lines.append("")
        }
        if !testing.isEmpty { lines += ["**Testing:** \(testing)", ""] }
        lines.append("<sub>Reviewed at \(headSHA.prefix(7)) with \(model) from Dash.</sub>")
        return lines.joined(separator: "\n")
    }
}
