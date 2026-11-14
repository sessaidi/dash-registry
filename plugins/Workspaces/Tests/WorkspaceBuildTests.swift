import DashKit
import Foundation
import SwiftData
import Testing
import WorkspaceKit

@MainActor
struct WorkspaceBuildTests {
    @Test func namesImagesLikeUpToolbox() {
        #expect(WorktreeBuild.registry(env: .dev, region: .eu) == "europe-west1-docker.pkg.dev/fubotv-dev/backend-workspaces-eu")
        #expect(WorktreeBuild.image(registry: "us-east4-docker.pkg.dev/fubotv-dev/backend-workspaces", app: "Services-User", branch: "feat/LAF-12", sha: "ABC")
                == "us-east4-docker.pkg.dev/fubotv-dev/backend-workspaces/services-user:feat-laf-12-abc")
        #expect(WorktreeBuild.slug("git@github.com:fubotv/services-user.git") == "fubotv/services-user")
        #expect(WorktreeBuild.slug("https://github.com/fubotv/services-user") == "fubotv/services-user")
    }

    @Test func findsServicesAndAppNames() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "apps/services-user")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "FROM scratch\n".write(to: app.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        try "module github.com/fubotv/monorepo/apps/user-svc\n\ngo 1.22\n".write(to: app.appending(path: "go.mod"), atomically: true, encoding: .utf8)
        #expect(WorktreeBuild.services(in: root).map(\.lastPathComponent) == ["services-user"])
        #expect(WorktreeBuild.appName(app) == "user-svc")
    }

    @Test func tarsTheContextHonouringDockerignore() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ctx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appending(path: String(repeating: "long-directory-name/", count: 6))
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "node_modules/x"), withIntermediateDirectories: true)
        try "FROM scratch\nCOPY build/app /app\n".write(to: root.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        try "bin".write(to: root.appending(path: "build/app"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appending(path: "node_modules/x/i.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)
        try "deep".write(to: deep.appending(path: "file.txt"), atomically: true, encoding: .utf8)
        try "node_modules\n*.env\n.env\n".write(to: root.appending(path: ".dockerignore"), atomically: true, encoding: .utf8)
        let data = try Tar.archive(root, ignoring: Tar.dockerignore(in: root))
        let file = root.deletingLastPathComponent().appending(path: "ctx-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let listing = try Shell.run("/usr/bin/tar", ["-tf", file.path], in: root.deletingLastPathComponent())
        let entries = Set(listing.split(separator: "\n").map(String.init))
        #expect(entries.contains("Dockerfile") && entries.contains("build/app"))
        #expect(entries.contains(String(repeating: "long-directory-name/", count: 6) + "file.txt"))
        #expect(!entries.contains { $0.hasPrefix("node_modules") } && !entries.contains(".env"))
    }

    @Test func recordsTheTrainAndWorkspaceMetadata() throws {
        let (feature, host) = makeFeature(FakeCluster([]))
        let car = feature.startDeployment("laf-12", kind: "image", app: "api", image: "r/api:feat-x-abc")
        feature.finish(car)
        let failed = feature.startDeployment("laf-12", kind: "config")
        feature.finish(failed, error: ToolError("boom"))
        let train = feature.train(workspace: "laf-12")
        #expect(train.map(\.kind) == ["config", "image"] && train.map(\.status) == ["failed", "succeeded"])
        #expect(train[1].tag == "feat-x-abc" && train[0].error == "boom")
        #expect(try host.context.fetch(FetchDescriptor<WorkspaceDeployment>()).count == 2)
    }
}
