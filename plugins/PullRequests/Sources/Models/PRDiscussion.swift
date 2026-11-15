import DashKit
import Foundation
import SwiftData

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

    /// Dashii's wording of something the user is about to post: a clearer version and what
    /// changed. Only a suggestion: the user decides and sends it themselves.
    struct Rewording: Equatable, Sendable {
        let rewrite: String
        let notes: [String]
    }

    static let rewordSchema: JSONValue = [
        "type": "object", "additionalProperties": false, "required": ["rewrite", "notes"],
        "properties": [
            "rewrite": ["type": "string", "description": "The text, reworded. Same language, same intent and verdict, in the user's voice."],
            "notes": ["type": "array", "items": ["type": "string"], "description": "Up to 4 short notes: what you changed and why, and anything wrong in the user's point given the diff."],
        ],
    ]

    func reword(_ text: String, purpose: String, context: String, pr: PullRequest) async throws -> Rewording {
        guard let host else { throw ToolError("Pull Requests isn't ready.") }
        let diff = (try? await client.diff(pr.repo, pr.number)) ?? ""
        let prompt = """
            Pull request \(pr.repo)#\(pr.number) “\(pr.title)” by \(pr.author).

            <diff>
            \(diff.prefix(30_000))
            </diff>

            <thread>
            \(context.prefix(6000))
            </thread>

            I'm about to post \(purpose). Here is my draft:

            <draft>
            \(text)
            </draft>

            Rewrite it so it's clear, specific and kind to the author: point at the code (file, line) when it helps, \
            say what to change and why, keep it short. Keep my intent and my verdict; don't add praise or filler. \
            If my point is wrong given the diff, say so in the notes.
            """
        let answer = try JSONValue.parse(try await host.dashii.complete(
            system: "You help an engineer word their own code review comments. You never post anything; they decide.",
            prompt: prompt, outputSchema: Self.rewordSchema, effort: "low"))
        return Rewording(rewrite: answer["rewrite"]?.string ?? text, notes: answer["notes"]?.array?.compactMap(\.string) ?? [])
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
