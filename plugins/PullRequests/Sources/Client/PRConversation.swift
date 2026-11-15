import DashKit
import Foundation

/// A pull request's conversation on GitHub: review threads on lines, general comments and reviews.
///
/// Answering it (reply, comment, resolve, approve, request changes) is the user's alone: these
/// calls are made only from buttons in the PR sheet, after the user confirms. They're never a
/// Dashii tool or a widget action, so neither Dashii nor any agent can post as the user.
struct PRConversation: Equatable, Sendable {
    struct Comment: Equatable, Sendable, Identifiable {
        /// The REST id (replies go to it).
        let id: Int
        let author: String
        let body: String
        let createdAt: Date?
    }

    struct Thread: Equatable, Sendable, Identifiable {
        /// The GraphQL node id (resolving uses it).
        let id: String
        let path: String
        let line: Int?
        let isResolved: Bool
        let isOutdated: Bool
        let comments: [Comment]
    }

    struct Review: Equatable, Sendable {
        let author: String
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED
        let state: String
        let body: String
        let submittedAt: Date?
    }

    var threads: [Thread] = []
    var comments: [Comment] = []
    var reviews: [Review] = []

    var unresolved: Int { threads.filter { !$0.isResolved }.count }

    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) { nodes { id isResolved isOutdated path line
                comments(first: 50) { nodes { databaseId author { login } body createdAt } } } }
              comments(first: 100) { nodes { databaseId author { login } body createdAt } }
              reviews(last: 30) { nodes { author { login } state body submittedAt } }
            }
          }
        }
        """

    /// From the GraphQL answer's `data`.
    init(data: JSONValue) {
        let pull = data["repository"]?["pullRequest"] ?? .null
        func comment(_ node: JSONValue) -> Comment {
            Comment(id: node["databaseId"]?.int ?? 0, author: node["author"]?["login"]?.string ?? "ghost",
                    body: node["body"]?.string ?? "", createdAt: node["createdAt"]?.string.flatMap(Self.date))
        }
        threads = (pull["reviewThreads"]?["nodes"]?.array ?? []).map { node in
            Thread(id: node["id"]?.string ?? "", path: node["path"]?.string ?? "", line: node["line"]?.int,
                   isResolved: node["isResolved"]?.bool ?? false, isOutdated: node["isOutdated"]?.bool ?? false,
                   comments: (node["comments"]?["nodes"]?.array ?? []).map(comment))
        }
        comments = (pull["comments"]?["nodes"]?.array ?? []).map(comment)
        reviews = (pull["reviews"]?["nodes"]?.array ?? []).map { node in
            Review(author: node["author"]?["login"]?.string ?? "ghost", state: node["state"]?.string ?? "",
                   body: node["body"]?.string ?? "", submittedAt: node["submittedAt"]?.string.flatMap(Self.date))
        }
    }

    init() {}

    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}

/// The user's answers on GitHub, sent only from the PR sheet's buttons (see `PRConversation`).
extension GitHubClient {
    func graphQL(_ query: String, variables: JSONValue) async throws -> JSONValue {
        let answer = try await send("/graphql", method: "POST", body: ["query": .string(query), "variables": variables])
        if let message = answer["errors"]?.array?.first?["message"]?.string { throw ToolError("GitHub: \(message)") }
        return answer["data"] ?? .null
    }

    func conversation(_ repo: String, _ number: Int) async throws -> PRConversation {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ToolError("Bad repository \(repo)") }
        return PRConversation(data: try await graphQL(PRConversation.query,
                                                      variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "number": .number(Double(number))]))
    }

    /// Answers a review thread (a reply to its first comment).
    func reply(_ repo: String, _ number: Int, to commentID: Int, body: String) async throws {
        _ = try await send("/repos/\(repo)/pulls/\(number)/comments/\(commentID)/replies", method: "POST", body: ["body": .string(body)])
    }

    /// A comment on the pull request's conversation.
    func comment(_ repo: String, _ number: Int, body: String) async throws {
        _ = try await send("/repos/\(repo)/issues/\(number)/comments", method: "POST", body: ["body": .string(body)])
    }

    /// APPROVE, REQUEST_CHANGES or COMMENT, with the review's text.
    func submitReview(_ repo: String, _ number: Int, event: String, body: String) async throws {
        _ = try await send("/repos/\(repo)/pulls/\(number)/reviews", method: "POST", body: ["event": .string(event), "body": .string(body)])
    }

    func setResolved(threadID: String, _ resolved: Bool) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }"
        _ = try await graphQL(mutation, variables: ["id": .string(threadID)])
    }
}
