import DashKit
import DashKitTesting
import Foundation
import Testing

@MainActor
struct AcmeIntegrationTests {
    /// An integration whose requests go to a stub host (one per test, so tests don't share answers).
    func make(token: String? = "secret", routes: [String: String] = ["/me": #"{"name": "ada"}"#]) -> (AcmeIntegration, String) {
        let host = "api-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: routes)
        return (AcmeIntegration(token: { token }, session: StubHTTP.session, server: URL(string: "https://\(host)")!), host)
    }

    @Test func connectsWithATokenAndVerifiesTheAccount() async throws {
        let (integration, host) = make()
        #expect(integration.isConnected)
        await integration.verify().value
        #expect(integration.account == "ada")
        #expect(integration.connectionState == .connected("Signed in as ada"))
        #expect(StubHTTP.requests(host).first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func aRejectedTokenShowsTheError() async throws {
        let (integration, _) = make(routes: [:])
        await integration.verify().value
        #expect(integration.account == nil)
        guard case .failed = integration.connectionState else { Issue.record("expected a failure"); return }
    }

    @Test func theServerIsAPreferenceAndStaysEncryptedOffThisMac() async throws {
        let integration = AcmeIntegration(token: { nil })   // no token: setServer's check sends nothing
        integration.preferences.removeAll()
        defer { integration.preferences.removeAll() }
        #expect(integration.server == AcmeIntegration.apiURL)
        #expect(!integration.setServer("http://acme.example.com"))      // the token would travel in clear
        #expect(!integration.setServer("not a url"))
        #expect(integration.setServer("http://localhost:8787"))
        // Saved: a new launch reads it back.
        #expect(AcmeIntegration(token: { nil }).server.absoluteString == "http://localhost:8787")
    }

    @Test func noTokenMeansNotConnected() {
        let (integration, _) = make(token: nil)
        #expect(!integration.isConnected && integration.connection == nil)
        #expect(integration.connectionState == .notConfigured)
        #expect(integration.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
    }

    @Test func toolsStayOnTheAPI() async throws {
        let (integration, host) = make(routes: ["/tickets": "[]"])
        let tickets = try #require(integration.tools.first { $0.name == "acme_tickets" })
        _ = try await tickets.run(["status": "todo"])
        #expect(StubHTTP.requests(host).last?.url?.query == "status=todo")
        await #expect(throws: ToolError.self) { try await tickets.run(["status": "todo&admin=1"]) }
        for path in ["https://evil.example/x", "//evil.example/x", "/../admin", "/@evil.example", "me"] {
            #expect(throws: ToolError.self) { try AcmeTools.apiPath(path) }
        }
        #expect(try AcmeTools.apiPath("/tickets?status=todo") == "/tickets?status=todo")
    }
}
