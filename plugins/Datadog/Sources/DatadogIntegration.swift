import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Datadog account: a site, an API key and an application key (both in the user's secret
/// store), and a read-only connection for Claude and features. Nothing here changes Datadog.
@MainActor
@Observable
final class DatadogIntegration: Integration {
    let id = "datadog"
    let name = "Datadog"
    let systemImage = "dog"
    let metadata = ExtensionMetadata(
        version: "1.0.0", author: .dash,
        summary: "Your Datadog site, read-only: monitors, metrics, logs, events, incidents, dashboards, SLOs, hosts and services.",
        category: .monitoring, tags: ["datadog", "monitoring", "observability", "apm", "logs"], minimumDashKit: "2.0.0")
    let secretKeys = [SecretKey("api_key", "API key"), SecretKey("app_key", "Application key")]
    let secrets: SecretStore? = SecretStore(extensionID: "datadog")

    /// Datadog sites (the API is `api.<site>`, the app `app.<site>`).
    static let sites = ["datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com", "ap2.datadoghq.com", "ddog-gov.com"]
    /// Tool output larger than this is cut, so one call can't flood the conversation.
    static let maxToolCharacters = 60_000

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readSecret: @MainActor (String) -> String?
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?

    var site: String {
        didSet {
            defaults.set(site, forKey: "datadog.site")
            account = nil
            Task { await verify() }
        }
    }
    private(set) var account: String?
    private(set) var lastError: String?
    /// Bumped when a key changes, so views re-read `isConnected`.
    private var keysVersion = 0

    /// `secret` and `session` are for tests; Dash uses the user's secret store and the shared session.
    init(defaults: UserDefaults = DashStorage.defaults, secret: (@MainActor (String) -> String?)? = nil, session: URLSession? = nil) {
        self.defaults = defaults
        let store = SecretStore(extensionID: "datadog")
        readSecret = secret ?? { store.read($0) }
        self.session = session
        site = defaults.string(forKey: "datadog.site") ?? "datadoghq.com"
    }

    private func key(_ name: String) -> String? {
        _ = keysVersion
        return readSecret(name).flatMap { $0.isEmpty ? nil : $0 }
    }

    var apiURL: URL { URL(string: "https://api.\(site)")! }
    var appURL: URL { URL(string: "https://app.\(site)")! }
    var isConnected: Bool { key("api_key") != nil && key("app_key") != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: account) }

    var connection: IntegrationConnection? {
        guard let api = key("api_key"), let app = key("app_key") else { return nil }
        return IntegrationConnection(baseURL: apiURL, headers: ["DD-API-KEY": api, "DD-APPLICATION-KEY": app, "Accept": "application/json"],
                                     session: session)
    }

    var exports: JSONValue { ["site": .string(site), "app_url": .string(appURL.absoluteString), "account": account.map { .string($0) } ?? .null] }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await verify() }
    }

    func prepare(host: any ExtensionContext) async throws {
        self.host = host
        await verify()
        if let lastError { throw ToolError(lastError) }
    }

    func setKey(_ name: String, _ value: String) {
        secrets?.write(name, value)
        keysVersion += 1
        account = nil
        Task { await verify() }
    }

    /// Checks the API key (`/api/v1/validate`), then reads who the application key belongs to.
    func verify() async {
        guard let connection else { lastError = nil; return }
        do {
            guard try await connection.get("/api/v1/validate", service: name)["valid"] == true else {
                lastError = "Datadog rejected the API key."
                return
            }
            let user = try? await connection.get("/api/v2/current_user", service: name)
            account = user?["data"]?["attributes"]?["handle"]?.string ?? user?["data"]?["attributes"]?["email"]?.string ?? site
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func settingsView() -> AnyView { AnyView(DatadogSettings(integration: self)) }

    // MARK: Requests

    func requireConnection() throws -> IntegrationConnection {
        guard let connection else { throw ToolError("Connect Datadog in Settings › Datadog (API key and application key).") }
        return connection
    }

    /// A GET with query parameters, encoded strictly (Datadog queries contain `+`, `:` and `&`).
    func get(_ path: String, _ query: [String: String?] = [:]) async throws -> JSONValue {
        try await requireConnection().get(Self.path(path, query), service: name)
    }

    /// Logs search is a POST but only reads; it's the one POST this integration sends.
    func searchLogs(query: String, from: String, to: String, limit: Int) async throws -> JSONValue {
        let connection = try requireConnection()
        guard let url = connection.url("/api/v2/logs/events/search") else { throw ToolError("Bad Datadog URL.") }
        let body: JSONValue = ["filter": ["query": .string(query), "from": .string(from), "to": .string(to)],
                               "page": ["limit": .number(Double(limit))], "sort": "-timestamp"]
        let request = try HTTP.request(url, method: "POST", body: body, headers: ["Content-Type": "application/json"])
        let (data, _) = try await connection.send(request, service: name)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    static func path(_ path: String, _ query: [String: String?]) -> String {
        let items = query.compactMap { name, value in value.map { (name, $0) } }.sorted { $0.0 < $1.0 }
        guard !items.isEmpty else { return path }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#[]")
        let encoded = items.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return path + (path.contains("?") ? "&" : "?") + encoded.joined(separator: "&")
    }

    /// Cuts output Claude doesn't need whole.
    static func limited(_ value: JSONValue) -> JSONValue {
        let text = value.jsonString()
        return text.count > maxToolCharacters ? .string(String(text.prefix(maxToolCharacters)) + "\n[truncated]") : value
    }

    var tools: [DashiiTool] { DatadogTools.tools(self) }
}
