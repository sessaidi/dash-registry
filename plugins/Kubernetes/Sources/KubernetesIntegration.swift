import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Layer 1 for Kubernetes: the kubeconfig read in-process ($KUBECONFIG's first file or
/// ~/.kube/config), one context at a time. No kubectl and no credential plugins are run:
/// tokens, token files, basic auth and client certificates are used directly, and
/// `gke-gcloud-auth-plugin` contexts get their token from the Google Cloud integration.
@MainActor
@Observable
final class KubernetesIntegration: Integration {
    let id = "kubernetes"
    let name = "Kubernetes"
    let systemImage = "helm"
    let optional = ["gcp"]
    let metadata = ExtensionMetadata(
        version: "1.1.0", author: .dash, summary: "Your kubeconfig's clusters, read in-process: read-only API access for Claude and features.",
        category: .cloud, tags: ["kubernetes", "k8s", "kubeconfig", "gke"], minimumDashKit: "1.3.0")

    static let googleProbe = URL(string: "https://www.googleapis.com")!

    /// The kubeconfig file in use.
    let configURL: URL
    private(set) var config: KubeConfig?
    private(set) var loadError: String?
    /// Context chosen in Settings; empty follows the kubeconfig's current-context.
    var selectedContext: String {
        didSet {
            defaults.set(selectedContext, forKey: "kubernetes.context")
            rebuild()
            Task { await verify() }
        }
    }
    /// Namespace override; empty uses the context's namespace (or "default").
    var namespaceSetting: String {
        didSet { defaults.set(namespaceSetting.trimmingCharacters(in: .whitespaces), forKey: "kubernetes.namespace") }
    }
    private(set) var resolved: ResolvedContext?
    private(set) var resolveError: String?
    private(set) var lastError: String?
    private(set) var credentialsRejected = false
    private(set) var serverVersion: String?
    private(set) var isChecking = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    /// Where gke-gcloud-auth-plugin contexts get their Google token. Default: the `gcp` integration.
    @ObservationIgnored var googleConnection: @MainActor @Sendable () -> IntegrationConnection?

    init(configURL: URL = KubeConfig.defaultPath(), defaults: UserDefaults = .standard, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configURL = configURL
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        selectedContext = defaults.string(forKey: "kubernetes.context") ?? ""
        namespaceSetting = defaults.string(forKey: "kubernetes.namespace") ?? ""
        googleConnection = { nil }
        googleConnection = { [weak self] in self?.host?.integration("gcp")?.connection }
        reload()
    }

    // MARK: State

    var contextNames: [String] { config?.contexts.map(\.name) ?? [] }
    /// The context in use: the Settings choice, else current-context.
    var activeContext: String? { selectedContext.isEmpty ? config?.currentContext : selectedContext }
    var namespace: String {
        let override = namespaceSetting.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? resolved?.namespace ?? "default" : override
    }
    var needsGoogle: Bool { resolved?.auth == .gcp }
    var googleAvailable: Bool { googleConnection() != nil }

    /// Why the context can't be used at all (nil when it can).
    var blockingProblem: String? {
        if let loadError { return loadError }
        if let resolveError { return resolveError }
        guard let resolved else { return "No context selected." }
        if case .unsupported(let reason) = resolved.auth { return reason }
        if needsGoogle, !googleAvailable { return "Context \(resolved.name) uses gke-gcloud-auth-plugin: connect the Google Cloud integration first." }
        return nil
    }

    var isConnected: Bool { blockingProblem == nil && session != nil && !credentialsRejected }

    var connectionState: ConnectionState {
        if isChecking { return .checking }
        if let problem = blockingProblem { return .failed(problem) }
        if let lastError { return .failed(lastError) }
        guard let resolved else { return .notConfigured }
        return .connected("\(resolved.name)" + (serverVersion.map { " · Kubernetes \($0)" } ?? ""))
    }

    var connection: IntegrationConnection? {
        guard blockingProblem == nil, let resolved, let session else { return nil }
        var headers = ["Accept": "application/json"]
        var sign: (@Sendable (URLRequest) async throws -> URLRequest)?
        switch resolved.auth {
        case .none, .unsupported: break
        case .bearer(let token): headers["Authorization"] = "Bearer \(token)"
        case .basic(let username, let password): headers["Authorization"] = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case .tokenFile(let path):
            sign = { request in
                var request = request
                request.setValue("Bearer \(try Self.readToken(path))", forHTTPHeaderField: "Authorization")
                return request
            }
        case .gcp:
            let google = googleConnection
            sign = { request in
                guard let gcp = await google() else { throw ToolError("Connect Google Cloud in Settings to reach this GKE cluster.") }
                let probe = try await gcp.authorize(URLRequest(url: Self.googleProbe))
                guard let authorization = probe.value(forHTTPHeaderField: "Authorization") else {
                    throw ToolError("Google Cloud didn't provide a token for this GKE cluster.")
                }
                var request = request
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                return request
            }
        }
        return IntegrationConnection(baseURL: resolved.server, headers: headers, sign: sign, session: session)
    }

    var exports: JSONValue {
        [
            "contexts": .array(contextNames.map(JSONValue.string)),
            "currentContext": activeContext.map(JSONValue.string) ?? .null,
            "namespace": .string(namespace),
            "server": resolved.map { .string($0.server.absoluteString) } ?? .null,
        ]
    }

    nonisolated static func readToken(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else { throw ToolError("Can't read the token file \(path).") }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ToolError("The token file \(path) is empty.") }
        return token
    }

    // MARK: Loading

    /// Re-reads the kubeconfig file.
    func reload() {
        do {
            config = try KubeConfig.load(configURL)
            loadError = nil
        } catch {
            config = nil
            loadError = error.localizedDescription
        }
        rebuild()
    }

    /// Resolves the active context and builds its TLS session.
    func rebuild() {
        session?.finishTasksAndInvalidate()
        session = nil
        resolved = nil
        resolveError = nil
        lastError = nil
        credentialsRejected = false
        serverVersion = nil
        guard let config else { return }
        do {
            let context = try config.resolve(activeContext)
            resolved = context
            if context.auth.isSupported { session = try KubeTrust.session(for: context, configuration: sessionConfiguration) }
        } catch {
            resolveError = error.localizedDescription
        }
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await verify() }
    }

    /// GET /version: proves the server, trust and credentials work.
    func verify() async {
        guard let connection else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let version = try await connection.get("/version", service: "Kubernetes")
            serverVersion = version["gitVersion"]?.string
            lastError = nil
            credentialsRejected = false
        } catch let error as HTTPError {
            credentialsRejected = error.status == 401
            lastError = error.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    func settingsView() -> AnyView { AnyView(KubernetesSettings(kubernetes: self)) }

    // MARK: Tools

    private struct GetInput: Decodable { let path: String }
    private struct PodsInput: Decodable {
        let namespace: String?
        let labelSelector: String?
        let fieldSelector: String?
    }

    static let maxCharacters = 100_000

    /// Rejects anything that isn't a plain read: full URLs, `..`, watches, follows and streaming subresources.
    static func checkReadOnly(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("://"), !path.hasPrefix("//") else {
            throw ToolError("path must be an API path starting with /, e.g. /api/v1/namespaces/default/pods.")
        }
        let parts = path.split(separator: "?", maxSplits: 1)
        let segments = parts[0].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if segments.contains("..") || segments.contains(".") { throw ToolError("path must not contain . or .. segments.") }
        let streaming: Set<String> = ["exec", "attach", "portforward", "proxy"]
        if let segment = segments.first(where: { streaming.contains($0) }) {
            throw ToolError("\(segment) is not a read-only request; k8s_get only reads resources.")
        }
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1).map { $0.removingPercentEncoding ?? String($0) }
                if ["watch", "follow"].contains(pair[0].lowercased()), pair.count == 1 || !["false", "0"].contains(pair[1].lowercased()) {
                    throw ToolError("\(pair[0]) requests stream forever; ask for a plain list instead.")
                }
            }
        }
    }

    static func validNamespace(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 63 && text.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
            && text.first != "-" && text.last != "-"
    }

    func requireConnection() throws -> IntegrationConnection {
        guard let connection else { throw ToolError(blockingProblem ?? "Set up Kubernetes in Settings › Kubernetes.") }
        return connection
    }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "k8s_get",
                description: "Read any Kubernetes API path on the current context (GET only), e.g. /api/v1/namespaces/default/pods, /apis/apps/v1/namespaces/prod/deployments/web, /api/v1/namespaces/default/pods/web-1/log?tailLines=100 or /api/v1/nodes. Watches, exec, attach, port-forward and proxy are refused. Responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("API path starting with /, with an optional query string.")], required: ["path"]
            ) { [weak self] input in
                guard let self else { throw ToolError("Kubernetes is not loaded.") }
                let path = try input.toolInput(GetInput.self).path.trimmingCharacters(in: .whitespaces)
                try Self.checkReadOnly(path)
                return try await Self.get(path, connection: try requireConnection())
            },
            ClaudeTool(
                name: "k8s_list_pods",
                description: "List pods on the current Kubernetes context with phase, kubectl-style status (CrashLoopBackOff, ImagePullBackOff…), ready containers, restarts and node. Defaults to the configured namespace; use \"all\" for every namespace.",
                properties: [
                    "namespace": JSONSchema.string("Namespace, or \"all\". Default: the namespace set in Settings."),
                    "labelSelector": JSONSchema.string("Label selector, e.g. app=web,tier!=cache."),
                    "fieldSelector": JSONSchema.string("Field selector, e.g. status.phase!=Running or spec.nodeName=node-1."),
                ]
            ) { [weak self] input in
                guard let self else { throw ToolError("Kubernetes is not loaded.") }
                let request = try input.toolInput(PodsInput.self)
                let namespace = request.namespace?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? self.namespace
                let all = namespace == "all" || namespace == "*"
                guard all || Self.validNamespace(namespace) else { throw ToolError("\"\(namespace)\" is not a valid namespace name.") }
                let connection = try requireConnection()
                let list = try await connection.get(
                    PodSummary.path(namespace: all ? nil : namespace, labelSelector: request.labelSelector, fieldSelector: request.fieldSelector, limit: 500),
                    service: "Kubernetes")
                let pods = PodSummary.list(list)
                var result: [String: JSONValue] = [
                    "context": activeContext.map(JSONValue.string) ?? .null, "namespace": .string(all ? "all" : namespace),
                    "count": .number(Double(pods.count)), "pods": .array(pods.map(\.json)),
                ]
                if let next = list["metadata"]?["continue"]?.string, !next.isEmpty { result["truncated"] = "More than 500 pods; narrow with a selector." }
                return .object(result)
            },
        ] + granularTools
    }

    /// GETs a path and returns JSON, or text cut at `maxCharacters`.
    static func get(_ path: String, connection: IntegrationConnection) async throws -> JSONValue {
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        let (data, _) = try await connection.send(URLRequest(url: url), service: "Kubernetes")
        let text = String(decoding: data, as: UTF8.self)
        if text.count > maxCharacters { return .string(String(text.prefix(maxCharacters)) + "\n[truncated]") }
        return (try? JSONValue.parse(data)) ?? .string(text)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Settings

private struct KubernetesSettings: View {
    @Bindable var kubernetes: KubernetesIntegration

    var body: some View {
        Form {
            Section {
                LabeledContent("kubeconfig") {
                    Text(kubernetes.configURL.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                if !kubernetes.contextNames.isEmpty {
                    Picker("Context", selection: $kubernetes.selectedContext) {
                        Text("current-context" + (kubernetes.config?.currentContext.map { " (\($0))" } ?? "")).tag("")
                        ForEach(kubernetes.contextNames, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Namespace", text: $kubernetes.namespaceSetting, prompt: Text(kubernetes.resolved?.namespace ?? "default"))
                if let resolved = kubernetes.resolved {
                    LabeledContent("Server") { Text(resolved.server.absoluteString).textSelection(.enabled) }
                    LabeledContent("Authentication", value: resolved.auth.isSupported ? authLabel(resolved) : "Unsupported")
                    LabeledContent("Trust", value: resolved.insecure ? "Not verified" : resolved.certificateAuthorities.isEmpty ? "System roots" : "Cluster CA")
                    if resolved.insecure {
                        Label("TLS verification is off for this cluster (insecure-skip-tls-verify). Anyone on the network path can impersonate it and read your credentials.",
                              systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(Tone.warning.color)
                    }
                    if kubernetes.needsGoogle, !kubernetes.googleAvailable {
                        Label("This context uses gke-gcloud-auth-plugin. Connect the Google Cloud integration and Dash will use its token instead.",
                              systemImage: "cloud")
                            .foregroundStyle(Tone.warning.color)
                    }
                }
                HStack {
                    ConnectionStatusLabel(kubernetes.connectionState)
                    Spacer()
                    Button("Reload kubeconfig") { kubernetes.reload(); Task { await kubernetes.verify() } }
                    AsyncButton("Check") { await kubernetes.verify() }
                }
            } header: {
                Text("Cluster")
            } footer: {
                Text("Dash reads $KUBECONFIG (first file) or ~/.kube/config itself; nothing is executed. Supported: tokens, token files, basic auth, client certificates (RSA/ECDSA), and gke-gcloud-auth-plugin through Google Cloud. Other exec plugins (aws, kubelogin…) aren't.")
            }
        }
        .formStyle(.grouped)
    }

    private func authLabel(_ resolved: ResolvedContext) -> String {
        let base = resolved.auth.summary
        return resolved.clientCertificate != nil ? (resolved.auth == .none ? "client certificate" : "client certificate + \(base)") : base
    }
}
