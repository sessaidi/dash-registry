import DashKit
import DashKitUI
import CryptoKit
import Foundation

struct AWSCredentials: Sendable, Equatable {
    let accessKeyID: String
    let secretAccessKey: String
    var sessionToken: String?
    var expiration: Date?
}

/// Reads ~/.aws/config and ~/.aws/credentials in-process. Supports static keys and IAM Identity
/// Center (SSO) profiles via the token `aws sso login` caches. `credential_process` is not
/// supported, since it means executing a program.
actor AWSCredentialsProvider {
    struct Profile: Equatable, Sendable {
        let name: String
        var values: [String: String]
        var region: String? { values["region"] }
        var isSSO: Bool { values["sso_session"] != nil || values["sso_start_url"] != nil }
    }

    let home: URL
    let session: URLSession
    private var cache: [String: AWSCredentials] = [:]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession = .shared) {
        self.home = home
        self.session = session
    }

    nonisolated static func parseINI(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                sections[current!, default: [:]] = sections[current!] ?? [:]
            } else if let current, let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[current]?[key] = value
            }
        }
        return sections
    }

    private func read(_ file: String) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: home.appending(path: ".aws/\(file)"), encoding: .utf8) else { return [:] }
        return Self.parseINI(text)
    }

    /// Profiles from config ("[profile x]" / "[default]") merged with credentials ("[x]").
    func profiles() -> [Profile] {
        var merged: [String: [String: String]] = [:]
        for (section, values) in read("config") {
            let name = section == "default" ? "default" : section.hasPrefix("profile ") ? String(section.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
            if let name { merged[name, default: [:]].merge(values) { _, new in new } }
        }
        for (name, values) in read("credentials") { merged[name, default: [:]].merge(values) { _, new in new } }
        return merged.map { Profile(name: $0.key, values: $0.value) }.sorted { $0.name < $1.name }
    }

    func profile(_ name: String) throws -> Profile {
        guard let profile = profiles().first(where: { $0.name == name }) else { throw ToolError("No AWS profile \"\(name)\" in ~/.aws/config or ~/.aws/credentials.") }
        return profile
    }

    func credentials(profile name: String) async throws -> AWSCredentials {
        if let cached = cache[name], cached.expiration.map({ $0 > Date().addingTimeInterval(120) }) ?? true { return cached }
        let profile = try profile(name)
        let resolved: AWSCredentials
        if let key = profile.values["aws_access_key_id"], let secret = profile.values["aws_secret_access_key"] {
            resolved = AWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: profile.values["aws_session_token"])
        } else if profile.isSSO {
            resolved = try await ssoCredentials(profile)
        } else if profile.values["credential_process"] != nil {
            throw ToolError("Profile \(name) uses credential_process, which Dash doesn't run. Use an SSO or key-based profile.")
        } else if profile.values["role_arn"] != nil {
            throw ToolError("Profile \(name) assumes a role; role chaining isn't supported yet. Use the source or an SSO profile.")
        } else {
            throw ToolError("Profile \(name) has no credentials Dash can use.")
        }
        cache[name] = resolved
        return resolved
    }

    /// IAM Identity Center: the cached SSO access token -> short-lived role credentials.
    private func ssoCredentials(_ profile: Profile) async throws -> AWSCredentials {
        var settings = profile.values
        if let sessionName = settings["sso_session"], let session = read("config")["sso-session \(sessionName)"] {
            settings.merge(session) { current, _ in current }
        }
        guard let account = settings["sso_account_id"], let role = settings["sso_role_name"], let region = settings["sso_region"] else {
            throw ToolError("SSO profile \(profile.name) needs sso_account_id, sso_role_name and sso_region.")
        }
        // The cache file is named after sha1(session name) for sso-session configs, sha1(start URL) otherwise.
        let key = settings["sso_session"] ?? settings["sso_start_url"] ?? ""
        let file = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let data = try? Data(contentsOf: home.appending(path: ".aws/sso/cache/\(file).json")),
              let token = try? JSONValue.parse(data), let accessToken = token["accessToken"]?.string else {
            throw ToolError("No cached SSO login for \(profile.name). Run `aws sso login --profile \(profile.name)` once in a terminal.")
        }
        if let expires = token["expiresAt"]?.string.flatMap(ISO8601DateFormatter.date), expires < Date() {
            throw ToolError("The SSO login for \(profile.name) expired. Run `aws sso login --profile \(profile.name)` again.")
        }
        var components = URLComponents(string: "https://portal.sso.\(region).amazonaws.com/federation/credentials")!
        components.queryItems = [URLQueryItem(name: "account_id", value: account), URLQueryItem(name: "role_name", value: role)]
        var request = URLRequest(url: components.url!)
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        let (body, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let credentials = try? JSONValue.parse(body)["roleCredentials"],
              let id = credentials["accessKeyId"]?.string, let secret = credentials["secretAccessKey"]?.string else {
            throw ToolError("AWS SSO refused the role credentials for \(profile.name) (\((response as? HTTPURLResponse)?.statusCode ?? 0)). Run `aws sso login` again.")
        }
        return AWSCredentials(accessKeyID: id, secretAccessKey: secret, sessionToken: credentials["sessionToken"]?.string,
                              expiration: credentials["expiration"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    func clearCache() { cache = [:] }
}

/// AWS Signature Version 4.
enum SigV4 {
    /// "ec2.eu-west-1.amazonaws.com" -> ("ec2", "eu-west-1"); global endpoints sign in us-east-1.
    static func scope(for host: String, defaultRegion: String) -> (service: String, region: String) {
        let labels = host.replacingOccurrences(of: ".amazonaws.com", with: "").split(separator: ".").map(String.init)
        let service = labels.first ?? ""
        if labels.count >= 2, labels[1].contains("-") { return (service, labels[1]) }
        if ["iam", "sts", "route53", "cloudfront", "organizations"].contains(service) && labels.count == 1 { return (service, "us-east-1") }
        return (service, defaultRegion)
    }

    static func sign(_ request: URLRequest, credentials: AWSCredentials, service: String, region: String, date: Date = Date()) -> URLRequest {
        var request = request
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        let day = String(amzDate.prefix(8))
        let url = request.url!
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

        var headers: [String: String] = ["host": url.host()! + (url.port.map { ":\($0)" } ?? "")]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower == "content-type" || lower.hasPrefix("x-amz-") { headers[lower] = value.trimmingCharacters(in: .whitespaces) }
        }
        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonicalHeaders = headers.keys.sorted().map { "\($0):\(headers[$0]!)\n" }.joined()
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(String, String)] = items.map { (encode($0.name), encode($0.value ?? "")) }
        let sorted = pairs.sorted { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        let query = sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let payloadHash = hex(SHA256.hash(data: request.httpBody ?? Data()))
        let canonical = [request.httpMethod ?? "GET", path.isEmpty ? "/" : path, query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let credentialScope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, credentialScope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(credentials.secretAccessKey)".utf8))
        for part in [day, region, service, "aws4_request"] { key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key))) }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
        return request
    }

    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? text
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
