import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Layer 1 for Google Cloud: credentials read and refreshed in-process (no gcloud, no
/// gke-gcloud-auth-plugin at run time). GKE/GCP features build on its `connection`.
@MainActor
@Observable
final class GCPIntegration: Integration {
    let id = "gcp"
    let name = "Google Cloud"
    let systemImage = "cloud"
    let metadata = ExtensionMetadata(
        version: "1.3.0", author: .dash, summary: "Google credentials refreshed in-process; read-only tools for GKE, Cloud Run, Pub/Sub, Cloud SQL, Artifact Registry, IAM, Compute, Cloud Build, Error Reporting, logs and metrics.",
        category: .cloud, tags: ["gcp", "google", "cloud", "gke", "cloud-run", "pubsub"], homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.0.0")

    static let baseURL = URL(string: "https://www.googleapis.com")!
    nonisolated static let tokenInfoURL = URL(string: "https://oauth2.googleapis.com/tokeninfo")!
    static let projectsURL = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
    static let responseLimit = 100_000

    /// Empty: Application Default Credentials (gcloud's file). Otherwise a service-account key file.
    var credentialsPath: String {
        didSet {
            preferences.set(credentialsPath, "credentials")
            reload()
            Task { await verify() }
        }
    }
    private(set) var account: String?
    private(set) var lastError: String?
    private(set) var checking = false
    @ObservationIgnored private(set) var credentials: GoogleCredentials?
    /// nil: `URLSession.shared`. Tests inject a stubbed session.
    @ObservationIgnored private let session: URLSession?

    init(credentialsPath: String? = nil, session: URLSession? = nil) {
        self.session = session
        self.credentialsPath = credentialsPath ?? PreferenceStore(prefix: "gcp").string("credentials") ?? ""
        reload()
    }

    var isConnected: Bool { credentials != nil && lastError == nil }
    var connectionState: ConnectionState {
        if checking && lastError == nil && account == nil { return .checking }
        return state(error: lastError, configured: credentials != nil, account: account)
    }

    /// Any *.googleapis.com URL, with a fresh OAuth token added to each request.
    var connection: IntegrationConnection? {
        guard let credentials else { return nil }
        return IntegrationConnection(baseURL: Self.baseURL, hosts: [".googleapis.com"], sign: { request in
            var request = request
            request.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
            return request
        }, session: session)
    }

    var exports: JSONValue {
        ["account": account.map(JSONValue.string) ?? .null, "credentialsFile": .string(credentialsFile.path)]
    }

    var credentialsFile: URL {
        credentialsPath.isEmpty ? GoogleCredentials.defaultPath : URL(filePath: (credentialsPath as NSString).expandingTildeInPath)
    }

    func reload() {
        do {
            credentials = try GoogleCredentials(file: credentialsFile, session: session ?? .shared)
            account = credentials?.account
            lastError = nil
        } catch {
            credentials = nil
            account = nil
            lastError = error.localizedDescription
        }
    }

    func start(host: any ExtensionContext) {
        Task { await verify() }
    }

    /// Gets a token and, for user credentials, the signed-in email (tokeninfo).
    func verify() async {
        guard let credentials else { return }
        checking = true
        defer { checking = false }
        do {
            let token = try await credentials.accessToken()
            if account == nil {
                account = try? await Self.email(token: token, session: session ?? .shared)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The email a token belongs to, from oauth2.googleapis.com/tokeninfo (token sent in the form body, not the URL).
    nonisolated static func email(token: String, session: URLSession) async throws -> String? {
        var request = URLRequest(url: tokenInfoURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleCredentials.form(["access_token": token])
        let (data, _) = try await HTTP.send(request, service: "Google OAuth", session: session)
        return try JSONValue.parse(data)["email"]?.string
    }

    func settingsView() -> AnyView { AnyView(GCPSettings(gcp: self)) }

    func requireConnection() throws -> IntegrationConnection {
        guard let connection else { throw ToolError(lastError ?? "Connect Google Cloud in Settings › Google Cloud.") }
        return connection
    }
}
