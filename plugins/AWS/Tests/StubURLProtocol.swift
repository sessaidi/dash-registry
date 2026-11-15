import Foundation

/// Answers every request from a canned table and records what was sent. No network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ text: String, status: Int = 200) -> Reply { Reply(status: status, body: Data(text.utf8)) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    /// Replies keyed by URL path ("/user"); unknown paths get a 404.
    static func reset(_ table: [String: Reply]) {
        lock.withLock {
            replies = table
            recorded = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.replies[request.url?.path() ?? ""] ?? .json(#"{"message":"Not Found"}"#, status: 404)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
