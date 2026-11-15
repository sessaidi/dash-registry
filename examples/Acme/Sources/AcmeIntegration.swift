import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Acme account: an API token in the Keychain and an authenticated connection that
/// features use without seeing the token.
@MainActor
@Observable
final class AcmeIntegration: Integration {
    let id = "acme"
    let name = "Acme"
    let systemImage = "link"
    let metadata = ExtensionMetadata(version: "1.0.0", author: ExtensionAuthor(name: "Ada", email: "ada@example.com"),
                                     summary: "Connects your Acme account.", category: .other, minimumDashKit: "2.0.0")
    let secretKeys = [SecretKey("token", "API token")]
    let secrets: SecretStore? = SecretStore(extensionID: "acme")

    /// The real service. Settings can point Acme elsewhere (the mock server, a self-hosted Acme).
    static let apiURL = URL(string: "https://api.example.com")!

    @ObservationIgnored private let readToken: @MainActor () -> String?
    @ObservationIgnored private let session: URLSession?
    @ObservationIgnored private let fixedServer: URL?
    @ObservationIgnored private var check: Task<Void, Never>?
    private(set) var account: String?
    private(set) var lastError: String?

    /// `token`, `session` and `server` are for tests; Dash uses the Keychain, the shared session
    /// and the server saved in Settings.
    init(token: (@MainActor () -> String?)? = nil, session: URLSession? = nil, server: URL? = nil) {
        let store = SecretStore(extensionID: "acme")
        readToken = token ?? { store.read("token") }
        self.session = session
        fixedServer = server
    }

    /// Where requests go: the one saved in Settings, else the real service. Not a secret, so it's
    /// a preference (the extension's own `preferences`), not a Keychain item.
    var server: URL { fixedServer ?? preferences.string("server").flatMap(URL.init(string:)) ?? Self.apiURL }

    private var token: String? { readToken().flatMap { $0.isEmpty ? nil : $0 } }
    var isConnected: Bool { token != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: account) }

    var connection: IntegrationConnection? {
        guard let token else { return nil }
        return IntegrationConnection(baseURL: server, headers: ["Authorization": "Bearer \(token)"], session: session)
    }

    /// What features may read without the secret (e.g. the signed-in account).
    var exports: JSONValue { ["account": account.map { .string($0) } ?? .null] }

    var tools: [DashiiTool] { AcmeTools.tools(integration: self) }

    func start(host: any ExtensionContext) {
        if check == nil { verify() }
    }

    /// At launch, while the splash screen shows progress: waits for the check `start` began.
    func prepare(host: any ExtensionContext) async throws {
        await (check ?? verify()).value
        if let lastError { throw ToolError(lastError) }
    }

    func setToken(_ token: String) {
        secrets?.write("token", token)
        account = nil
        verify()
    }

    /// Points Acme at another server: https, or plain http on this Mac only (the token travels
    /// with every request, so it never crosses the network unencrypted). False if refused.
    @discardableResult
    func setServer(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), let host = url.host() else { return false }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return false }
        preferences.set(url.absoluteString, "server")
        account = nil
        verify()
        return true
    }

    /// Asks the API who the token belongs to. Adjust the path and field to the service's.
    /// A new check cancels the one in flight, so the answer for an old token never wins.
    @discardableResult
    func verify() -> Task<Void, Never> {
        check?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            guard let connection else { lastError = nil; return }
            do {
                let name = try await connection.get("/me", service: name)["name"]?.string
                guard !Task.isCancelled else { return }
                account = name
                lastError = nil
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
            }
        }
        check = task
        return task
    }

    func settingsView() -> AnyView { AnyView(AcmeSettings(integration: self)) }
}

private struct AcmeSettings: View {
    let integration: AcmeIntegration
    @State private var server = ""
    @State private var refused = false

    var body: some View {
        Form {
            Section {
                SecretField("API token", isStored: integration.isConnected, onSave: { integration.setToken($0) },
                            onRemove: { integration.setToken("") })
                LabeledContent("Status") { ConnectionStatusLabel(integration.connectionState) }
            } footer: {
                Text("Stored in your Keychain. Features use the connection; they never see the token.")
            }
            Section {
                TextField("Server", text: $server, prompt: Text(AcmeIntegration.apiURL.absoluteString))
                    .onSubmit { refused = !integration.setServer(server) }
            } footer: {
                Text(refused ? "Use an https address, or http://localhost for the mock server."
                     : "Press Return to save. The tutorials' mock server is http://localhost:8787.")
                    .foregroundStyle(refused ? .red : .secondary)
            }
        }
        .onAppear { server = integration.server.absoluteString }
    }
}
