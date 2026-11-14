import DashKit
import Foundation
import Testing

/// The REST client over the integration's connection, against stubbed responses.
@MainActor
struct GitHubClientTests {
    let host = "gh-\(UUID().uuidString.lowercased()).test"

    var client: GitHubClient {
        GitHubClient(connection: IntegrationConnection(
            baseURL: URL(string: "https://\(host)")!, headers: ["Authorization": "Bearer t0ken", "Accept": "application/vnd.github+json"],
            session: StubProtocol.session()))
    }

    @Test func viewerAndHeaders() async throws {
        StubProtocol.serve(host, routes: ["/user": .json(#"{"login":"octocat"}"#)])
        #expect(try await client.viewer() == "octocat")
        let sent = try #require(StubProtocol.requests(host).last)
        #expect(sent.url?.absoluteString == "https://\(host)/user")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(sent.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func openPullsUsesETags() async throws {
        StubProtocol.serve(host) { request in
            request.value(forHTTPHeaderField: "If-None-Match") == #"W/"abc""#
                ? StubProtocol.Reply(status: 304)
                : .json(Fixtures.list(Fixtures.pull(7, sha: "aaa")), etag: #"W/"abc""#)
        }
        let first = try await client.openPulls("acme/api", etag: nil)
        #expect(!first.notModified && first.etag == #"W/"abc""#)
        #expect(first.json[0]?["number"]?.int == 7)
        let query = try #require(StubProtocol.requests(host).last?.url?.query())
        #expect(query == "state=open&per_page=100&sort=updated&direction=desc")

        let second = try await client.openPulls("acme/api", etag: first.etag)
        #expect(second.notModified && second.etag == #"W/"abc""# && second.json == .null)
    }

    @Test func diffAsksForTheDiffMediaType() async throws {
        StubProtocol.serve(host, routes: ["/repos/acme/api/pulls/7": .text("diff --git a/x b/x\n+hello\n")])
        #expect(try await client.diff("acme/api", 7) == "diff --git a/x b/x\n+hello\n")
        #expect(StubProtocol.requests(host).last?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.diff")
    }

    @Test func listsFilesReviewsAndComments() async throws {
        StubProtocol.serve(host, routes: [
            "/repos/acme/api/pulls/7/files": .json(#"[{"filename":"a.swift","status":"modified","additions":3,"deletions":1}]"#),
            "/repos/acme/api/pulls/7/reviews": .json(#"[{"user":{"login":"bob"},"state":"APPROVED","body":"lgtm"}]"#),
            "/repos/acme/api/issues/7/comments": .json(#"[{"user":{"login":"amy"},"body":"ping"}]"#),
        ])
        #expect(try await client.files("acme/api", 7).first?["filename"] == "a.swift")
        #expect(try await client.reviews("acme/api", 7).first?["state"] == "APPROVED")
        #expect(try await client.comments("acme/api", 7).first?["body"] == "ping")
        let queries = StubProtocol.requests(host).compactMap { $0.url?.query() }
        #expect(queries == ["per_page=100", "per_page=100", "per_page=50"])
    }

    @Test func writesSendTheRightMethodsAndBodies() async throws {
        StubProtocol.serve(host, routes: [
            "PUT /repos/acme/api/pulls/7/merge": .json(#"{"merged":true}"#),
            "POST /repos/acme/api/pulls": .json(#"{"number":8,"html_url":"https://github.com/acme/api/pull/8"}"#, status: 201),
        ])
        try await client.merge("acme/api", 7, method: "squash")
        let created = try await client.createPull("acme/api", title: "T", head: "h", base: "main", body: "B", draft: true)
        #expect(created["number"]?.int == 8)

        let sent = StubProtocol.requests(host)
        #expect(sent.map { $0.httpMethod ?? "" } == ["PUT", "POST"])
        #expect(sent[0].bodyJSON == ["merge_method": "squash"])
        #expect(sent[1].bodyJSON == ["title": "T", "head": "h", "base": "main", "body": "B", "draft": true])
    }

    @Test func repositoryLookups() async throws {
        StubProtocol.serve(host, routes: [
            "/repos/acme/api": .json(#"{"default_branch":"trunk"}"#),
            "/repos/acme/api/commits/v1.2": .json(#"{"sha":"deadbeef"}"#),
            "/repos/acme/api/commits/nope": .json("{}"),
            "/repos/acme/api/contents/docs/read%20me.md": .json(#"{"content":"aGVs\nbG8="}"#),
        ])
        #expect(try await client.defaultBranch("acme/api") == "trunk")
        #expect(try await client.resolve("acme/api", ref: "v1.2") == "deadbeef")
        #expect(try await client.file("acme/api", path: "docs/read me.md", ref: "main") == Data("hello".utf8))
        await #expect(throws: ToolError.self) { _ = try await client.resolve("acme/api", ref: "nope") }
    }

    @Test func errorsCarryGitHubsMessage() async throws {
        StubProtocol.serve(host, routes: ["/user": .json(#"{"message":"Bad credentials"}"#, status: 401)])
        do {
            _ = try await client.viewer()
            Issue.record("expected an error")
        } catch let error as HTTPError {
            #expect(error.status == 401 && error.service == "GitHub" && error.message == "Bad credentials")
        }
    }
}
