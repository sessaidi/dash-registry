import DashKit
import Foundation
import Testing

/// The Overview's numbers and the Changes tab's diff lines.
struct PullRequestOverviewTests {
    @Test func diffLinesCarryTheirLineNumbers() {
        let lines = DiffLine.parse("@@ -10,3 +10,4 @@ func a() {\n keep\n-old\n+new\n+more\n\\ No newline at end of file")
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .note])
        #expect(lines[1].old == 10 && lines[1].new == 10)
        #expect(lines[2].old == 11 && lines[2].new == nil)
        #expect(lines[3].new == 11 && lines[4].new == 12 && lines[4].text == "more")
    }

    @Test func statsCountChecksAndMergeState() {
        let pull: JSONValue = ["changed_files": 4, "additions": 30, "deletions": 10, "commits": 3, "comments": 2, "review_comments": 1, "mergeable_state": "dirty"]
        let runs: [JSONValue] = [["status": "completed", "conclusion": "success"], ["status": "completed", "conclusion": "failure"],
                                 ["status": "in_progress"], ["status": "completed", "conclusion": "skipped"]]
        let stats = PRStats(pull: pull, checkRuns: runs)
        #expect(stats.files == 4 && stats.additions == 30 && stats.comments == 3)
        #expect(stats.checksPassed == 2 && stats.checksFailed == 1 && stats.checksPending == 1 && stats.checksTone == .danger)
        #expect(stats.mergeLabel.text == "Conflicts")
    }
}
