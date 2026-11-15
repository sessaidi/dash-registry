import DashKit
import Foundation
import Testing

/// The fixed review format: the schema Claude answers in, the stored model, and the Markdown posted to GitHub.
@MainActor
struct ReviewFormatTests {
    @Test func schemaIsStrict() {
        let schema = PullRequestsFeature.reviewSchema
        #expect(schema["additionalProperties"] == false)
        #expect(schema["required"] == ["verdict", "risk", "summary", "findings", "testing"])
        #expect(schema["properties"]?["verdict"]?["enum"] == ["approve", "comment", "request_changes"])
        #expect(schema["properties"]?["risk"]?["enum"] == ["low", "medium", "high"])
        let finding = schema["properties"]?["findings"]?["items"]
        #expect(finding?["required"] == ["file", "line", "severity", "title", "detail", "suggestion"])
        #expect(finding?["properties"]?["severity"]?["enum"] == ["blocker", "major", "minor", "nit"])
    }

    @Test func findingsRoundTripThroughStoredData() throws {
        let review = PRReview(prUID: "acme/api#1", headSHA: "abc1234567", model: "m")
        #expect(review.uid == "acme/api#1@abc1234567" && review.status == "queued" && review.findings.isEmpty)
        let parsed = try JSONValue.parse(Fixtures.review)["findings"]?.decode([PRReview.Finding].self) ?? []
        review.findings = parsed
        #expect(review.findings == parsed && review.findings.count == 2)
        review.findingsData = Data("not json".utf8)
        #expect(review.findings.isEmpty)
    }

    @Test func jsonExposesTheReview() throws {
        let review = PRReview(prUID: "acme/api#1", headSHA: "abc", model: "m")
        review.status = "failed"
        review.error = "boom"
        #expect(review.json["status"] == "failed" && review.json["error"] == "boom" && review.json["headSHA"] == "abc")
        #expect(review.json["findings"] == [])
        review.error = nil
        #expect(review.json["error"] == .null)
    }

    @Test func markdownTableEscapesAndPlacesFindings() throws {
        let review = PRReview(prUID: "acme/api#1", headSHA: "abc1234567", model: "claude-opus-5-5")
        let result = try JSONValue.parse(Fixtures.review)
        review.verdict = result["verdict"]?.string ?? ""
        review.risk = result["risk"]?.string ?? ""
        review.summary = result["summary"]?.string ?? ""
        review.testing = result["testing"]?.string ?? ""
        review.findings = try result["findings"]?.decode([PRReview.Finding].self) ?? []
        #expect(review.markdown == """
            ### Dashii review — request changes · risk high

            Adds retries; 4xx responses are retried too.

            | Severity | Where | Finding |
            |---|---|---|
            | major | `Sources/Fetcher.swift:58` | **Retries 4xx** shouldRetry is true for \\| every error including 404. _Suggestion:_ Retry 429 and 5xx only. |
            | nit | `README.md` | **Typo** recieve |

            **Testing:** No test for the give-up path.

            <sub>Reviewed at abc1234 with claude-opus-5-5 from Dash.</sub>
            """)
    }

    @Test func markdownWithoutFindingsOrTesting() {
        let review = PRReview(prUID: "acme/api#1", headSHA: "abc1234567", model: "m")
        review.verdict = "approve"
        review.risk = "low"
        review.summary = "Sound."
        #expect(review.markdown == "### Dashii review — approve · risk low\n\nSound.\n\n<sub>Reviewed at abc1234 with m from Dash.</sub>")
    }

    @Test func pullRequestApplyTracksHeadChanges() {
        let pr = PullRequest(uid: PullRequest.uid("acme/api", 3), repo: "acme/api", number: 3)
        #expect(pr.uid == "acme/api#3")
        let item = try! JSONValue.parse(Fixtures.pull(3, sha: "s1", author: "me", draft: true, requested: ["me", "bob"]))
        #expect(pr.apply(item, viewer: "me"))
        #expect(pr.isDraft && pr.isMine && pr.reviewRequested && pr.url == "https://github.com/acme/api/pull/3")
        #expect(!pr.apply(item, viewer: "bob") && !pr.isMine && pr.reviewRequested)
        #expect(!pr.apply(item, viewer: "carol") && !pr.reviewRequested)
    }
}
