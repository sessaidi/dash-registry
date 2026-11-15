import CryptoKit
import Foundation
import Security

/// TLS for one context: trust anchored to the cluster CA (or the system, or nothing when
/// `insecure-skip-tls-verify` is set) and, for client-certificate users, an in-memory identity.
final class KubeTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    // Immutable after init; Security types are thread-safe but not marked Sendable.
    let anchors: [SecCertificate]
    let insecure: Bool
    let serverName: String?
    let identity: SecIdentity?
    let intermediates: [SecCertificate]

    init(anchors: [SecCertificate], insecure: Bool, serverName: String?, identity: SecIdentity?, intermediates: [SecCertificate] = []) {
        self.anchors = anchors
        self.insecure = insecure
        self.serverName = serverName
        self.identity = identity
        self.intermediates = intermediates
    }

    convenience init(context: ResolvedContext) throws {
        let anchors = context.certificateAuthorities.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var identity: SecIdentity?
        var intermediates: [SecCertificate] = []
        if context.auth.isSupported, let certificate = context.clientCertificate, let key = context.clientKey {
            (identity, intermediates) = try ClientIdentity.make(certificate: certificate, key: key)
        }
        self.init(anchors: anchors, insecure: context.insecure, serverName: context.tlsServerName, identity: identity, intermediates: intermediates)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            if insecure { return (.useCredential, URLCredential(trust: trust)) }
            if anchors.isEmpty, serverName == nil { return (.performDefaultHandling, nil) }
            return evaluate(trust, host: space.host) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(identity: identity, certificates: intermediates.isEmpty ? nil : intermediates, persistence: .forSession))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    /// True if `trust` chains to the cluster CA (or the system roots when there's none)
    /// and the certificate names `tls-server-name` or the host.
    func evaluate(_ trust: SecTrust, host: String, at date: Date? = nil) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, (serverName ?? host) as CFString))
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// A session for a context. `configuration` lets tests install URLProtocol stubs.
    static func session(for context: ResolvedContext, configuration: URLSessionConfiguration = .ephemeral) throws -> URLSession {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Dash-Kubernetes/1.0"]
        return URLSession(configuration: configuration, delegate: try KubeTrust(context: context), delegateQueue: nil)
    }
}

// MARK: - Client certificates

/// Builds a TLS client identity from kubeconfig PEM data, entirely in memory (no keychain, no exec).
/// Keys: PKCS#1 RSA ("RSA PRIVATE KEY"), SEC1 EC ("EC PRIVATE KEY", P-256/384/521) and unencrypted PKCS#8 ("PRIVATE KEY").
enum ClientIdentity {
    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static func make(certificate: Data, key: Data) throws -> (SecIdentity, [SecCertificate]) {
        let certificates = PEM.certificates(certificate).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certificates.first else { throw Failure(message: "the client certificate isn't a PEM certificate.") }
        let privateKey = try self.privateKey(key)
        guard let identity = SecIdentityCreate(nil, leaf, privateKey) else {
            throw Failure(message: "the client key doesn't match the client certificate.")
        }
        return (identity, Array(certificates.dropFirst()))
    }

    /// nil when an identity can be built, else why not.
    static func problem(certificate: Data, key: Data) -> String? {
        do {
            _ = try make(certificate: certificate, key: key)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func privateKey(_ data: Data) throws -> SecKey {
        guard let block = PEM.blocks(data).first(where: { $0.label.hasSuffix("PRIVATE KEY") }) else {
            throw Failure(message: "the client key isn't a PEM private key.")
        }
        switch block.label {
        case "RSA PRIVATE KEY":
            return try secKey(block.der, type: kSecAttrKeyTypeRSA)
        case "EC PRIVATE KEY":
            return try secKey(try ecX963(sec1: block.der), type: kSecAttrKeyTypeECSECPrimeRandom)
        case "PRIVATE KEY":
            let info = try DER.parsePKCS8(block.der)
            switch info.algorithm {
            case DER.rsaEncryption: return try secKey(info.key, type: kSecAttrKeyTypeRSA)
            case DER.ecPublicKey: return try secKey(try ecX963(pkcs8: block.der), type: kSecAttrKeyTypeECSECPrimeRandom)
            default: throw Failure(message: "only RSA and ECDSA client keys are supported (key algorithm \(info.algorithm)).")
            }
        case "ENCRYPTED PRIVATE KEY":
            throw Failure(message: "encrypted client keys aren't supported.")
        default:
            throw Failure(message: "unsupported key type \"\(block.label)\".")
        }
    }

    static func secKey(_ data: Data, type: CFString) throws -> SecKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: type, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw Failure(message: "the client key couldn't be loaded (\(reason)).")
        }
        return key
    }

    /// 04 || X || Y || D, the form SecKeyCreateWithData takes for EC private keys.
    static func ecX963(sec1 der: Data) throws -> Data {
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return key.x963Representation }
        if let key = try? P384.Signing.PrivateKey(derRepresentation: der) { return key.x963Representation }
        if let key = try? P521.Signing.PrivateKey(derRepresentation: der) { return key.x963Representation }
        throw Failure(message: "only P-256, P-384 and P-521 EC client keys are supported.")
    }

    static func ecX963(pkcs8 der: Data) throws -> Data { try ecX963(sec1: der) }  // CryptoKit's DER init accepts both.
}

/// Just enough DER to unwrap a PKCS#8 PrivateKeyInfo.
enum DER {
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let ecPublicKey = "1.2.840.10045.2.1"

    struct Node {
        let tag: UInt8
        let content: Data
    }

    struct Malformed: Error {}

    /// Reads one TLV at `offset`, advancing it.
    static func read(_ data: Data, _ offset: inout Int) throws -> Node {
        let bytes = [UInt8](data)
        guard offset + 2 <= bytes.count else { throw Malformed() }
        let tag = bytes[offset]
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw Malformed() }
            length = bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { throw Malformed() }
        let content = Data(bytes[offset..<(offset + length)])
        offset += length
        return Node(tag: tag, content: content)
    }

    static func children(_ data: Data) throws -> [Node] {
        var offset = 0
        var nodes: [Node] = []
        while offset < data.count { nodes.append(try read(data, &offset)) }
        return nodes
    }

    static func oid(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return "" }
        var parts = [Int(first) / 40, Int(first) % 40]
        var value = 0
        for byte in bytes.dropFirst() {
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING privateKey, ... }
    static func parsePKCS8(_ der: Data) throws -> (algorithm: String, key: Data) {
        var offset = 0
        let outer = try read(der, &offset)
        guard outer.tag == 0x30 else { throw ClientIdentity.Failure(message: "the client key isn't valid PKCS#8.") }
        let fields = try children(outer.content)
        guard fields.count >= 3, fields[1].tag == 0x30, fields[2].tag == 0x04,
              let algorithm = try children(fields[1].content).first, algorithm.tag == 0x06 else {
            throw ClientIdentity.Failure(message: "the client key isn't valid PKCS#8.")
        }
        return (oid(algorithm.content), fields[2].content)
    }
}
