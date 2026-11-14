import DashKit
import Foundation
import Security

/// Errors reading Google credentials or exchanging them for tokens.
enum GCPAuthError: LocalizedError, Equatable {
    case credentialsNotFound(String)
    case unsupportedCredentials(String)
    case invalidPrivateKey
    case oauth(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound(let path): "No Google credentials at \(path). Run `gcloud auth application-default login` once, or choose a service-account key."
        case .unsupportedCredentials(let type): "Unsupported Google credentials type \"\(type)\"."
        case .invalidPrivateKey: "The service-account private key could not be read."
        case .oauth(401, _): "Google OAuth rejected the credentials (401). Sign in again."
        case .oauth(let status, let message): "Google OAuth error \(status): \(message)"
        }
    }
}

/// Application Default Credentials read in-process: nothing is executed.
///
/// Supports the two file formats `gcloud` writes:
/// - `authorized_user` (`gcloud auth application-default login`): refresh-token grant;
/// - `service_account` (a JSON key): a JWT signed locally with RS256, exchanged for a token.
///
/// Tokens are cached until a minute before expiry; concurrent callers share one refresh.
actor GoogleCredentials {
    static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// `$GOOGLE_APPLICATION_CREDENTIALS`, else gcloud's ADC file in `$CLOUDSDK_CONFIG` or
    /// `~/.config/gcloud` (variables from your shell config count too).
    static var defaultPath: URL {
        if let path = ShellEnvironment.value("GOOGLE_APPLICATION_CREDENTIALS"), !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        let config = ShellEnvironment.value("CLOUDSDK_CONFIG").map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/gcloud")
        return config.appending(path: "application_default_credentials.json")
    }

    enum Kind {
        case authorizedUser(clientID: String, clientSecret: String, refreshToken: String)
        case serviceAccount(email: String, privateKey: SecKey, tokenURI: URL)
    }

    let kind: Kind
    /// The service-account email, when known from the file.
    nonisolated let account: String?
    private let session: URLSession
    private var cached: (token: String, expiry: Date)?
    private var refreshing: Task<(String, Date), any Error>?

    init(file: URL = GoogleCredentials.defaultPath, session: URLSession = .shared) throws {
        guard let data = try? Data(contentsOf: file) else { throw GCPAuthError.credentialsNotFound(file.path) }
        guard let json = try? JSONValue.parse(data) else { throw GCPAuthError.unsupportedCredentials("not JSON") }
        try self.init(json: json, session: session)
    }

    init(json: JSONValue, session: URLSession = .shared) throws {
        self.session = session
        switch json["type"]?.string {
        case "authorized_user":
            guard let id = json["client_id"]?.string, let secret = json["client_secret"]?.string, let refresh = json["refresh_token"]?.string else {
                throw GCPAuthError.unsupportedCredentials("authorized_user without client_id/client_secret/refresh_token")
            }
            kind = .authorizedUser(clientID: id, clientSecret: secret, refreshToken: refresh)
            account = nil
        case "service_account":
            guard let email = json["client_email"]?.string, let pem = json["private_key"]?.string else {
                throw GCPAuthError.unsupportedCredentials("service_account without client_email/private_key")
            }
            kind = .serviceAccount(
                email: email, privateKey: try RSAKey.privateKey(pem: pem),
                tokenURI: json["token_uri"]?.string.flatMap(URL.init(string:)) ?? Self.tokenURL)
            account = email
        default:
            throw GCPAuthError.unsupportedCredentials(json["type"]?.string ?? "missing")
        }
    }

    /// A valid access token, from the cache or a fresh grant.
    func accessToken() async throws -> String {
        if let cached, cached.expiry > Date().addingTimeInterval(60) { return cached.token }
        if let refreshing { return try await refreshing.value.0 }
        let request = try tokenRequest()
        let session = session
        let task = Task { try await Self.exchange(request, session: session) }
        refreshing = task
        defer { refreshing = nil }
        let (token, expiry) = try await task.value
        cached = (token, expiry)
        return token
    }

    /// Drops the cached token (after a 401, or when credentials change).
    func invalidate() { cached = nil }

    func tokenRequest(now: Date = Date()) throws -> URLRequest {
        var request: URLRequest
        switch kind {
        case .authorizedUser(let id, let secret, let refresh):
            request = URLRequest(url: Self.tokenURL)
            request.httpBody = Self.form([
                "grant_type": "refresh_token", "client_id": id, "client_secret": secret, "refresh_token": refresh,
            ])
        case .serviceAccount(let email, let key, let tokenURI):
            request = URLRequest(url: tokenURI)
            let assertion = try JWT.sign(
                claims: ["iss": .string(email), "scope": .string(Self.cloudPlatformScope), "aud": .string(tokenURI.absoluteString)],
                key: key, now: now)
            request.httpBody = Self.form(["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion])
        }
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func exchange(_ request: URLRequest, session: URLSession) async throws -> (String, Date) {
        let (data, response) = try await session.data(for: request)
        let json = try? JSONValue.parse(data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let token = json?["access_token"]?.string else {
            throw GCPAuthError.oauth(status: status, message: json?["error_description"]?.string ?? json?["error"]?.string ?? "no access_token")
        }
        return (token, Date().addingTimeInterval(json?["expires_in"]?.double ?? 3600))
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

enum JWT {
    static func sign(claims: [String: JSONValue], key: SecKey, now: Date = Date()) throws -> String {
        var payload = claims
        let issued = Int(now.timeIntervalSince1970)
        payload["iat"] = .number(Double(issued))
        payload["exp"] = .number(Double(issued + 3600))
        let header: JSONValue = ["alg": "RS256", "typ": "JWT"]
        let input = base64URL(Data(header.jsonString().utf8)) + "." + base64URL(Data(JSONValue.object(payload).jsonString().utf8))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data? else {
            throw GCPAuthError.invalidPrivateKey
        }
        return input + "." + base64URL(signature)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RSAKey {
    /// Reads a PKCS#8 ("BEGIN PRIVATE KEY", as in Google key files) or PKCS#1 PEM RSA key.
    static func privateKey(pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw GCPAuthError.invalidPrivateKey }
        let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try unwrapPKCS8(der)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { throw GCPAuthError.invalidPrivateKey }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(bytes: [UInt8](der))
        let outer = try reader.element(tag: 0x30)
        var inner = DERReader(bytes: outer)
        _ = try inner.element(tag: 0x02)
        _ = try inner.element(tag: 0x30)
        return Data(try inner.element(tag: 0x04))
    }

    struct DERReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func element(tag: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == tag else { throw GCPAuthError.invalidPrivateKey }
            offset += 1
            guard offset < bytes.count else { throw GCPAuthError.invalidPrivateKey }
            var length = Int(bytes[offset])
            offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count <= 4, offset + count <= bytes.count else { throw GCPAuthError.invalidPrivateKey }
                length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
                offset += count
            }
            guard offset + length <= bytes.count else { throw GCPAuthError.invalidPrivateKey }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }
    }
}
