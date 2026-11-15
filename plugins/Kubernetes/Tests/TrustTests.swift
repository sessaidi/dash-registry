import Foundation
import Security
import Testing

@Suite("TLS trust and client identities")
struct TrustTests {
    static func certificate(_ pem: String) throws -> SecCertificate {
        let der = try #require(PEM.certificates(Data(pem.utf8)).first)
        return try #require(SecCertificateCreateWithData(nil, der as CFData))
    }

    static func serverTrust() throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates([try certificate(Fixtures.serverCrt)] as CFArray, SecPolicyCreateBasicX509(), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test func pinnedCAAcceptsItsServer() throws {
        let trust = KubeTrust(anchors: [try Self.certificate(Fixtures.caCrt)], insecure: false, serverName: nil, identity: nil)
        #expect(trust.evaluate(try Self.serverTrust(), host: "kube.test", at: Fixtures.verifyDate))
        #expect(trust.evaluate(try Self.serverTrust(), host: "127.0.0.1", at: Fixtures.verifyDate))
    }

    @Test func pinnedCARejectsWrongHostAndOtherCA() throws {
        let trust = KubeTrust(anchors: [try Self.certificate(Fixtures.caCrt)], insecure: false, serverName: nil, identity: nil)
        #expect(!trust.evaluate(try Self.serverTrust(), host: "evil.test", at: Fixtures.verifyDate))
        let other = KubeTrust(anchors: [try Self.certificate(Fixtures.otherCrt)], insecure: false, serverName: nil, identity: nil)
        #expect(!other.evaluate(try Self.serverTrust(), host: "kube.test", at: Fixtures.verifyDate))
    }

    @Test func tlsServerNameOverridesHost() throws {
        let trust = KubeTrust(anchors: [try Self.certificate(Fixtures.caCrt)], insecure: false, serverName: "kube.test", identity: nil)
        #expect(trust.evaluate(try Self.serverTrust(), host: "10.0.0.1", at: Fixtures.verifyDate))
    }

    @Test func systemRootsDontTrustPrivateCA() throws {
        let trust = KubeTrust(anchors: [], insecure: false, serverName: "kube.test", identity: nil)
        #expect(!trust.evaluate(try Self.serverTrust(), host: "kube.test", at: Fixtures.verifyDate))
    }

    @Test(arguments: [
        (Fixtures.clientRsaCrt, Fixtures.clientRsaKey), (Fixtures.clientRsaCrt, Fixtures.clientRsaPk8),
        (Fixtures.clientEcCrt, Fixtures.clientEcKey), (Fixtures.clientEcCrt, Fixtures.clientEcPk8),
    ])
    func clientIdentities(certificate: String, key: String) throws {
        let (identity, intermediates) = try ClientIdentity.make(certificate: Data(certificate.utf8), key: Data(key.utf8))
        #expect(intermediates.isEmpty)
        var copied: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &copied) == errSecSuccess)
        #expect(copied.map { SecCertificateCopyData($0) as Data } == PEM.certificates(Data(certificate.utf8)).first)
        // The key really signs.
        var privateKey: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess)
        let algorithm: SecKeyAlgorithm = certificate == Fixtures.clientEcCrt ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        let signature = SecKeyCreateSignature(try #require(privateKey), algorithm, Data("hello".utf8) as CFData, nil)
        #expect(signature != nil)
    }

    @Test func chainCertificatesAreIntermediates() throws {
        let (_, intermediates) = try ClientIdentity.make(certificate: Data((Fixtures.clientRsaCrt + "\n" + Fixtures.caCrt).utf8), key: Data(Fixtures.clientRsaKey.utf8))
        #expect(intermediates.count == 1)
    }

    @Test func badKeysAreExplained() {
        #expect(ClientIdentity.problem(certificate: Data(Fixtures.clientRsaCrt.utf8), key: Data("nope".utf8))?.contains("isn't a PEM private key") == true)
        #expect(ClientIdentity.problem(certificate: Data(Fixtures.clientRsaCrt.utf8),
                                       key: Data("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----".utf8))?.contains("encrypted") == true)
        #expect(ClientIdentity.problem(certificate: Data(Fixtures.clientRsaCrt.utf8), key: Data(Fixtures.clientRsaKey.utf8)) == nil)
    }

    @Test func pkcs8AlgorithmIsRead() throws {
        let der = try #require(PEM.blocks(Data(Fixtures.clientRsaPk8.utf8)).first?.der)
        #expect(try DER.parsePKCS8(der).algorithm == DER.rsaEncryption)
        let ec = try #require(PEM.blocks(Data(Fixtures.clientEcPk8.utf8)).first?.der)
        #expect(try DER.parsePKCS8(ec).algorithm == DER.ecPublicKey)
    }

    @Test func sessionCarriesIdentityForClientCertificateContexts() throws {
        let context = try KubeConfig(yaml: Kubeconfigs.kind).resolve()
        let trust = try KubeTrust(context: context)
        #expect(trust.identity != nil)
        #expect(trust.anchors.count == 1)
        #expect(!trust.insecure)
    }
}
