import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Docker Engine over its unix socket. Contract: id `docker`, baseURL `http://docker`,
/// a `transport` speaking HTTP/1.1 on the socket, exports `socket` and `version`, prefs under `docker.`.
@MainActor
@Observable
final class DockerIntegration: Integration {
    let id = "docker"
    let name = "Docker"
    let systemImage = "shippingbox"
    let metadata = ExtensionMetadata(
        version: "1.2.0", author: .dash,
        summary: "Lists, inspects and controls local Docker containers through the Engine API socket.",
        category: .cloud, tags: ["docker", "containers", "local"])

    static let baseURL = URL(string: "http://docker")!

    private(set) var version: String?
    private(set) var error: String?
    private(set) var checking = false
    /// Bumped when the socket preference changes so views refresh.
    private(set) var revision = 0
    /// Containers acted on recently (reference → when), so their exits aren't reported as crashes.
    private(set) var recentActions: [String: Date] = [:]
    @ObservationIgnored private(set) var host: (any ExtensionContext)?
    @ObservationIgnored var now: @MainActor () -> Date = { .now }
    /// Answers the engine's requests instead of the socket (tests).
    @ObservationIgnored var transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))?

    var socketPreference: String {
        get { _ = revision; return preferences.string("socket") ?? "" }
        set {
            preferences.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue, "socket")
            revision += 1
        }
    }

    /// The socket in use: the preference, else the first one found.
    var socketPath: String? {
        _ = revision
        return DockerSocket.resolve(preferred: preferences.string("socket"))
    }

    var isConnected: Bool { version != nil && error == nil }

    var connectionState: ConnectionState {
        if checking { return .checking }
        if let error { return .failed(error) }
        guard let socketPath else { return .notConfigured }
        return version.map { .connected("Docker \($0) via \(socketPath)") } ?? .notConfigured
    }

    var connection: IntegrationConnection? {
        if let transport { return IntegrationConnection(baseURL: Self.baseURL, headers: ["Accept": "application/json"], transport: transport) }
        guard let path = socketPath else { return nil }
        return IntegrationConnection(baseURL: Self.baseURL, headers: ["Accept": "application/json"], transport: { request in
            try await UnixHTTP.send(request, socketPath: path)
        })
    }

    var exports: JSONValue {
        ["socket": socketPath.map { .string($0) } ?? .null, "version": version.map { .string($0) } ?? .null]
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await verify() }
    }

    /// GET /version on the current socket.
    func verify() async {
        guard let connection else {
            version = nil
            error = nil
            return
        }
        checking = true
        defer { checking = false }
        do {
            let info = try await connection.get("/version", service: "Docker")
            version = info["Version"]?.string ?? "unknown"
            error = nil
        } catch {
            version = nil
            self.error = error.localizedDescription
        }
    }

    func noteAction(on reference: String) {
        let cutoff = Date().addingTimeInterval(-120)
        recentActions = recentActions.filter { $0.value > cutoff }
        recentActions[reference] = Date()
    }

    /// References acted on in the last two minutes.
    var intentionalReferences: [String] {
        let cutoff = Date().addingTimeInterval(-120)
        return recentActions.filter { $0.value > cutoff }.map(\.key)
    }

    func settingsView() -> AnyView { AnyView(DockerSettingsView(integration: self)) }
}
