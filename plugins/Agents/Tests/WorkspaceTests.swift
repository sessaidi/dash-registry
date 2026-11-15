import Foundation
import Testing

@MainActor
struct AgentWorkspaceTests {
    @Test func parsesUnifiedDiffs() {
        let diffs = DiffParser.parse("""
            diff --git a/api/renew.go b/api/renew.go
            index 1..2 100644
            --- a/api/renew.go
            +++ b/api/renew.go
            @@ -10,4 +10,5 @@ func Renew() {
             a := 1
            -b := 2
            +b := 3
            +c := 4
             return
            diff --git a/old.go b/new.go
            similarity index 90%
            rename from old.go
            rename to new.go
            diff --git a/gone.go b/gone.go
            deleted file mode 100644
            --- a/gone.go
            +++ /dev/null
            @@ -1,1 +0,0 @@
            -x
            """)
        #expect(diffs.map(\.path) == ["api/renew.go", "new.go", "gone.go"])
        #expect(diffs.map(\.status) == [.modified, .renamed, .deleted])
        let renew = diffs[0]
        #expect(renew.additions == 2 && renew.deletions == 1)
        #expect(renew.changedLines == [11, 12] && renew.firstChange == 11)
        #expect(renew.hunks[0].lines.map(\.new) == [10, nil, 11, 12, 13])
        #expect(diffs[1].oldPath == "old.go")
    }

    @Test func buildsTheTreeFoldersFirst() {
        let tree = FileNode.tree(["README.md", "api/renew.go", "api/v1/x.go", "Makefile"])
        #expect(tree.map(\.name) == ["api", "Makefile", "README.md"])
        #expect(tree[0].children?.map(\.name) == ["v1", "renew.go"])
        #expect(tree[0].children?[0].children?.first?.path == "api/v1/x.go")
    }

    @Test func readsAWorktreesChangesAgainstItsBase() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws { _ = try WorktreeState.git(arguments, in: root) }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.email", "a@b.c"])
        try git(["config", "user.name", "A"])
        try "one\ntwo\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["-c", "commit.gpgsign=false", "commit", "-qm", "base"])
        try git(["checkout", "-qb", "feat"])
        try "one\nTWO\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["-c", "commit.gpgsign=false", "commit", "-qam", "change"])
        try "new\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let state = WorktreeState(root: root, base: "main")
        await state.reload()
        #expect(state.error == nil)
        #expect(state.files == ["a.txt", "b.txt"])
        #expect(state.diffs.map(\.path) == ["a.txt", "b.txt"])
        #expect(state.status(of: "b.txt") == .added && state.diff(for: "a.txt")?.changedLines == [2])
    }
}
