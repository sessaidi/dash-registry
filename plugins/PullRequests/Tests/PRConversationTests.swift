import DashKit
import Foundation
import Testing

/// The PR conversation read from GitHub's GraphQL, and who may answer it.
@MainActor
struct PRConversationTests {
    @Test func readsThreadsCommentsAndReviews() throws {
        let data = try JSONValue.parse(#"""
            {"repository":{"pullRequest":{
              "reviewThreads":{"nodes":[
                {"id":"T1","isResolved":false,"isOutdated":false,"path":"api/a.swift","line":12,
                 "comments":{"nodes":[{"databaseId":7,"author":{"login":"ada"},"body":"Why not cache?","createdAt":"2026-11-15T10:00:00Z"}]}},
                {"id":"T2","isResolved":true,"isOutdated":true,"path":"api/b.swift","line":null,"comments":{"nodes":[]}}]},
              "comments":{"nodes":[{"databaseId":9,"author":null,"body":"LGTM","createdAt":"2026-11-15T11:00:00Z"}]},
              "reviews":{"nodes":[{"author":{"login":"sam"},"state":"CHANGES_REQUESTED","body":"Split it","submittedAt":"2026-11-15T12:00:00Z"}]}}}}
            """#)
        let conversation = PRConversation(data: data)
        #expect(conversation.threads.map(\.id) == ["T1", "T2"] && conversation.unresolved == 1)
        #expect(conversation.threads[0].comments.first == .init(id: 7, author: "ada", body: "Why not cache?", createdAt: PRConversation.date("2026-11-15T10:00:00Z")))
        #expect(conversation.threads[1].line == nil && conversation.threads[1].isOutdated)
        #expect(conversation.comments.first?.author == "ghost")
        #expect(conversation.reviews.first?.state == "CHANGES_REQUESTED")
    }

    @Test func onlyTheUserAnswersOnGitHub() {
        // Replying, commenting, resolving and submitting reviews are buttons in the PR sheet:
        // no Dashii tool (so no agent) can do any of it.
        let feature = PullRequestsFeature(defaults: UserDefaults(suiteName: "pr-\(UUID())")!)
        let names = feature.tools.map(\.name)
        for word in ["reply", "comment", "resolve", "approve", "submit", "request_changes"] {
            #expect(!names.contains { $0.contains(word) }, "a Dashii tool can \(word)")
        }
        #expect(feature.tools.filter(\.writesRemotely).map(\.name) == ["github_create_pr"])
    }
}
