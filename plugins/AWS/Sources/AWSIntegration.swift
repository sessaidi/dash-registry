import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Layer 1 for AWS: a profile from ~/.aws (keys or IAM Identity Center), with every request
/// signed in-process (SigV4). Features send full `url`s on *.amazonaws.com with
/// `"integration": "aws"`; the service and region are read from the host.
@MainActor
@Observable
final class AWSIntegration: Integration {
    static let profileKey = "aws.profile"
    static let regionKey = "aws.region"
    static let maxToolCharacters = 100_000

    let id = "aws"
    let name = "AWS"
    let systemImage = "server.rack"
    let metadata = ExtensionMetadata(version: "1.1.0", summary: "Profiles from ~/.aws (keys or SSO), SigV4-signed in-process.", category: .cloud, homepage: "https://github.com/sessaidi/dash")

    @ObservationIgnored private let defaults: UserDefaults
    /// URLSession for signed requests; nil uses the shared session. Tests inject a stubbed one.
    @ObservationIgnored private let session: URLSession?
    /// The host from `start(host:)`, for the "Features using this integration" section.
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?

    var profileName: String { didSet { defaults.set(profileName, forKey: Self.profileKey); Task { await reload() } } }
    /// Empty: the profile's region.
    var regionOverride: String { didSet { defaults.set(regionOverride, forKey: Self.regionKey) } }
    private(set) var profiles: [AWSCredentialsProvider.Profile] = []
    private(set) var identity: String?
    private(set) var lastError: String?

    @ObservationIgnored let provider: AWSCredentialsProvider

    /// Everything but the defaults exists for tests; the app reads ~/.aws and uses the shared session.
    init(defaults: UserDefaults = DashStorage.defaults, environment: [String: String] = ShellEnvironment.current,
         provider: AWSCredentialsProvider = AWSCredentialsProvider(), session: URLSession? = nil) {
        self.defaults = defaults
        self.provider = provider
        self.session = session
        profileName = defaults.string(forKey: Self.profileKey) ?? environment["AWS_PROFILE"] ?? "default"
        regionOverride = defaults.string(forKey: Self.regionKey) ?? ""
    }

    var profile: AWSCredentialsProvider.Profile? { profiles.first { $0.name == profileName } }
    var region: String { regionOverride.isEmpty ? (profile?.region ?? "us-east-1") : regionOverride }
    var isConnected: Bool { profile != nil && lastError == nil }
    var connectionState: ConnectionState {
        if let lastError { return .failed(lastError) }
        return identity.map { .connected($0) } ?? (profile == nil ? .notConfigured : .checking)
    }

    var connection: IntegrationConnection? {
        guard profile != nil else { return nil }
        let provider = provider
        let profileName = profileName
        let region = region
        return IntegrationConnection(baseURL: URL(string: "https://sts.\(region).amazonaws.com")!, hosts: [".amazonaws.com"], sign: { request in
            let scope = SigV4.scope(for: request.url?.host() ?? "", defaultRegion: region)
            let credentials = try await provider.credentials(profile: profileName)
            return SigV4.sign(request, credentials: credentials, service: scope.service, region: scope.region)
        }, session: session)
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await reload() }
    }

    func reload() async {
        await provider.clearCache()
        profiles = await provider.profiles()
        guard profile != nil else {
            identity = nil
            lastError = profiles.isEmpty ? "No profiles in ~/.aws/config or ~/.aws/credentials." : "Choose a profile."
            return
        }
        do {
            identity = try await callerIdentity()
            lastError = nil
        } catch {
            identity = nil
            lastError = error.localizedDescription
        }
    }

    /// Sends a request through the connection (signed for the URL's service and region).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let connection, let url = request.url, connection.allows(url) else { throw ToolError("Only https://*.amazonaws.com URLs can be signed.") }
        return try await connection.send(request, service: "AWS")
    }

    /// STS GetCallerIdentity -> the ARN of who Dash acts as.
    func callerIdentity() async throws -> String {
        var request = URLRequest(url: URL(string: "https://sts.\(region).amazonaws.com/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("Action=GetCallerIdentity&Version=2011-06-15".utf8)
        let (data, _) = try await send(request)
        let xml = String(decoding: data, as: UTF8.self)
        return xml.firstMatch(of: /<Arn>([^<]+)<\/Arn>/).map { String($0.1) } ?? "unknown"
    }

    func prepare(host: any ExtensionContext) async throws {
        await reload()
        if let lastError, profile != nil { throw ToolError(lastError) }
    }

    func settingsView() -> AnyView { AnyView(AWSSettingsView(aws: self)) }
}
