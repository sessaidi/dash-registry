import DashKit
import Foundation
import Testing

@Suite("kubeconfig")
struct KubeConfigTests {
    @Test func gkeContextUsesGoogleCloud() throws {
        let config = try KubeConfig(yaml: Kubeconfigs.gke)
        #expect(config.currentContext == "gke_acme-prod_us-central1_main")
        let user = try #require(config.users.first)
        #expect(user.exec?.program == "gke-gcloud-auth-plugin")
        #expect(user.exec?.apiVersion == "client.authentication.k8s.io/v1beta1")
        let resolved = try config.resolve()
        #expect(resolved.server.absoluteString == "https://34.123.45.67")
        #expect(resolved.auth == .gcp)
        #expect(resolved.namespace == "default")
        #expect(resolved.certificateAuthorities.count == 1)
        #expect(!resolved.insecure)
    }

    @Test func eksExecIsUnsupported() throws {
        let config = try KubeConfig(yaml: Kubeconfigs.eks)
        let user = try #require(config.users.first)
        #expect(user.name == "arn:aws:eks:us-west-2:123456789012:cluster/demo")
        #expect(user.exec?.command == "aws")
        #expect(user.exec?.args == ["--region", "us-west-2", "eks", "get-token", "--cluster-name", "demo", "--output", "json"])
        #expect(user.exec?.env == ["AWS_PROFILE": "prod"])
        let resolved = try config.resolve()
        #expect(resolved.server.host() == "ABCDEF0123456789.gr7.us-west-2.eks.amazonaws.com".lowercased() || resolved.server.host() == "ABCDEF0123456789.gr7.us-west-2.eks.amazonaws.com")
        guard case .unsupported(let reason) = resolved.auth else { Issue.record("expected unsupported"); return }
        #expect(reason.contains("aws"))
        #expect(reason.contains("doesn't run programs"))
    }

    @Test func kindClientCertificate() throws {
        let config = try KubeConfig(yaml: Kubeconfigs.kind)
        let resolved = try config.resolve()
        #expect(resolved.server.absoluteString == "https://127.0.0.1:6443")
        #expect(resolved.auth == .none)
        #expect(resolved.clientCertificate == Data(Fixtures.clientRsaCrt.utf8))
        #expect(resolved.clientKey == Data(Fixtures.clientRsaKey.utf8))
        #expect(resolved.auth.isSupported)
    }

    @Test func handWrittenTokens() throws {
        let url = try writeKubeconfig(Kubeconfigs.tokens, extraFiles: ["certs/staging-ca.crt": Fixtures.caCrt, "tokens/staging": "file-token\n"])
        let config = try KubeConfig.load(url)
        #expect(config.contexts.map(\.name) == ["dev", "staging", "legacy"])

        let dev = try config.resolve()
        #expect(dev.name == "dev")
        #expect(dev.server.absoluteString == "https://rancher.example.com/k8s/clusters/c-abc")
        #expect(dev.insecure)
        #expect(dev.certificateAuthorities.isEmpty)
        #expect(dev.namespace == "team-a")
        #expect(dev.auth == .bearer("eyJhbGciOiJSUzI1NiIsImtpZCI6IiJ9.payload.sig"))

        let staging = try config.resolve("staging")
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        #expect(staging.auth == .tokenFile(directory + "/tokens/staging"))
        #expect(staging.certificateAuthorities.count == 1)
        #expect(staging.server.port == 6443)

        #expect(try config.resolve("legacy").auth == .basic(username: "admin", password: "p@ss: word"))
    }

    @Test func oidcAndUnknownAuthProviders() throws {
        let oidc = try KubeConfig(yaml: singleContext(host: "a.test", user: ["auth-provider:", "  name: oidc", "  config:", "    id-token: abc.def.ghi", "    idp-issuer-url: https://issuer"]))
        #expect(try oidc.resolve().auth == .bearer("abc.def.ghi"))
        let azure = try KubeConfig(yaml: singleContext(host: "a.test", user: ["auth-provider:", "  name: azure"]))
        #expect(try !azure.resolve().auth.isSupported)
        let gcp = try KubeConfig(yaml: singleContext(host: "a.test", user: ["auth-provider:", "  name: gcp", "  config:", "    cmd-path: /usr/bin/gcloud"]))
        #expect(try gcp.resolve().auth == .gcp)
    }

    @Test func tokenFileWinsOverToken() throws {
        let config = try KubeConfig(yaml: singleContext(host: "a.test", user: ["token: inline", "tokenFile: /tmp/token"]))
        #expect(try config.resolve().auth == .tokenFile("/tmp/token"))
    }

    @Test func clientCertificateProblemsAreExplained() throws {
        let noKey = try KubeConfig(yaml: singleContext(host: "a.test", user: ["client-certificate-data: \(Fixtures.base64(Fixtures.clientRsaCrt))"]))
        guard case .unsupported(let reason) = try noKey.resolve().auth else { Issue.record("expected unsupported"); return }
        #expect(reason.contains("no client key"))

        let mismatched = try KubeConfig(yaml: singleContext(host: "a.test", user: [
            "client-certificate-data: \(Fixtures.base64(Fixtures.clientRsaCrt))", "client-key-data: \(Fixtures.base64(Fixtures.clientEcKey))",
        ]))
        guard case .unsupported(let mismatch) = try mismatched.resolve().auth else { Issue.record("expected unsupported"); return }
        #expect(mismatch.contains("doesn't match"))
    }

    @Test func resolveErrors() throws {
        let empty = try KubeConfig(yaml: "apiVersion: v1\nkind: Config\n")
        #expect(throws: KubeConfig.ResolveError.self) { try empty.resolve() }
        let config = try KubeConfig(yaml: Kubeconfigs.kind)
        #expect(throws: KubeConfig.ResolveError.self) { try config.resolve("missing") }
        let badServer = try KubeConfig(yaml: singleContext(host: "", user: ["token: x"]).replacingOccurrences(of: "https://", with: "not a url"))
        #expect(throws: KubeConfig.ResolveError.self) { try badServer.resolve() }
        #expect(throws: KubeConfig.LoadError.self) {
            try KubeConfig(yaml: singleContext(host: "a.test", user: ["token: x"], cluster: ["certificate-authority-data: %%%not-base64"]))
        }
        let badCA = try KubeConfig(yaml: singleContext(host: "a.test", user: ["token: x"], cluster: ["certificate-authority-data: \(Fixtures.base64("hello"))"]))
        #expect(throws: KubeConfig.ResolveError.self) { try badCA.resolve() }
    }

    @Test func defaultPath() {
        let home = URL(filePath: "/Users/someone")
        #expect(KubeConfig.defaultPath(environment: [:], home: home).path == "/Users/someone/.kube/config")
        #expect(KubeConfig.defaultPath(environment: ["KUBECONFIG": "/a/one:/b/two"], home: home).path == "/a/one")
        #expect(KubeConfig.defaultPath(environment: ["KUBECONFIG": ":/b/two"], home: home).path == "/b/two")
        #expect(KubeConfig.defaultPath(environment: ["KUBECONFIG": ""], home: home).path == "/Users/someone/.kube/config")
    }

    @Test func pemBundles() {
        let bundle = Data((Fixtures.caCrt + "\n" + Fixtures.otherCrt).utf8)
        #expect(PEM.certificates(bundle).count == 2)
        #expect(PEM.certificates(Data("garbage".utf8)).isEmpty)
    }
}
