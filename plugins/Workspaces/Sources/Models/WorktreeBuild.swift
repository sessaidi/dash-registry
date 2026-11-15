import DashKit
import Foundation
import WorkspaceKit

/// A step Dash ran for a workspace, with the command that does the same thing and part of its output.
struct WorkspaceStep: Identifiable, Sendable, Equatable {
    let id = UUID()
    let at: Date
    let title: String
    /// The command that does exactly this.
    let command: String
    /// The everyday equivalent (up-toolbox, kubectl, gcloud), when different.
    let familiar: String?
    var output: String
    var failed: Bool
}

/// `up-toolbox workspace run`, natively: from a worktree's service folder, test and build the
/// Go binary, build the image through the Docker integration, push it to the workspace's
/// Artifact Registry, then point the workspace deployment at it and wait for the rollout.
struct WorktreeBuild: Sendable {
    let folder: URL
    let workspace: String
    let env: WorkspaceEnvironment
    let region: WorkspaceRegion
    var arch = "amd64"
    var runTests = true

    /// Artifact Registry repository per env/region (up-toolbox `localbuild.go`).
    static func registry(env: WorkspaceEnvironment, region: WorkspaceRegion) -> String {
        switch (env, region) {
        case (.dev, .us): "us-east4-docker.pkg.dev/fubotv-dev/backend-workspaces"
        case (.dev, .eu): "europe-west1-docker.pkg.dev/fubotv-dev/backend-workspaces-eu"
        case (.qa, .us): "us-east4-docker.pkg.dev/model-gearing-425/backend-workspaces"
        case (.qa, .eu): "europe-west1-docker.pkg.dev/model-gearing-425/backend-workspaces-eu"
        }
    }

    /// The app name: the last segment of go.mod's module path, else the folder name.
    static func appName(_ folder: URL) -> String {
        if let text = try? String(contentsOf: folder.appending(path: "go.mod"), encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("module ") }) {
            return String(line.dropFirst(7).trimmingCharacters(in: .whitespaces).split(separator: "/").last ?? "")
        }
        return folder.lastPathComponent
    }

    /// Service folders a worktree holds: itself if it has a Dockerfile, else `apps/*` with one.
    static func services(in worktree: URL) -> [URL] {
        if FileManager.default.fileExists(atPath: worktree.appending(path: "Dockerfile").path) { return [worktree] }
        let apps = worktree.appending(path: "apps")
        let children = (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
        return children.filter { FileManager.default.fileExists(atPath: $0.appending(path: "Dockerfile").path) }.sorted { $0.path < $1.path }
    }

    /// `<registry>/<app>:<branch with / as ->-<sha>`, lowercased (up-toolbox's tag).
    static func image(registry: String, app: String, branch: String, sha: String) -> String {
        "\(registry)/\(app)".lowercased() + ":" + "\(branch.replacingOccurrences(of: "/", with: "-"))-\(sha)".lowercased()
    }

    /// Runs every step, reporting each as it ends. Returns the deployed image.
    func run(docker: IntegrationConnection, token: @escaping @Sendable () async throws -> String, client: WorkspaceClient,
             report: @escaping @Sendable (WorkspaceStep) -> Void) async throws -> String {
        let app = Self.appName(folder)
        guard FileManager.default.fileExists(atPath: folder.appending(path: "Dockerfile").path) else {
            throw ToolError("No Dockerfile in \(folder.path). In a monorepo, pick the app folder (apps/<service>).")
        }
        let buildDir = folder.appending(path: "build")
        guard !FileManager.default.fileExists(atPath: buildDir.path) else {
            throw ToolError("\(folder.lastPathComponent)/build already exists; up-toolbox and Dash need it absent. Remove it and retry.")
        }
        defer { try? FileManager.default.removeItem(at: buildDir) }

        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"])
        let sha = try git(["rev-parse", "HEAD"])
        let image = Self.image(registry: Self.registry(env: env, region: region), app: app, branch: branch, sha: sha)
        let cd = "cd \(Shell.quote(folder.path))"

        if runTests {
            try step("Test", command: "\(cd) && go test -v -count=1 ./...", report: report) {
                try Shell.run("/usr/bin/env", ["go", "test", "-v", "-count=1", "./..."], in: folder)
            }
        }
        try step("Build the binary", command: "\(cd) && CGO_ENABLED=0 GOOS=linux GOARCH=\(arch) go build -a -o build/app ./app", report: report) {
            try Shell.run("/usr/bin/env", ["go", "build", "-a", "-o", "build/app", "./app"], in: folder,
                          environment: ["CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": arch])
        }

        // docker build, through the Docker integration's socket.
        let context = try Tar.archive(folder, ignoring: Tar.dockerignore(in: folder))
        var build = URLRequest(url: docker.baseURL.appending(path: "build"))
        build.url = URL(string: docker.baseURL.absoluteString + "/build?" + [
            "t=\(image.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? image)", "platform=linux/\(arch)", "dockerfile=Dockerfile", "rm=1",
        ].joined(separator: "&"))
        build.httpMethod = "POST"
        build.setValue("application/x-tar", forHTTPHeaderField: "Content-Type")
        build.httpBody = context
        build.timeoutInterval = 1800
        try await asyncStep("Build the image", command: "\(cd) && DOCKER_BUILDKIT=1 docker build --platform linux/\(arch) -t \(image) .", report: report) {
            let (data, _) = try await docker.send(build, service: "Docker")
            return try Self.dockerStream(data)
        }

        // docker push with an OAuth token for Artifact Registry (what `docker login -u oauth2accesstoken` sets up).
        let host = String(image.prefix { $0 != "/" })
        let auth = try JSONSerialization.data(withJSONObject: ["username": "oauth2accesstoken", "password": try await token(), "serveraddress": host])
        let name = String(image[..<image.lastIndex(of: ":")!])
        let tag = String(image[image.index(after: image.lastIndex(of: ":")!)...])
        var push = URLRequest(url: URL(string: docker.baseURL.absoluteString + "/images/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/push?tag=\(tag)")!)
        push.httpMethod = "POST"
        push.setValue(auth.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"), forHTTPHeaderField: "X-Registry-Auth")
        push.timeoutInterval = 1800
        try await asyncStep("Push", command: "gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin \(host) && docker push \(image)", report: report) {
            let (data, _) = try await docker.send(push, service: "Docker")
            return try Self.dockerStream(data)
        }

        // Patch and wait, recording git details on the namespace like up-toolbox.
        var details = ["git_branch": branch, "git_dirty": ((try? git(["status", "--porcelain"])) ?? "").isEmpty ? "false" : "true"]
        if let short = try? git(["rev-parse", "--short", "HEAD"]) { details["git_hash"] = short }
        if let tagName = try? git(["tag", "--points-at", "HEAD"]).split(separator: "\n").first, !tagName.isEmpty { details["git_tag"] = String(tagName) }
        if let remote = try? git(["config", "--get", "remote.origin.url"]), let slug = Self.slug(remote) { details["dash_repo"] = slug }
        try await asyncStep("Deploy", command: "kubectl --context \(client.kube.contextName) -n \(workspace) set image deployment/\(app) \(app)=\(image) && kubectl --context \(client.kube.contextName) -n \(workspace) rollout status deployment/\(app)",
                            familiar: "\(cd) && up-toolbox workspace run --name \(workspace) --env \(env.rawValue) --region \(region.rawValue)\(runTests ? "" : " --no-test")",
                            report: report) {
            try await client.deploy(workspace: workspace, app: app, image: image, git: details)
            return "\(app) runs \(tag)"
        }
        return image
    }

    // MARK: Helpers

    private func git(_ arguments: [String]) throws -> String {
        try Shell.run("/usr/bin/git", arguments, in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func step(_ title: String, command: String, familiar: String? = nil, report: @Sendable (WorkspaceStep) -> Void, _ body: () throws -> String) throws {
        do {
            let output = try body()
            report(WorkspaceStep(at: .now, title: title, command: command, familiar: familiar, output: String(output.suffix(20_000)), failed: false))
        } catch {
            report(WorkspaceStep(at: .now, title: title, command: command, familiar: familiar, output: error.localizedDescription, failed: true))
            throw error
        }
    }

    private func asyncStep(_ title: String, command: String, familiar: String? = nil, report: @Sendable (WorkspaceStep) -> Void,
                           _ body: () async throws -> String) async throws {
        do {
            let output = try await body()
            report(WorkspaceStep(at: .now, title: title, command: command, familiar: familiar, output: String(output.suffix(20_000)), failed: false))
        } catch {
            report(WorkspaceStep(at: .now, title: title, command: command, familiar: familiar, output: error.localizedDescription, failed: true))
            throw error
        }
    }

    /// Docker's JSON-lines progress as text; an `error` line fails the step.
    static func dockerStream(_ data: Data) throws -> String {
        var lines: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let json = try? JSONValue.parse(String(line)) else { lines.append(String(line)); continue }
            if let error = json["error"]?.string ?? json["errorDetail"]?["message"]?.string { throw ToolError("Docker: \(error)") }
            if let text = json["stream"]?.string { lines.append(text.trimmingCharacters(in: .newlines)) }
            else if let status = json["status"]?.string { lines.append(status + (json["id"]?.string.map { " \($0)" } ?? "")) }
        }
        return lines.joined(separator: "\n")
    }

    /// "owner/name" from an origin URL.
    static func slug(_ remote: String) -> String? {
        var path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = path.range(of: "://") { path = String(path[range.upperBound...]).split(separator: "/", maxSplits: 1).dropFirst().joined() }
        else if let colon = path.firstIndex(of: ":") { path = String(path[path.index(after: colon)...]) }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.isEmpty ? nil : path
    }
}

/// Runs local tools (git, go) and waits.
enum Shell {
    static func run(_ executable: String, _ arguments: [String], in folder: URL, environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // Your shell's environment (PATH with go, GOPATH, GOPRIVATE…), plus the usual places.
        var env = ShellEnvironment.current
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin:\(NSHomeDirectory())/go/bin"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ToolError("\(([executable] + arguments).joined(separator: " ")) failed (\(process.terminationStatus)):\n\(output.suffix(4000))")
        }
        return output
    }

    static func quote(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? text : "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// A tar archive of a build context (ustar, GNU long names), honouring .dockerignore.
enum Tar {
    static func dockerignore(in folder: URL) -> [String] {
        ((try? String(contentsOf: folder.appending(path: ".dockerignore"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whether `path` (relative) matches a .dockerignore pattern list (last match wins; `!` re-includes).
    static func ignored(_ path: String, patterns: [String]) -> Bool {
        var result = false
        for raw in patterns {
            let negate = raw.hasPrefix("!")
            var pattern = negate ? String(raw.dropFirst()) : raw
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.hasSuffix("/") { pattern.removeLast() }
            if matches(path, pattern) || path.hasPrefix(pattern + "/") && !pattern.contains("*") { result = !negate }
        }
        return result
    }

    static func matches(_ path: String, _ pattern: String) -> Bool {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if character == "*" {
                let next = pattern.index(after: index)
                if next < pattern.endIndex && pattern[next] == "*" { regex += ".*"; index = pattern.index(after: next); continue }
                regex += "[^/]*"
            } else if character == "?" { regex += "[^/]" }
            else { regex += NSRegularExpression.escapedPattern(for: String(character)) }
            index = pattern.index(after: index)
        }
        return path.range(of: regex + "(/.*)?$", options: .regularExpression) != nil
    }

    static func archive(_ root: URL, ignoring patterns: [String]) throws -> Data {
        var data = Data()
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isExecutableKey]) else { return data }
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if relative == ".git" || relative.hasPrefix(".git/") || ignored(relative, patterns: patterns) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isExecutableKey])
            if values.isDirectory == true {
                append(name: relative + "/", contents: Data(), mode: 0o755, type: "5", into: &data)
            } else if values.isRegularFile == true {
                append(name: relative, contents: try Data(contentsOf: url), mode: values.isExecutable == true ? 0o755 : 0o644, type: "0", into: &data)
            }
        }
        data.append(Data(count: 1024))
        return data
    }

    private static func append(name: String, contents: Data, mode: Int, type: Character, into data: inout Data) {
        let nameBytes = Array(name.utf8)
        if nameBytes.count > 100 {
            // GNU long name: a pseudo-entry carrying the full path.
            data.append(header(name: "././@LongLink", size: nameBytes.count + 1, mode: 0o644, type: "L"))
            var long = Data(nameBytes + [0])
            long.append(Data(count: (512 - long.count % 512) % 512))
            data.append(long)
        }
        data.append(header(name: String(decoding: nameBytes.prefix(100), as: UTF8.self), size: contents.count, mode: mode, type: type))
        data.append(contents)
        data.append(Data(count: (512 - contents.count % 512) % 512))
    }

    private static func header(name: String, size: Int, mode: Int, type: Character) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { block[offset + index] = byte }
        }
        put(name, at: 0, length: 100)
        put(String(format: "%07o", mode), at: 100, length: 8)
        put("0000000", at: 108, length: 8)
        put("0000000", at: 116, length: 8)
        put(String(format: "%011o", size), at: 124, length: 12)
        put(String(format: "%011o", Int(Date().timeIntervalSince1970)), at: 136, length: 12)
        put("        ", at: 148, length: 8)
        put(String(type), at: 156, length: 1)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", checksum) + "\0 ", at: 148, length: 8)
        return Data(block)
    }
}
