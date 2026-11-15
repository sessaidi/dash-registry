import DashKit
import Foundation
import Testing

/// The Changes tab's diff lines.
struct PullRequestOverviewTests {
    @Test func diffLinesCarryTheirLineNumbers() {
        let lines = DiffLine.parse("@@ -10,3 +10,4 @@ func a() {\n keep\n-old\n+new\n+more\n\\ No newline at end of file")
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .note])
        #expect(lines[1].old == 10 && lines[1].new == 10)
        #expect(lines[2].old == 11 && lines[2].new == nil)
        #expect(lines[3].new == 11 && lines[4].new == 12 && lines[4].text == "more")
    }

}
