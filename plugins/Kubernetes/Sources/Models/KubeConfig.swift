import DashKit
import Foundation
import Security

/// A parsed kubeconfig: clusters, users and contexts, with file references resolved
/// against the kubeconfig's directory (as kubectl does).
struct KubeConfig: Equatable, Sendable {
    struct Cluster: Equatable, Sendable {
        var name: String
        var server: String
        /// PEM (or DER) bytes from `certificate-authority-data`.
        var certificateAuthorityData: Data?
        /// Absolute path from `certificate-authority`.
        var certificateAuthorityFile: String?
        var insecureSkipTLSVerify: Bool
        var tlsServerName: String?
        var proxyURL: String?
    }

    struct Exec: Equatable, Sendable {
        var command: String
        var args: [String]
        var env: [String: String]
        var apiVersion: String?

        /// The executable's file name ("gke-gcloud-auth-plugin" for "/usr/local/bin/gke-gcloud-auth-plugin").
        var program: String { (command as NSString).lastPathComponent }
    }

    struct AuthProvider: Equatable, Sendable {
        var name: String
        var config: [String: String]
    }

    struct User: Equatable, Sendable {
        var name: String
        var token: String?
        var tokenFile: String?
        var clientCertificateData: Data?
        var clientCertificateFile: String?
        var clientKeyData: Data?
        var clientKeyFile: String?
        var username: String?
        var password: String?
        var exec: Exec?
        var authProvider: AuthProvider?
    }

    struct Context: Equatable, Sendable {
        var name: String
        var cluster: String
        var user: String
        var namespace: String?
    }

    var clusters: [Cluster]
    var users: [User]
    var contexts: [Context]
    var currentContext: String?

    struct LoadError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    init(clusters: [Cluster] = [], users: [User] = [], contexts: [Context] = [], currentContext: String? = nil) {
        self.clusters = clusters
        self.users = users
        self.contexts = contexts
        self.currentContext = currentContext
    }

    /// Parses kubeconfig YAML. Relative paths resolve against `directory`.
    init(yaml: String, directory: URL? = nil) throws {
        let root = try YAML.parse(yaml)
        guard root.object != nil || root == .null else { throw LoadError(message: "kubeconfig is not a mapping") }

        func path(_ value: JSONValue?) -> String? {
            guard let text = value?.scalarText, !text.isEmpty else { return nil }
            let expanded = (text as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") || directory == nil { return expanded }
            return directory!.appending(path: expanded).standardizedFileURL.path
        }
        func data(_ value: JSONValue?, field: String, entry: String) throws -> Data? {
            guard let text = value?.scalarText, !text.isEmpty else { return nil }
            guard let data = Data(base64Encoded: text.filter { !$0.isWhitespace }) else {
                throw LoadError(message: "\(field) of \(entry) is not valid base64")
            }
            return data
        }
        func named(_ key: String) -> [(String, JSONValue)] {
            (root[key]?.array ?? []).compactMap { item in
                guard let name = item["name"]?.scalarText else { return nil }
                return (name, item[String(key.dropLast())] ?? .null)
            }
        }

        clusters = try named("clusters").map { name, body in
            Cluster(
                name: name, server: body["server"]?.scalarText ?? "",
                certificateAuthorityData: try data(body["certificate-authority-data"], field: "certificate-authority-data", entry: "cluster \(name)"),
                certificateAuthorityFile: path(body["certificate-authority"]),
                insecureSkipTLSVerify: body["insecure-skip-tls-verify"]?.flag ?? false,
                tlsServerName: body["tls-server-name"]?.scalarText, proxyURL: body["proxy-url"]?.scalarText)
        }
        users = try named("users").map { name, body in
            var exec: Exec?
            if let spec = body["exec"], spec.object != nil {
                var env: [String: String] = [:]
                for item in spec["env"]?.array ?? [] {
                    if let key = item["name"]?.scalarText { env[key] = item["value"]?.scalarText ?? "" }
                }
                exec = Exec(command: spec["command"]?.scalarText ?? "", args: (spec["args"]?.array ?? []).compactMap(\.scalarText),
                            env: env, apiVersion: spec["apiVersion"]?.scalarText)
            }
            var provider: AuthProvider?
            if let spec = body["auth-provider"], let providerName = spec["name"]?.scalarText {
                provider = AuthProvider(name: providerName, config: (spec["config"]?.object ?? [:]).compactMapValues(\.scalarText))
            }
            return User(
                name: name, token: body["token"]?.scalarText.flatMap { $0.isEmpty ? nil : $0 }, tokenFile: path(body["tokenFile"]),
                clientCertificateData: try data(body["client-certificate-data"], field: "client-certificate-data", entry: "user \(name)"),
                clientCertificateFile: path(body["client-certificate"]),
                clientKeyData: try data(body["client-key-data"], field: "client-key-data", entry: "user \(name)"),
                clientKeyFile: path(body["client-key"]),
                username: body["username"]?.scalarText, password: body["password"]?.scalarText,
                exec: exec, authProvider: provider)
        }
        contexts = named("contexts").map { name, body in
            Context(name: name, cluster: body["cluster"]?.scalarText ?? "", user: body["user"]?.scalarText ?? "",
                    namespace: body["namespace"]?.scalarText.flatMap { $0.isEmpty ? nil : $0 })
        }
        currentContext = root["current-context"]?.scalarText.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `$KUBECONFIG`'s first entry, else ~/.kube/config.
    static func defaultPath(environment: [String: String] = ShellEnvironment.current, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let list = environment["KUBECONFIG"],
           let first = list.split(separator: ":").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return URL(filePath: (first as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".kube/config")
    }

    static func load(_ url: URL) throws -> KubeConfig {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            throw LoadError(message: "Can't read kubeconfig at \(url.path): \((error as NSError).localizedDescription)")
        }
        return try KubeConfig(yaml: text, directory: url.deletingLastPathComponent())
    }

    func context(_ name: String) -> Context? { contexts.first { $0.name == name } }
    func cluster(_ name: String) -> Cluster? { clusters.first { $0.name == name } }
    func user(_ name: String) -> User? { users.first { $0.name == name } }
}

// MARK: - Resolution

/// How requests to a context authenticate.
enum KubeAuth: Equatable, Sendable {
    case none
    case bearer(String)
    /// Re-read on every request, as client-go does (projected tokens rotate).
    case tokenFile(String)
    case basic(username: String, password: String)
    /// `gke-gcloud-auth-plugin` (or the legacy `gcp` auth provider): a Google token from the `gcp` integration.
    case gcp
    case unsupported(String)

    var isSupported: Bool { if case .unsupported = self { return false }; return true }

    var summary: String {
        switch self {
        case .none: "no credentials"
        case .bearer: "bearer token"
        case .tokenFile(let path): "token file \((path as NSString).lastPathComponent)"
        case .basic(let username, _): "basic auth (\(username))"
        case .gcp: "Google Cloud (gke-gcloud-auth-plugin)"
        case .unsupported(let reason): reason
        }
    }
}

/// Everything needed to talk to one context's API server.
struct ResolvedContext: Equatable, Sendable {
    var name: String
    var server: URL
    var namespace: String
    var auth: KubeAuth
    /// DER certificates to anchor trust to; empty = system trust.
    var certificateAuthorities: [Data]
    var insecure: Bool
    var tlsServerName: String?
    /// PEM/DER client certificate and key (client certificate auth), if any.
    var clientCertificate: Data?
    var clientKey: Data?
}

extension KubeConfig {
    struct ResolveError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Resolves a context (nil = current-context) into a server, trust and auth.
    /// Unsupported auth is reported in `auth`, not thrown, so Settings can explain it.
    func resolve(_ name: String? = nil, readFile: (String) throws -> Data = { try Data(contentsOf: URL(filePath: $0)) }) throws -> ResolvedContext {
        guard let contextName = name ?? currentContext else {
            throw ResolveError(message: contexts.isEmpty ? "The kubeconfig has no contexts." : "No current-context; pick one in Settings.")
        }
        guard let context = context(contextName) else { throw ResolveError(message: "Context \"\(contextName)\" isn't in the kubeconfig.") }
        guard let cluster = cluster(context.cluster) else {
            throw ResolveError(message: "Context \"\(contextName)\" refers to missing cluster \"\(context.cluster)\".")
        }
        guard let server = URL(string: cluster.server), let scheme = server.scheme, ["https", "http"].contains(scheme), server.host() != nil else {
            throw ResolveError(message: "Cluster \"\(cluster.name)\" has no valid server URL (\"\(cluster.server)\").")
        }
        let user = context.user.isEmpty ? nil : self.user(context.user)
        if !context.user.isEmpty, user == nil {
            throw ResolveError(message: "Context \"\(contextName)\" refers to missing user \"\(context.user)\".")
        }

        var authorities: [Data] = []
        if !cluster.insecureSkipTLSVerify {
            if let data = cluster.certificateAuthorityData {
                authorities = PEM.certificates(data)
            } else if let file = cluster.certificateAuthorityFile {
                let data: Data
                do { data = try readFile(file) } catch { throw ResolveError(message: "Can't read certificate-authority \(file).") }
                authorities = PEM.certificates(data)
            }
            if (cluster.certificateAuthorityData != nil || cluster.certificateAuthorityFile != nil), authorities.isEmpty {
                throw ResolveError(message: "Cluster \"\(cluster.name)\" has a certificate authority Dash can't read (expected PEM certificates).")
            }
        }

        var resolved = ResolvedContext(
            name: contextName, server: server, namespace: context.namespace ?? "default", auth: .none,
            certificateAuthorities: authorities, insecure: cluster.insecureSkipTLSVerify, tlsServerName: cluster.tlsServerName)
        guard let user else { return resolved }

        if user.clientCertificateData != nil || user.clientCertificateFile != nil {
            do {
                resolved.clientCertificate = try user.clientCertificateData ?? readFile(user.clientCertificateFile!)
                resolved.clientKey = try user.clientKeyData ?? user.clientKeyFile.map(readFile)
            } catch {
                resolved.auth = .unsupported("Can't read the client certificate or key of user \"\(user.name)\".")
                return resolved
            }
            if resolved.clientKey == nil {
                resolved.auth = .unsupported("User \"\(user.name)\" has a client certificate but no client key.")
                return resolved
            }
            if let problem = ClientIdentity.problem(certificate: resolved.clientCertificate!, key: resolved.clientKey!) {
                resolved.auth = .unsupported("Client certificate of user \"\(user.name)\" is unsupported: \(problem)")
                return resolved
            }
        }

        if let exec = user.exec {
            if exec.program == "gke-gcloud-auth-plugin" {
                resolved.auth = .gcp
            } else {
                resolved.auth = .unsupported(
                    "User \"\(user.name)\" gets credentials by running \"\(exec.program)\"; Dash doesn't run programs. Only gke-gcloud-auth-plugin is supported (through the Google Cloud integration). Use a token or a client certificate instead.")
            }
        } else if let provider = user.authProvider {
            switch provider.name {
            case "gcp": resolved.auth = .gcp
            case "oidc":
                if let token = provider.config["id-token"], !token.isEmpty { resolved.auth = .bearer(token) } else {
                    resolved.auth = .unsupported("User \"\(user.name)\" uses the oidc auth provider without an id-token.")
                }
            default:
                resolved.auth = .unsupported("User \"\(user.name)\" uses the \"\(provider.name)\" auth provider, which Dash doesn't support.")
            }
        } else if let tokenFile = user.tokenFile {
            resolved.auth = .tokenFile(tokenFile)
        } else if let token = user.token {
            resolved.auth = .bearer(token)
        } else if let username = user.username, let password = user.password {
            resolved.auth = .basic(username: username, password: password)
        }
        return resolved
    }
}

// MARK: - PEM

enum PEM {
    struct Block: Equatable {
        let label: String
        let der: Data
    }

    /// PEM blocks in `data`; if `data` isn't PEM at all, it is returned as one unlabeled DER block.
    static func blocks(_ data: Data) -> [Block] {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("-----BEGIN ") else { return data.isEmpty ? [] : [Block(label: "", der: data)] }
        var blocks: [Block] = []
        var label: String?
        var body = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                body = ""
            } else if line.hasPrefix("-----END "), let current = label {
                if let der = Data(base64Encoded: body) { blocks.append(Block(label: current, der: der)) }
                label = nil
            } else if label != nil, !line.contains(":") {
                body += line
            }
        }
        return blocks
    }

    /// DER certificates (PEM bundle or a single DER certificate).
    static func certificates(_ data: Data) -> [Data] {
        blocks(data).filter { $0.label == "CERTIFICATE" || $0.label.isEmpty }.map(\.der)
            .filter { SecCertificateCreateWithData(nil, $0 as CFData) != nil }
    }
}
