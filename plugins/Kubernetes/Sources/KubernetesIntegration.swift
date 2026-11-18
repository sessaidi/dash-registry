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
        version: "1.12.0", author: .dash, summary: "Your kubeconfig's clusters, read in-process: read-only API access for Dashii and features.",
        category: .cloud, tags: ["kubernetes", "k8s", "kubeconfig", "gke"], minimumDashKit: "2.4.0")

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
    /// The clock for freshness (tests move it).
    @ObservationIgnored var now: @MainActor () -> Date = { .now }
    /// Where gke-gcloud-auth-plugin contexts get their Google token. Default: the `gcp` integration.
    @ObservationIgnored var googleConnection: @MainActor @Sendable () -> IntegrationConnection?

    init(configURL: URL = KubeConfig.defaultPath(), defaults: UserDefaults = DashStorage.defaults, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
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
        return makeConnection(resolved, session: session)
    }

    /// Sessions for contexts other than the active one, built on demand (widgets browsing another cluster).
    @ObservationIgnored private var otherSessions: [String: (context: ResolvedContext, session: URLSession)] = [:]

    /// A connection to any kubeconfig context; nil (or a blank name) is the active one.
    /// Doesn't change the context Dash and Claude use.
    func connection(context name: String?) -> IntegrationConnection? {
        guard let name, !name.isEmpty, name != activeContext else { return connection }
        if let cached = otherSessions[name] { return makeConnection(cached.context, session: cached.session) }
        guard let config, let context = try? config.resolve(name), context.auth.isSupported,
              context.auth != .gcp || googleAvailable,
              let session = try? KubeTrust.session(for: context, configuration: sessionConfiguration) else { return nil }
        otherSessions[name] = (context, session)
        return makeConnection(context, session: session)
    }

    private func makeConnection(_ resolved: ResolvedContext, session: URLSession) -> IntegrationConnection {
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
        for other in otherSessions.values { other.session.finishTasksAndInvalidate() }
        otherSessions = [:]
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
}
