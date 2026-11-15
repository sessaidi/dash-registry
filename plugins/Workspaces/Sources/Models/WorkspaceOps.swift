import DashKit
import Foundation
import WorkspaceKit

/// A named set of services a workspace runs ("signup": capig, papi, services-signup, services-user).
struct WorkspaceProfile: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var services: [String]
    var id: String { name }

    static let defaults: [WorkspaceProfile] = [
        .init(name: "default", services: ["capig", "papi"]),
        .init(name: "signup", services: ["capig", "papi", "services-signup", "services-user"]),
        .init(name: "privacy", services: ["capig", "papi", "services-user-privacy"]),
        .init(name: "vapi", services: ["capig", "papi", "vapi"]),
    ]
}

/// Where a workspace's code lives: a worktree (often an agent's) and the service folder in it.
struct WorkspaceLink: Codable, Hashable, Sendable {
    var worktree: String
    /// The service folder to build (the worktree itself, or apps/<service> in a monorepo).
    var service: String
}

/// A worktree Dash knows about: from the Agents feature or added by hand.
struct KnownWorktree: Hashable, Identifiable, Sendable {
    var path: String
    var branch: String
    var issue: String
    var id: String { path }

    /// The workspace name up-toolbox would use: the ticket key, lowercased.
    var suggestedName: String {
        let key = issue.isEmpty ? (branch.split(separator: "/").last.map(String.init) ?? branch) : issue
        return key.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}

extension WorkspacesFeature {
    // MARK: Profiles and links

    var profiles: [WorkspaceProfile] {
        get {
            guard let data = defaultsStore.data(forKey: "workspaces.profiles"), let saved = try? JSONDecoder().decode([WorkspaceProfile].self, from: data) else {
                return WorkspaceProfile.defaults
            }
            return saved
        }
        set {
            defaultsStore.set(try? JSONEncoder().encode(newValue), forKey: "workspaces.profiles")
            revision += 1
        }
    }

    var links: [String: WorkspaceLink] {
        get {
            _ = revision
            guard let data = defaultsStore.data(forKey: "workspaces.links") else { return [:] }
            return (try? JSONDecoder().decode([String: WorkspaceLink].self, from: data)) ?? [:]
        }
        set {
            defaultsStore.set(try? JSONEncoder().encode(newValue), forKey: "workspaces.links")
            revision += 1
        }
    }

    func link(_ workspace: String, worktree: String, service: String? = nil) {
        let services = WorktreeBuild.services(in: URL(fileURLWithPath: worktree))
        links[workspace] = WorkspaceLink(worktree: worktree, service: service ?? services.first?.path ?? worktree)
    }

    /// Worktrees of the Agents feature's sessions (through its `agents_list` tool).
    func worktrees() async -> [KnownWorktree] {
        guard let tool = host?.extensions.first(where: { $0.id == "agents" })?.tools.first(where: { $0.name == "agents_list" }),
              let result = try? await tool.run([:]) else { return [] }
        return (result.array ?? []).compactMap { session in
            guard let path = session["worktree"]?.string, FileManager.default.fileExists(atPath: path) else { return nil }
            return KnownWorktree(path: path, branch: session["branch"]?.string ?? "", issue: session["issue"]?.string ?? "")
        }
    }

    /// The local configuration folder: in the linked worktree (like up-toolbox in its cwd), else
    /// in Dash's own folder.
    func folder(for name: String) -> WorkspaceFolder {
        let parent = links[name].map { URL(fileURLWithPath: $0.worktree) }
            ?? URL.applicationSupportDirectory.appending(path: "Dash/Workspaces", directoryHint: .isDirectory)
        return WorkspaceFolder(url: WorkspaceFolder.url(in: parent, name: name, env: env, region: region))
    }

    // MARK: Steps (what was done, and the commands that do it)

    func record(_ name: String, _ step: WorkspaceStep) {
        steps[name, default: []].insert(step, at: 0)
        if steps[name]!.count > 100 { steps[name]!.removeLast() }
    }

    /// Steps Dash ran plus every request made to the cluster for this workspace, newest first.
    func commands(for name: String) -> [WorkspaceStep] {
        let traces = (connectedClient?.kube.recorder.traces(namespace: name) ?? []).map { trace in
            WorkspaceStep(at: trace.at, title: "\(trace.method) \(trace.path.split(separator: "?").first ?? "")", command: trace.exact,
                          familiar: trace.familiar, output: "HTTP \(trace.status)", failed: !(200..<300).contains(trace.status))
        }
        return (steps[name, default: []] + traces).sorted { $0.at > $1.at }
    }

    private var credentials: ConnectionTokenSource {
        get throws {
            guard let connection = host?.integration("gcp")?.connection else { throw ToolError("Connect Google Cloud in Settings › Integrations.") }
            return ConnectionTokenSource(connection: connection)
        }
    }

    // MARK: Create (generate + up)

    /// Copies the services from the source cluster's `default` namespace, writes the
    /// configuration to the worktree (like `up-toolbox workspace generate`), then creates
    /// everything (like `up`).
    func create(name rawName: String, services: [String], worktree: String?, service: String? = nil, overwriteFiles: Bool = false) async throws {
        let name = rawName.lowercased()
        try WorkspaceGenerator.validate(name)
        if let worktree { link(name, worktree: worktree, service: service) }
        busy.insert(name)
        defer { busy.remove(name) }
        let full = WorkspaceGenerator.expand(services.joined(separator: ","))
        let shortList = services.joined(separator: ",")
        let source = try await WorkspaceClient.connectSource(env: env, region: region, credentials: try credentials)
        let read = try await source.readSource(services: full)
        let project = links[name].map { WorktreeBuild.appName(URL(fileURLWithPath: $0.service)) }
        let manifests = try WorkspaceGenerator.manifests(read, options: .init(
            name: name, env: env, region: region, username: username, services: full, currentProject: project))
        let folder = folder(for: name)
        try folder.write(manifests, force: overwriteFiles)
        record(name, WorkspaceStep(at: .now, title: "Generate", command: "# files written to \(folder.url.path)",
                                   familiar: "up-toolbox workspace generate --name \(name) --env \(env.rawValue) --region \(region.rawValue) --services \(shortList)",
                                   output: manifests.map { "\($0["kind"]?.string ?? "")/\($0["metadata"]?["name"]?.string ?? "")" }.joined(separator: "\n"), failed: false))
        let target = try await client()
        let car = startDeployment(name, kind: "create", summary: shortList)
        do {
            try await target.up(manifests, namespace: name)
            finish(car)
            record(name, WorkspaceStep(at: .now, title: "Create", command: "cd \(Shell.quote(folder.url.path)) && kubectl --context \(target.kube.contextName) create -f namespace.yaml && kubectl --context \(target.kube.contextName) create -k . -n \(name)",
                                       familiar: "up-toolbox workspace up --name \(name) --env \(env.rawValue) --region \(region.rawValue) --source \(Shell.quote(folder.url.path))",
                                       output: "https://\(WorkspaceGenerator.host(name: name, env: env, region: region))", failed: false))
        } catch {
            record(name, WorkspaceStep(at: .now, title: "Create", command: "kubectl create -k \(Shell.quote(folder.url.path))", familiar: nil, output: error.localizedDescription, failed: true))
            finish(car, error: error)
            throw error
        }
        host?.emit("workspace.created", from: self, title: "Workspace \(name) created", detail: shortList, importance: .notable)
        await refresh()
    }

    // MARK: Deploy the worktree (run)

    /// Builds the linked worktree's service and deploys it (like `up-toolbox workspace run`).
    @discardableResult
    func deployWorktree(_ name: String, runTests: Bool = true) async throws -> String {
        guard let link = links[name] else { throw ToolError("Link \(name) to a worktree first.") }
        guard let docker = host?.integration("docker")?.connection else { throw ToolError("Connect Docker in Settings › Integrations.") }
        busy.insert(name)
        defer { busy.remove(name) }
        let credentials = try credentials
        let build = WorktreeBuild(folder: URL(fileURLWithPath: link.service), workspace: name, env: env, region: region, runTests: runTests)
        let car = startDeployment(name, kind: "worktree")
        let image: String
        do {
            image = try await build.run(docker: docker, token: { try await credentials.accessToken() }, client: try await client()) { [weak self] step in
                Task { @MainActor in self?.record(name, step) }
            }
        } catch {
            finish(car, error: error)
            throw error
        }
        finish(car, image: image)
        host?.emit("workspace.deployed", from: self, title: "\(WorktreeBuild.appName(URL(fileURLWithPath: link.service))) deployed to \(name)", detail: image, importance: .notable)
        await refresh()
        return image
    }

    // MARK: Configuration

    /// What the local files would change in the cluster.
    func pendingChanges(_ name: String) async throws -> [WorkspaceChange] {
        let folder = folder(for: name)
        guard folder.exists else { throw ToolError("No local configuration for \(name) (expected \(folder.url.path)). Generate it first.") }
        return try await client().changes(try folder.read(), namespace: name)
    }

    /// Applies the local files, then restarts deployments whose ConfigMaps changed so they read them.
    @discardableResult
    func applyConfig(_ name: String) async throws -> [WorkspaceChange] {
        let client = try await client()
        let changes = try await pendingChanges(name).filter { $0.kind != .unchanged }
        guard !changes.isEmpty else { return [] }
        busy.insert(name)
        defer { busy.remove(name) }
        let car = startDeployment(name, kind: "config", summary: changes.map(\.id).joined(separator: ", "))
        do { try await client.apply(changes, namespace: name) } catch { finish(car, error: error); throw error }
        finish(car)
        let changedConfigMaps = changes.filter { $0.object["kind"]?.string == "ConfigMap" }.compactMap { $0.object["metadata"]?["name"]?.string }
        var restarted: [String] = []
        for configMap in changedConfigMaps {
            let data = (changes.first { $0.object["metadata"]?["name"]?.string == configMap }?.object["data"]?.object ?? [:]).compactMapValues(\.string)
            restarted += try await client.updateConfigMap(workspace: name, name: configMap, data: data)
        }
        let folder = folder(for: name)
        record(name, WorkspaceStep(at: .now, title: "Apply configuration", command: "kubectl --context \(client.kube.contextName) apply -k \(Shell.quote(folder.url.path)) -n \(name)",
                                   familiar: "kubectl --context \(client.kube.contextName) diff -k \(Shell.quote(folder.url.path)) -n \(name)",
                                   output: changes.map { "\($0.kind.rawValue) \($0.id)" + ($0.differences.isEmpty ? "" : ": " + $0.differences.prefix(5).joined(separator: ", ")) }.joined(separator: "\n")
                                    + (restarted.isEmpty ? "" : "\nrestarted: " + Set(restarted).sorted().joined(separator: ", ")),
                                   failed: false))
        host?.emit("workspace.configured", from: self, title: "Configuration applied to \(name)", detail: changes.map(\.id).joined(separator: ", "), importance: .notable)
        return changes
    }

    // MARK: Logs and diagnosis

    func logs(_ name: String, pod: String, container: String?, previous: Bool, tail: Int = 500, sinceSeconds: Int? = nil) async throws -> String {
        try await client().podLogs(name, pod: pod, container: container, tailLines: tail, sinceSeconds: sinceSeconds, previous: previous)
    }

    func diagnose(_ name: String) async throws -> WorkspaceDiagnosis {
        try await client().diagnose(name)
    }

    /// The GKE cluster workspaces run on (for Cloud Logging filters).
    var clusterName: String { env.cluster(region: region).name }

    /// Cloud Logging through the Google Cloud integration's `gcp_logs_query`.
    func cloudLogs(_ name: String, minSeverity: String? = nil, text: String? = nil, since: String = "6h", pod: String? = nil, limit: Int = 300) async throws -> JSONValue {
        guard let tool = host?.integration("gcp")?.tools.first(where: { $0.name == "gcp_logs_query" }) else {
            throw ToolError("Update the Google Cloud integration (it needs gcp_logs_query).")
        }
        var input: [String: JSONValue] = ["project": .string(env.project), "namespace": .string(name), "cluster": .string(clusterName),
                                          "since": .string(since), "limit": .number(Double(limit))]
        if let minSeverity { input["minSeverity"] = .string(minSeverity) }
        if let text, !text.isEmpty { input["text"] = .string(text) }
        if let pod { input["pod"] = .string(pod) }
        let result = try await tool.run(.object(input)) ?? .null
        record(name, WorkspaceStep(at: .now, title: "Cloud Logging", command: result["command"]?.string ?? "", familiar: result["gcloud"]?.string,
                                   output: "\(result["count"]?.int ?? 0) entries", failed: false))
        return result
    }

    // MARK: Cleaning up after merges

    /// Deletes the user's workspaces whose branch's PR was merged (unless persisted). Uses the
    /// GitHub integration's `github_api_get`.
    func cleanUpMerged() async {
        guard removeWhenMerged, let tool = host?.integration("github")?.tools.first(where: { $0.name == "github_api_get" }) else { return }
        for workspace in workspaces where workspace.deployedBy == username && !workspace.persist {
            guard let repo = workspace.repo, let branch = workspace.gitBranch, !branch.isEmpty, branch != "HEAD" else { continue }
            let owner = repo.split(separator: "/").first.map(String.init) ?? ""
            let path = "/repos/\(repo)/pulls?state=closed&head=\(owner):\(branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch)&per_page=5"
            guard let pulls = (try? await tool.run(["path": .string(path)]))?.array,
                  let merged = pulls.first(where: { $0["merged_at"]?.string != nil }) else { continue }
            do {
                try await delete(workspace.name, confirm: false)
                host?.emit("workspace.cleaned", from: self, title: "Workspace \(workspace.name) deleted: its PR was merged",
                           detail: merged["html_url"]?.string, importance: .notable)
            } catch {
                lastError = "Couldn't delete \(workspace.name) after its PR merged: \(error.localizedDescription)"
            }
        }
    }
}
