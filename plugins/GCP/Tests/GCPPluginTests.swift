import DashKit
import Foundation
import Security
import Synchronization
import Testing

// MARK: - HTTP stub

/// Answers every request of a stubbed session; records what was sent. No real network.
final class StubProtocol: URLProtocol {
    struct Recorded: Sendable {
        let request: URLRequest
        let body: Data
    }
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    static let handler = Mutex<Handler?>(nil)
    static let recorded = Mutex<[Recorded]>([])

    static func session(_ handler: @escaping Handler) -> URLSession {
        Self.handler.withLock { $0 = handler }
        recorded.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Recorded] { recorded.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.recorded.withLock { $0.append(Recorded(request: request, body: body)) }
        let (status, data) = Self.handler.withLock { $0 }?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

func formFields(_ body: Data) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
    }
    return fields
}

func json(_ value: JSONValue) -> Data { (try? value.data()) ?? Data() }

let tokenResponse = json(["access_token": "ya29.test", "expires_in": 3600, "token_type": "Bearer"])

let authorizedUser: JSONValue = [
    "type": "authorized_user", "client_id": "id.apps.googleusercontent.com", "client_secret": "s3cr+t/=",
    "refresh_token": "1//refresh token",
]

// MARK: - Keys

enum TestKeys {
    static func rsa() throws -> SecKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        return key
    }

    static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var length: [UInt8]
        if content.count < 0x80 {
            length = [UInt8(content.count)]
        } else {
            var count = content.count
            var bytes: [UInt8] = []
            while count > 0 { bytes.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return [tag] + length + content
    }

    /// PKCS#1 RSAPrivateKey wrapped in a PKCS#8 PrivateKeyInfo, as a "BEGIN PRIVATE KEY" PEM.
    static func pkcs8PEM(_ key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(key, &error) as Data? else { throw error!.takeRetainedValue() }
        let rsaEncryption: [UInt8] = [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let info = der(0x30, der(0x02, [0x00]) + der(0x30, rsaEncryption) + der(0x04, [UInt8](pkcs1)))
        let base64 = Data(info).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PRIVATE KEY-----\n\(base64)\n-----END PRIVATE KEY-----\n"
    }
}

func base64URLDecode(_ text: Substring) -> Data? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
}

// MARK: - Tests

@Suite(.serialized)
struct GCPPluginTests {
    @Test func refreshTokenGrantSendsFormBody() async throws {
        let session = StubProtocol.session { _, _ in (200, tokenResponse) }
        let credentials = try GoogleCredentials(json: authorizedUser, session: session)
        #expect(try await credentials.accessToken() == "ya29.test")

        let sent = try #require(StubProtocol.requests.first)
        #expect(sent.request.url == GoogleCredentials.tokenURL)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: sent.body, as: UTF8.self)
        #expect(body == "client_id=id.apps.googleusercontent.com&client_secret=s3cr%2Bt%2F%3D&grant_type=refresh_token&refresh_token=1%2F%2Frefresh%20token")
        #expect(formFields(sent.body)["refresh_token"] == "1//refresh token")
    }

    @Test func tokensAreCachedAndSharedAcrossConcurrentCallers() async throws {
        let session = StubProtocol.session { _, _ in (200, tokenResponse) }
        let credentials = try GoogleCredentials(json: authorizedUser, session: session)
        async let a = credentials.accessToken()
        async let b = credentials.accessToken()
        let tokens = try await [a, b, credentials.accessToken()]
        #expect(tokens == ["ya29.test", "ya29.test", "ya29.test"])
        #expect(StubProtocol.requests.count == 1)

        await credentials.invalidate()
        _ = try await credentials.accessToken()
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func shortLivedTokensAreRefreshed() async throws {
        let session = StubProtocol.session { _, _ in (200, json(["access_token": "short", "expires_in": 30])) }
        let credentials = try GoogleCredentials(json: authorizedUser, session: session)
        _ = try await credentials.accessToken()
        _ = try await credentials.accessToken()
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func oauthErrorsAreReported() async throws {
        let session = StubProtocol.session { _, _ in (400, json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."])) }
        let credentials = try GoogleCredentials(json: authorizedUser, session: session)
        await #expect(throws: GCPAuthError.oauth(status: 400, message: "Token has been expired or revoked.")) {
            try await credentials.accessToken()
        }
    }

    @Test func serviceAccountJWTIsSignedWithRS256() async throws {
        let key = try TestKeys.rsa()
        let account: JSONValue = [
            "type": "service_account", "client_email": "bot@proj.iam.gserviceaccount.com",
            "private_key": .string(try TestKeys.pkcs8PEM(key)), "token_uri": "https://oauth2.googleapis.com/token",
        ]
        let session = StubProtocol.session { _, _ in (200, tokenResponse) }
        let credentials = try GoogleCredentials(json: account, session: session)
        #expect(credentials.account == "bot@proj.iam.gserviceaccount.com")
        #expect(try await credentials.accessToken() == "ya29.test")

        let fields = formFields(try #require(StubProtocol.requests.first).body)
        #expect(fields["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer")
        let parts = try #require(fields["assertion"]).split(separator: ".")
        try #require(parts.count == 3)

        let header = try JSONValue.parse(try #require(base64URLDecode(parts[0])))
        #expect(header["alg"]?.string == "RS256")
        #expect(header["typ"]?.string == "JWT")
        let claims = try JSONValue.parse(try #require(base64URLDecode(parts[1])))
        #expect(claims["iss"]?.string == "bot@proj.iam.gserviceaccount.com")
        #expect(claims["scope"]?.string == GoogleCredentials.cloudPlatformScope)
        #expect(claims["aud"]?.string == "https://oauth2.googleapis.com/token")
        let iat = try #require(claims["iat"]?.int)
        #expect(claims["exp"]?.int == iat + 3600)

        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        let signature = try #require(base64URLDecode(parts[2]))
        #expect(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil))
        // A tampered payload must not verify.
        #expect(!SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("x.y".utf8) as CFData, signature as CFData, nil))
    }

    @Test func invalidKeysAndTypesAreRejected() throws {
        #expect(throws: GCPAuthError.invalidPrivateKey) {
            try GoogleCredentials(json: ["type": "service_account", "client_email": "a@b", "private_key": "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"])
        }
        #expect(throws: GCPAuthError.unsupportedCredentials("external_account")) {
            try GoogleCredentials(json: ["type": "external_account"])
        }
        #expect(throws: GCPAuthError.credentialsNotFound("/nonexistent/adc.json")) {
            try GoogleCredentials(file: URL(filePath: "/nonexistent/adc.json"))
        }
    }

    // MARK: Integration

    @MainActor
    func integration(_ handler: @escaping StubProtocol.Handler) throws -> (GCPIntegration, URL) {
        let file = FileManager.default.temporaryDirectory.appending(path: "gcp-adc-\(UUID().uuidString).json")
        try authorizedUser.data().write(to: file)
        let session = StubProtocol.session(handler)
        return (GCPIntegration(credentialsPath: file.path, session: session), file)
    }

    @MainActor
    @Test func metadataAndExports() throws {
        let (gcp, file) = try integration { _, _ in (200, tokenResponse) }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(gcp.id == "gcp")
        #expect(gcp.layer == .integration)
        #expect(gcp.metadata.version == "1.2.0")
        #expect(gcp.metadata.category == .cloud)
        #expect(gcp.metadata.author == .dash)
        #expect(gcp.metadata.homepage == "https://github.com/sessaidi/dash")
        #expect(gcp.isConnected)
        #expect(gcp.exports["credentialsFile"]?.string == file.path)
        #expect(gcp.exports["account"] == .null)
        let connection = try #require(gcp.connection)
        #expect(connection.baseURL.absoluteString == "https://www.googleapis.com")
        #expect(connection.hosts == [".googleapis.com"])
        #expect(Set(gcp.tools.map(\.name)) == ["gcp_api_get", "gcp_list_projects", "gcp_logs_query", "gcp_metrics_query"])
        #expect(GCPPlugin.makeExtensions().first?.id == "gcp")
    }

    @MainActor
    @Test func missingCredentialsFail() {
        let gcp = GCPIntegration(credentialsPath: "/nonexistent/key.json", session: StubProtocol.session { _, _ in (500, Data()) })
        #expect(!gcp.isConnected)
        #expect(gcp.connection == nil)
        guard case .failed(let message) = gcp.connectionState else { Issue.record("expected failure"); return }
        #expect(message.contains("/nonexistent/key.json"))
    }

    @MainActor
    @Test func verifyReadsEmailFromTokenInfo() async throws {
        let (gcp, file) = try integration { request, _ in
            request.url?.path() == "/tokeninfo" ? (200, json(["email": "me@example.com"])) : (200, tokenResponse)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        await gcp.verify()
        #expect(gcp.account == "me@example.com")
        #expect(gcp.connectionState == .connected("Signed in as me@example.com"))
        #expect(gcp.exports["account"]?.string == "me@example.com")
        let info = try #require(StubProtocol.requests.last)
        #expect(info.request.url?.query() == nil)
        #expect(formFields(info.body)["access_token"] == "ya29.test")
    }

    @MainActor
    @Test func signAddsBearer() async throws {
        let (gcp, file) = try integration { _, _ in (200, tokenResponse) }
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = try #require(gcp.connection)
        let signed = try await connection.authorize(URLRequest(url: URL(string: "https://compute.googleapis.com/compute/v1/projects/p")!))
        #expect(signed.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test")
    }

    @MainActor
    @Test func apiGetAllowsOnlyGoogleAPIs() async throws {
        let (gcp, file) = try integration { request, _ in
            request.url?.host() == "oauth2.googleapis.com" ? (200, tokenResponse) : (200, json(["items": [1, 2]]))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let tool = try #require(gcp.tools.first { $0.name == "gcp_api_get" })
        for url in ["https://evil.com/x", "http://compute.googleapis.com/v1", "https://googleapis.com.evil.com/", "https://evilgoogleapis.com/", "not a url"] {
            await #expect(throws: ToolError("Only https://*.googleapis.com URLs are allowed."), "\(url)") {
                try await tool.run(["url": .string(url)])
            }
        }
        #expect(StubProtocol.requests.isEmpty)

        let result = try await tool.run(["url": "https://container.googleapis.com/v1/projects/p/locations/-/clusters"])
        #expect(result == ["items": [1, 2]])
        let call = try #require(StubProtocol.requests.last)
        #expect(call.request.httpMethod == "GET")
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test")
    }

    @MainActor
    @Test func apiGetTruncatesLargeResponses() async throws {
        let big = Data(String(repeating: "a", count: 150_000).utf8)
        let (gcp, file) = try integration { request, _ in
            request.url?.host() == "oauth2.googleapis.com" ? (200, tokenResponse) : (200, big)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try #require(try await gcp.apiGet("https://www.googleapis.com/storage/v1/b").string)
        #expect(text.hasPrefix(String(repeating: "a", count: 100_000) + "\n[truncated]"))
        #expect(text.count == 100_000 + "\n[truncated]".count)
    }

    @MainActor
    @Test func listProjectsFollowsPages() async throws {
        let (gcp, file) = try integration { request, _ in
            guard request.url?.host() == "cloudresourcemanager.googleapis.com" else { return (200, tokenResponse) }
            if request.url?.query()?.contains("pageToken=next") == true {
                return (200, json(["projects": [["projectId": "b", "name": "B", "lifecycleState": "DELETE_REQUESTED", "projectNumber": "2"]]]))
            }
            return (200, json(["projects": [["projectId": "a", "name": "A", "lifecycleState": "ACTIVE"]], "nextPageToken": "next"]))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let tool = try #require(gcp.tools.first { $0.name == "gcp_list_projects" })
        let result = try await tool.run([:])
        #expect(result["projects"] == [
            ["projectId": "a", "name": "A", "state": "ACTIVE"],
            ["projectId": "b", "name": "B", "state": "DELETE_REQUESTED"],
        ])
        let calls = StubProtocol.requests.filter { $0.request.url?.host() == "cloudresourcemanager.googleapis.com" }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.request.url?.path() == "/v1/projects" && $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.test" })
    }
}
