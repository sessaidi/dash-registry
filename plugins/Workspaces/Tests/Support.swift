import DashKit
import Foundation
import SwiftData
import WorkspaceKit

/// Serves canned responses per host, so parallel tests (each with its own host) don't collide.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    static func serve(_ host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            log[host] = []
        }
    }

    static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log[host, default: []].append(request)
            return Self.handlers[host]
        }
        let (status, body) = handler?(request) ?? (599, Data("no stub for \(host)".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// URLProtocol sees bodies as streams.
func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

/// Answers the permission modal with a fixed choice and records what was asked.
@MainActor
final class FakePermissions: PermissionAsking {
    var allow: Bool
    private(set) var asked: [String] = []

    init(allow: Bool) {
        self.allow = allow
    }

    func ask(_ prompt: PermissionPrompt) async -> Bool {
        asked.append(prompt.title)
        return allow
    }
}

@MainActor
final class FakeDashii: DashiiService {
    var model: String { "test" }
    func complete(_ request: DashiiRequest) async throws -> String { "" }
}

/// Stands in for the `gcp` integration: signs with a fixed token.
@MainActor
final class FakeGCP: Integration {
    static let token = "ya29.fake-google-token"

    let id = "gcp"
    let name = "Google Cloud"
    let systemImage = "cloud"
    var isConnected: Bool
    /// nil: the connection signs without a Bearer header.
    var token: String?

    init(isConnected: Bool = true, token: String? = FakeGCP.token) {
        self.isConnected = isConnected
        self.token = token
    }

    var connection: IntegrationConnection? {
        guard isConnected else { return nil }
        let token = token
        return IntegrationConnection(baseURL: URL(string: "https://www.googleapis.com")!, hosts: [".googleapis.com"]) { request in
            var request = request
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
    }
}

@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let fakePermissions: FakePermissions
    var permissions: any PermissionAsking { fakePermissions }
    let dashii: any DashiiService = FakeDashii()
    let activity = ActivityLog()
    private(set) var prompts: [String] = []
    static var retained: [FakeHost] = []

    init(_ extensions: [any DashExtension], allow: Bool = true) {
        let container = try! ModelContainer(for: Schema(extensions.flatMap(\.models)), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
        fakePermissions = FakePermissions(allow: allow)
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) { prompts.append(prompt) }
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// A Kubernetes API server for one workspace cluster, kept in memory: namespaces, the gateway
/// pods that give node pools, deployments, routes; PATCH and DELETE change it.
final class FakeCluster: @unchecked Sendable {
    struct Namespace {
        var name: String
        var deployedBy: String
        var created: Date
        var deployed: Date?
        var persist = false
        var branch: String?
        var node = "gke-api-cluster-east4-workspaces-spot-1234"
        var region = ""
    }

    struct Patch {
        let path: String
        let contentType: String
        let body: JSONValue
    }

    let host = "k8s-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var namespaces: [String: Namespace]
    private var images: [String: String] = [:]
    private var recordedPatches: [Patch] = []
    private var recordedDeletes: [String] = []
    /// Connections made through `connector`.
    private var connections = 0

    init(_ namespaces: [Namespace]) {
        self.namespaces = Dictionary(uniqueKeysWithValues: namespaces.map { ($0.name, $0) })
        StubProtocol.serve(host) { [self] request in handle(request) }
    }

    var patches: [Patch] { lock.withLock { recordedPatches } }
    var deletes: [String] { lock.withLock { recordedDeletes } }
    var connectCount: Int { lock.withLock { connections } }
    var requests: [URLRequest] { StubProtocol.requests(host) }

    /// Stands in for `WorkspaceClient.connect` (GKE discovery): a client on this fake server.
    var connector: WorkspacesFeature.Connector {
        { [self] env, region, credentials in
            lock.withLock { connections += 1 }
            let kube = KubernetesClient(server: URL(string: "https://\(host)")!, credentials: credentials, session: URLSession(configuration: StubProtocol.configuration()))
            return WorkspaceClient(env: env, region: region, kube: kube)
        }
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func reply(_ json: JSONValue, status: Int = 200) -> (status: Int, body: Data) {
        (status, (try? json.data()) ?? Data())
    }

    private func json(_ namespace: Namespace) -> JSONValue {
        var annotations: [String: JSONValue] = ["persist": .string(namespace.persist ? "true" : "false")]
        if let deployed = namespace.deployed { annotations["deployed_at"] = .string(Self.iso(deployed)) }
        if let branch = namespace.branch { annotations["git_branch"] = .string(branch) }
        return ["metadata": [
            "name": .string(namespace.name), "creationTimestamp": .string(Self.iso(namespace.created)),
            "labels": ["workspace": "true", "deployed_by": .string(namespace.deployedBy), "region": .string(namespace.region)],
            "annotations": .object(annotations),
        ]]
    }

    private func image(_ namespace: String, _ app: String) -> String {
        images["\(namespace)/\(app)"] ?? "us-docker.pkg.dev/fubotv-dev/apps/\(app):v1"
    }

    private func handle(_ request: URLRequest) -> (status: Int, body: Data) {
        lock.withLock {
            let url = request.url!
            let parts = url.path().split(separator: "/").map(String.init)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let selector = query.first { $0.name == "labelSelector" }?.value
            let notFound = Self.reply(["message": "not found"], status: 404)
            switch (request.httpMethod ?? "GET", parts.count, parts) {
            case ("GET", 3, ["api", "v1", "namespaces"]):
                return Self.reply(["items": .array(namespaces.values.map(json))])
            case ("GET", 3, ["api", "v1", "pods"]):
                return Self.reply(["items": .array(namespaces.values.map { ["metadata": ["namespace": .string($0.name)], "spec": ["nodeName": .string($0.node)]] })])
            case ("GET", 4, _) where parts.starts(with: ["api", "v1", "namespaces"]):
                return namespaces[parts[3]].map { Self.reply(json($0)) } ?? notFound
            case ("PATCH", 4, _) where parts.starts(with: ["api", "v1", "namespaces"]):
                guard namespaces[parts[3]] != nil else { return notFound }
                let body = (try? JSONValue.parse(bodyData(request))) ?? .null
                recordedPatches.append(Patch(path: url.path(), contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "", body: body))
                if let persist = body["metadata"]?["annotations"]?["persist"]?.string { namespaces[parts[3]]?.persist = persist == "true" }
                if body["metadata"]?["annotations"]?["deployed_at"] != nil { namespaces[parts[3]]?.deployed = Date() }
                return Self.reply(json(namespaces[parts[3]]!))
            case ("DELETE", 4, _) where parts.starts(with: ["api", "v1", "namespaces"]):
                recordedDeletes.append(parts[3])
                return namespaces.removeValue(forKey: parts[3]) == nil ? notFound : Self.reply(["status": "Success"])
            case ("GET", 5, _) where parts.starts(with: ["api", "v1", "namespaces"]) && parts[4] == "pods":
                if let app = selector?.split(separator: "=").last.map(String.init) {
                    return Self.reply(["items": [[
                        "metadata": ["name": .string("\(app)-abc"), "labels": ["name": .string(app)]],
                        "spec": ["containers": [["name": .string(app), "image": .string(image(parts[3], app))]]],
                        "status": ["phase": "Running", "containerStatuses": [["ready": true, "restartCount": 0]]],
                    ]]])
                }
                return Self.reply(["items": [
                    ["metadata": ["name": "common-api-gateway-abc", "labels": ["name": "common-api-gateway"]],
                     "spec": ["nodeName": "gke-workspaces-spot-1"],
                     "status": ["phase": "Running", "containerStatuses": [["ready": true, "restartCount": 0, "state": ["running": [:]]]]]],
                    ["metadata": ["name": "papi-xyz", "labels": ["name": "papi"]],
                     "spec": ["nodeName": "gke-workspaces-spot-1"],
                     "status": ["phase": "Running", "containerStatuses": [["ready": false, "restartCount": 7, "state": ["waiting": ["reason": "CrashLoopBackOff"]]]]]],
                ]])
            case ("GET", 6, _) where parts.starts(with: ["apis", "apps", "v1", "namespaces"]) && parts[5] == "deployments":
                return Self.reply(["items": [
                    ["metadata": ["name": "common-api-gateway"], "spec": ["replicas": 2, "template": ["spec": ["containers": [["image": .string(image(parts[4], "common-api-gateway"))]]]]],
                     "status": ["readyReplicas": 1]],
                ]])
            case ("PATCH", 7, _) where parts.starts(with: ["apis", "apps", "v1", "namespaces"]):
                let body = (try? JSONValue.parse(bodyData(request))) ?? .null
                recordedPatches.append(Patch(path: url.path(), contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "", body: body))
                if let image = body["spec"]?["template"]?["spec"]?["containers"]?[0]?["image"]?.string { images["\(parts[4])/\(parts[6])"] = image }
                return Self.reply([:])
            case ("GET", 6, _) where parts.starts(with: ["apis", "gateway.networking.k8s.io", "v1", "namespaces"]):
                return Self.reply(["items": [["spec": ["hostnames": .array([.string("\(parts[4]).backend-workspace.dev-01.fubo.tv")])]]]])
            default:
                return notFound
            }
        }
    }
}

/// A feature on its own UserDefaults suite, wired to `cluster`, attached to a host with `gcp`.
@MainActor
func makeFeature(_ cluster: FakeCluster, gcp: FakeGCP = FakeGCP(), allow: Bool = true, username: String = "sadik") -> (WorkspacesFeature, FakeHost) {
    let defaults = UserDefaults(suiteName: "workspaces-tests-\(UUID().uuidString)")!
    defaults.set(username, forKey: "workspaces.username")
    let feature = WorkspacesFeature(defaults: defaults, connect: cluster.connector)
    let host = FakeHost([gcp, feature], allow: allow)
    // The feature holds its host weakly, as Dash owns it; tests that drop the host keep it here.
    FakeHost.retained.append(host)
    // `start` keeps the host; stopping before the poller first runs keeps tests deterministic.
    feature.start(host: host)
    feature.stop()
    return (feature, host)
}

extension WorkspacesFeature {
    func tool(_ name: String) throws -> DashiiTool {
        guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return tool
    }
}

extension Date {
    static func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }
}
