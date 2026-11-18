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

    /// Replies keyed by the request's X-Amz-Target ("Logs_20140328.FilterLogEvents"), else host
    /// and path ("eks.eu-west-1.amazonaws.com/clusters"), else path ("/user"); others get a 404.
    static func reset(_ table: [String: Reply]) {
        lock.withLock {
            replies = table
            recorded = []
        }
    }

    /// What was sent, with the body (URLSession hands it over as a stream) back in `httpBody`.
    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream)
        }
        let path = request.url?.path() ?? ""
        let keys = [request.value(forHTTPHeaderField: "X-Amz-Target"), (request.url?.host() ?? "") + path, path].compactMap { $0 }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(request)
            return keys.lazy.compactMap { Self.replies[$0] }.first ?? .json(#"{"message":"Not Found"}"#, status: 404)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
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
