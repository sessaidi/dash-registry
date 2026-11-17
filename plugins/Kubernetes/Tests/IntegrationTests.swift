import DashKit
import Foundation
import Testing

@MainActor
@Suite("Kubernetes integration")
struct IntegrationTests {
    @Test func bearerTokenConnectionAndExports() async throws {
        let k8s = try makeIntegration(singleContext(host: "bearer.test", user: ["token: abc123"], namespace: "team-a"))
        StubProtocol.serve("bearer.test", json: #"{"gitVersion":"v1.31.2"}"#)
        #expect(k8s.isConnected)
        let connection = try #require(k8s.connection)
        #expect(connection.baseURL.absoluteString == "https://bearer.test")
        #expect(connection.headers["Authorization"] == "Bearer abc123")
        #expect(connection.session != nil)
        #expect(k8s.exports == [
            "contexts": ["ctx"], "currentContext": "ctx", "namespace": "team-a", "server": "https://bearer.test",
        ])
        await k8s.verify()
        #expect(k8s.serverVersion == "v1.31.2")
        #expect(k8s.connectionState == .connected("ctx · Kubernetes v1.31.2"))
        let request = try #require(StubProtocol.requests("bearer.test").last)
        #expect(request.url?.path == "/version")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func rejectedCredentialsDisconnect() async throws {
        let k8s = try makeIntegration(singleContext(host: "reject.test", user: ["token: bad"]))
        StubProtocol.serve("reject.test", json: #"{"kind":"Status","message":"Unauthorized"}"#, status: 401)
        await k8s.verify()
        #expect(!k8s.isConnected)
        guard case .failed(let message) = k8s.connectionState else { Issue.record("expected failure"); return }
        #expect(message.contains("401"))
    }

    @Test func tokenFileIsReadPerRequest() async throws {
        let k8s = try makeIntegration(singleContext(host: "file.test", user: ["tokenFile: token"]), extraFiles: ["token": "first\n"])
        StubProtocol.serve("file.test", json: "{}")
        let connection = try #require(k8s.connection)
        _ = try await connection.get("/version", service: "Kubernetes")
        try "second".write(to: k8s.configURL.deletingLastPathComponent().appending(path: "token"), atomically: true, encoding: .utf8)
        _ = try await connection.get("/version", service: "Kubernetes")
        #expect(StubProtocol.requests("file.test").map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer first", "Bearer second"])
    }

    @Test func basicAuth() throws {
        let k8s = try makeIntegration(singleContext(host: "basic.test", user: ["username: admin", "password: secret"]))
        #expect(k8s.connection?.headers["Authorization"] == "Basic " + Data("admin:secret".utf8).base64EncodedString())
    }

    @Test func gkeUsesGoogleCloudToken() async throws {
        let yaml = Kubeconfigs.gke.replacingOccurrences(of: "https://34.123.45.67", with: "https://gke.test")
        let k8s = try makeIntegration(yaml)
        // Without the gcp integration the context can't be used.
        #expect(!k8s.isConnected)
        #expect(k8s.connection == nil)
        guard case .failed(let message) = k8s.connectionState else { Issue.record("expected failure"); return }
        #expect(message.contains("Google Cloud"))

        let host = FakeHost([k8s, FakeGCP()])
        k8s.start(host: host)
        #expect(k8s.isConnected)
        StubProtocol.serve("gke.test", json: #"{"gitVersion":"v1.30.5-gke.1"}"#)
        await k8s.verify()
        #expect(k8s.serverVersion == "v1.30.5-gke.1")
        let request = try #require(StubProtocol.requests("gke.test").last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.fake-google-token")
    }

    @Test func unsupportedExecIsReported() throws {
        let k8s = try makeIntegration(Kubeconfigs.eks)
        #expect(!k8s.isConnected)
        #expect(k8s.connection == nil)
        guard case .failed(let message) = k8s.connectionState else { Issue.record("expected failure"); return }
        #expect(message.contains("aws"))
        #expect(k8s.tools.map(\.name) == ["k8s_contexts", "k8s_list_pods", "k8s_namespaces", "k8s_list", "k8s_describe", "k8s_logs",
                                            "k8s_events", "k8s_top_pods", "k8s_rollout_status", "k8s_api_read", "k8s_rollout_restart", "k8s_scale"])
        #expect(k8s.tools.filter(\.requiresApproval).map(\.name) == ["k8s_rollout_restart", "k8s_scale"])
    }

    @Test func kindsResolveLikeKubectl() throws {
        #expect(try KubernetesIntegration.resolveKind("deploy").path == "/apis/apps/v1")
        #expect(try KubernetesIntegration.resolveKind("HPA").name == "horizontalpodautoscalers")
        #expect(try KubernetesIntegration.resolveKind("service").name == "services")
        #expect(try KubernetesIntegration.resolveKind("nodes").namespaced == false)
        #expect(throws: (any Error).self) { try KubernetesIntegration.resolveKind("widgets") }
    }

    @Test func summariesKeepWhatMatters() throws {
        let deployment: JSONValue = ["metadata": ["name": "web", "namespace": "a"], "spec": ["replicas": 3, "template": ["spec": ["containers": [["image": "web:1"]]]]],
                                     "status": ["readyReplicas": 2]]
        let row = KubernetesIntegration.summary(deployment, kind: "deployments")
        #expect(row["ready"] == "2/3")
        #expect(row["images"] == ["web:1"])
        let secret: JSONValue = ["metadata": ["name": "s"], "data": ["password": "c2VjcmV0"]]
        #expect(KubernetesIntegration.summary(secret, kind: "secrets")["keys"] == ["password"])
        #expect(!KubernetesIntegration.summary(secret, kind: "secrets").jsonString().contains("c2VjcmV0"))
    }

    @Test func insecureContextStillConnects() throws {
        let k8s = try makeIntegration(singleContext(host: "insecure.test", user: ["token: t"], cluster: ["insecure-skip-tls-verify: true"]))
        #expect(k8s.resolved?.insecure == true)
        #expect(k8s.isConnected)
    }

    @Test func contextAndNamespaceSettings() throws {
        let url = try writeKubeconfig(Kubeconfigs.tokens, extraFiles: ["certs/staging-ca.crt": Fixtures.caCrt, "tokens/staging": "t"])
        let defaults = UserDefaults(suiteName: "kube-tests-\(UUID().uuidString)")!
        let k8s = KubernetesIntegration(configURL: url, defaults: defaults, sessionConfiguration: StubProtocol.configuration())
        #expect(k8s.activeContext == "dev")
        #expect(k8s.namespace == "team-a")
        k8s.selectedContext = "staging"
        #expect(defaults.string(forKey: "kubernetes.context") == "staging")
        #expect(k8s.exports["server"] == "https://staging.example.com:6443")
        #expect(k8s.namespace == "default")
        k8s.namespaceSetting = "payments"
        #expect(k8s.exports["namespace"] == "payments")
        #expect(defaults.string(forKey: "kubernetes.namespace") == "payments")
        // Settings survive a relaunch.
        let again = KubernetesIntegration(configURL: url, defaults: defaults, sessionConfiguration: StubProtocol.configuration())
        #expect(again.activeContext == "staging")
        #expect(again.namespace == "payments")
    }

    @Test func missingKubeconfig() {
        let k8s = KubernetesIntegration(configURL: URL(filePath: "/nonexistent/kube/config"), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(!k8s.isConnected)
        #expect(k8s.exports["contexts"] == [])
        guard case .failed(let message) = k8s.connectionState else { Issue.record("expected failure"); return }
        #expect(message.contains("/nonexistent/kube/config"))
    }

    // MARK: Reads

    @Test func getReturnsJSONAndTruncates() async throws {
        let k8s = try makeIntegration(singleContext(host: "get.test", user: ["token: t"]))
        StubProtocol.serve("get.test") { request in
            if request.url?.path == "/api/v1/namespaces" { return (200, Data(#"{"items":[{"metadata":{"name":"default"}}]}"#.utf8)) }
            return (200, Data(String(repeating: "x", count: 150_000).utf8))
        }
        let connection = try #require(k8s.connection)
        let json = try await KubernetesIntegration.get("/api/v1/namespaces", connection: connection)
        #expect(json["items"]?[0]?["metadata"]?["name"] == "default")
        let big = try await KubernetesIntegration.get("/api/v1/namespaces/default/pods/web/log?tailLines=10", connection: connection)
        let text = try #require(big.string)
        #expect(text.hasSuffix("[truncated]"))
        #expect(text.count == 100_000 + "\n[truncated]".count)
        let log = StubProtocol.requests("get.test")
        #expect(log.allSatisfy { $0.httpMethod == "GET" })
        #expect(log.last?.url?.query == "tailLines=10")
    }

    @Test(arguments: [
        "api/v1/pods", "https://evil.test/api", "//evil.test/api", "/api/v1/../../etc", "/api/v1/namespaces/default/pods/web/exec?command=sh",
        "/api/v1/namespaces/default/pods/web/attach", "/api/v1/namespaces/default/services/web/proxy/", "/api/v1/pods?watch=true",
        "/api/v1/pods?watch", "/api/v1/namespaces/a/pods/b/log?follow=1",
    ])
    func getRefusesNonReads(path: String) {
        #expect(throws: ToolError.self) { try KubernetesIntegration.checkReadOnly(path) }
    }

    @Test func getAllowsPlainReads() throws {
        try KubernetesIntegration.checkReadOnly("/api/v1/pods?watch=false&limit=10")
        try KubernetesIntegration.checkReadOnly("/apis/apps/v1/deployments")
        try KubernetesIntegration.checkReadOnly("/api/v1/namespaces/default/pods/web/log?tailLines=100")
    }

    @Test func metadataAndPlugin() {
        let extensions = KubernetesPlugin.makeExtensions()
        #expect(extensions.map(\.id) == ["kubernetes", "kubernetes-pods"])
        let k8s = extensions[0]
        #expect(k8s.layer == .integration)
        #expect(k8s.optional == ["gcp"])
        #expect(k8s.metadata.version == "1.1.0")
        #expect(k8s.metadata.category == .cloud)
        #expect(k8s.metadata.author == .dash)
        #expect(extensions[1].requires == ["kubernetes"])
        #expect(extensions[1].layer == .feature)
        #expect(extensions[1].widgets.map(\.kind) == ["kubernetes.pods"])
    }

    @Test func cEntryPointExportsBothExtensions() {
        let factory = Unmanaged<DashPluginFactory>.fromOpaque(dashPluginEntry()).takeRetainedValue()
        #expect(factory.make().map(\.id) == ["kubernetes", "kubernetes-pods"])
    }
}
