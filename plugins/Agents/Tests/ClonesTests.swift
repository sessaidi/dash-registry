import Foundation
import Testing

@MainActor
struct ClonesTests {
    @Test func worktreesLiveInTheClone() {
        let url = AgentsExtension.worktreeURL(repo: URL(filePath: "/Users/me/Codes/api"), branch: "feat/kan-12-renew")
        #expect(url.path == "/Users/me/Codes/api/.worktrees/feat-kan-12-renew")
    }

    @Test func clonesMissingRepositoriesFromALocalRemote() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codes-\(UUID().uuidString)")
        let origin = root.appending(path: "origin/api.git")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        _ = try await Git.git(["init", "-q", "--bare"], in: origin)
        let codes = root.appending(path: "Codes")
        let clone = try await AgentsExtension.ensureClone("file://\(origin.path)", codeRoot: codes.path)
        #expect(clone.path == codes.appending(path: "api").path)
        #expect(try String(contentsOf: clone.appending(path: ".git/info/exclude"), encoding: .utf8).contains(".worktrees/"))
        // Already there: reused, exclude written once.
        _ = try await AgentsExtension.ensureClone("file://\(origin.path)", codeRoot: codes.path)
        #expect(try String(contentsOf: clone.appending(path: ".git/info/exclude"), encoding: .utf8).components(separatedBy: ".worktrees/").count == 2)
    }
}
