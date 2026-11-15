import DashKit
import Foundation
import SwiftData
import SwiftUI

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

    static func serve(_ host: String, json: String, status: Int = 200) {
        serve(host) { _ in (status, Data(json.utf8)) }
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

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(_ prompt: PermissionPrompt) async -> Bool { false }
}

@MainActor
final class FakeDashii: DashiiService {
    var model: String { "test" }
    func complete(_ request: DashiiRequest) async throws -> String { "" }
}

/// Stands in for the `gcp` integration: signs with a fixed token.
@MainActor
final class FakeGCP: Integration {
    let id = "gcp"
    let name = "Google Cloud"
    let systemImage = "cloud"
    var isConnected: Bool { true }
    var connection: IntegrationConnection? {
        IntegrationConnection(baseURL: URL(string: "https://www.googleapis.com")!, hosts: [".googleapis.com"]) { request in
            var request = request
            request.setValue("Bearer ya29.fake-google-token", forHTTPHeaderField: "Authorization")
            return request
        }
    }
}

@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let dashii: any DashiiService = FakeDashii()
    let activity = ActivityLog()

    init(_ extensions: [any DashExtension]) {
        let container = try! ModelContainer(for: Schema([]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) {}
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// A temporary kubeconfig file.
func writeKubeconfig(_ yaml: String, extraFiles: [String: String] = [:]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "kube-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, contents) in extraFiles {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    let url = directory.appending(path: "config")
    try yaml.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@MainActor
func makeIntegration(_ yaml: String, extraFiles: [String: String] = [:]) throws -> KubernetesIntegration {
    KubernetesIntegration(
        configURL: try writeKubeconfig(yaml, extraFiles: extraFiles), defaults: UserDefaults(suiteName: "kube-tests-\(UUID().uuidString)")!,
        sessionConfiguration: StubProtocol.configuration())
}

/// A single-context kubeconfig on `host`; `user` and `cluster` lines are nested under their entries.
func singleContext(host: String, user: [String], namespace: String? = nil, cluster: [String] = []) -> String {
    var lines = ["apiVersion: v1", "kind: Config", "clusters:", "- cluster:", "    server: https://\(host)"]
    lines += cluster.map { "    " + $0 }
    lines += ["  name: c", "contexts:", "- context:", "    cluster: c", "    user: u"]
    if let namespace { lines.append("    namespace: \(namespace)") }
    lines += ["  name: ctx", "current-context: ctx", "users:", "- name: u", "  user:"]
    lines += user.map { "    " + $0 }
    return lines.joined(separator: "\n")
}

enum Kubeconfigs {
    static let gke = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: \(Fixtures.base64(Fixtures.caCrt))
            server: https://34.123.45.67
          name: gke_acme-prod_us-central1_main
        contexts:
        - context:
            cluster: gke_acme-prod_us-central1_main
            user: gke_acme-prod_us-central1_main
          name: gke_acme-prod_us-central1_main
        current-context: gke_acme-prod_us-central1_main
        kind: Config
        preferences: {}
        users:
        - name: gke_acme-prod_us-central1_main
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              command: gke-gcloud-auth-plugin
              installHint: Install gke-gcloud-auth-plugin for use with kubectl by following
                https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin
              provideClusterInfo: true
        """

    static let eks = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: \(Fixtures.base64(Fixtures.caCrt))
            server: https://ABCDEF0123456789.gr7.us-west-2.eks.amazonaws.com
          name: arn:aws:eks:us-west-2:123456789012:cluster/demo
        contexts:
        - context:
            cluster: arn:aws:eks:us-west-2:123456789012:cluster/demo
            user: arn:aws:eks:us-west-2:123456789012:cluster/demo
          name: arn:aws:eks:us-west-2:123456789012:cluster/demo
        current-context: arn:aws:eks:us-west-2:123456789012:cluster/demo
        kind: Config
        preferences: {}
        users:
        - name: arn:aws:eks:us-west-2:123456789012:cluster/demo
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              args:
              - --region
              - us-west-2
              - eks
              - get-token
              - --cluster-name
              - demo
              - --output
              - json
              command: aws
              env:
              - name: AWS_PROFILE
                value: prod
              interactiveMode: IfAvailable
              provideClusterInfo: false
        """

    static let kind = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: \(Fixtures.base64(Fixtures.caCrt))
            server: https://127.0.0.1:6443
          name: kind-kind
        contexts:
        - context:
            cluster: kind-kind
            user: kind-kind
          name: kind-kind
        current-context: kind-kind
        kind: Config
        preferences: {}
        users:
        - name: kind-kind
          user:
            client-certificate-data: \(Fixtures.base64(Fixtures.clientRsaCrt))
            client-key-data: \(Fixtures.base64(Fixtures.clientRsaKey))
        """

    /// Hand-written: indented lists, quotes, comments, flow mappings, insecure and file references.
    static let tokens = """
        # Written by hand for the team clusters.
        apiVersion: "v1"
        kind: Config
        clusters:
          - name: dev   # Rancher-proxied
            cluster:
              server: 'https://rancher.example.com/k8s/clusters/c-abc'
              insecure-skip-tls-verify: true
          - name: staging
            cluster:
              server: https://staging.example.com:6443
              certificate-authority: certs/staging-ca.crt
        users:
          - name: sa
            user:
              token: "eyJhbGciOiJSUzI1NiIsImtpZCI6IiJ9.payload.sig"
          - name: file
            user:
              tokenFile: tokens/staging   # rotated by a sidecar
          - name: legacy
            user: {username: admin, password: "p@ss: word"}
        contexts:
          - name: dev
            context: {cluster: dev, user: sa, namespace: team-a}
          - name: staging
            context:
              cluster: staging
              user: file
          - name: legacy
            context:
              cluster: staging
              user: legacy
        current-context: dev
        """
}
