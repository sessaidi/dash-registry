import DashKit
import Foundation
import Network

/// An error talking to the Docker socket (connection, timeout, malformed response).
struct DockerSocketError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A parsed HTTP/1.1 response.
struct HTTPWireResponse: Equatable, Sendable {
    var status: Int
    /// Header names lowercased.
    var headers: [String: String]
    var body: Data
}

/// HTTP/1.1 over a byte stream: request serialization and response parsing
/// (Content-Length, chunked, or read-to-EOF bodies).
enum HTTPWire {
    /// Serializes a request with `Host` and `Connection: close`.
    static func requestData(_ request: URLRequest, host: String = "docker") -> Data {
        let url = request.url
        var target = url?.path(percentEncoded: true) ?? "/"
        if target.isEmpty { target = "/" }
        if let query = url?.query(percentEncoded: true), !query.isEmpty { target += "?" + query }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? Data()

        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host)", "Connection: close"]
        var hasLength = false
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" { continue }
            if lower == "content-length" { hasLength = true }
            lines.append("\(name): \(value)")
        }
        if !hasLength && (!body.isEmpty || ["POST", "PUT", "PATCH"].contains(method)) {
            lines.append("Content-Length: \(body.count)")
        }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// Parses a response from `data`. Returns nil while more bytes are needed;
    /// with `atEOF`, a body without a length runs to the end and truncation throws.
    static func parse(_ data: Data, atEOF: Bool) throws -> HTTPWireResponse? {
        let bytes = [UInt8](data)
        var start = 0
        while true {
            guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: start) else {
                if atEOF { throw DockerSocketError(bytes.isEmpty ? "Docker closed the connection without a response" : "Truncated HTTP headers") }
                return nil
            }
            let head = String(decoding: bytes[start..<headerEnd], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
                throw DockerSocketError("Malformed HTTP status line: \(statusLine.prefix(80))")
            }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = headers[name].map { "\($0), \(value)" } ?? value
            }
            let bodyStart = headerEnd + 4
            // Interim responses (100 Continue) precede the real one.
            if (100..<200).contains(status) && status != 101 {
                start = bodyStart
                continue
            }
            if status == 204 || status == 304 {
                return HTTPWireResponse(status: status, headers: headers, body: Data())
            }
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                guard let body = try dechunk(bytes, from: bodyStart, atEOF: atEOF) else { return nil }
                return HTTPWireResponse(status: status, headers: headers, body: body)
            }
            if let lengthText = headers["content-length"] {
                guard let length = Int(lengthText.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""), length >= 0 else {
                    throw DockerSocketError("Bad Content-Length: \(lengthText)")
                }
                if bytes.count - bodyStart < length {
                    if atEOF { throw DockerSocketError("Truncated body: \(bytes.count - bodyStart) of \(length) bytes") }
                    return nil
                }
                return HTTPWireResponse(status: status, headers: headers, body: Data(bytes[bodyStart..<(bodyStart + length)]))
            }
            guard atEOF else { return nil }
            return HTTPWireResponse(status: status, headers: headers, body: Data(bytes[bodyStart...]))
        }
    }

    /// Decodes a chunked body starting at `index`; nil while incomplete.
    static func dechunk(_ bytes: [UInt8], from index: Int, atEOF: Bool) throws -> Data? {
        var body = Data()
        var position = index
        func incomplete() throws -> Data? {
            if atEOF { throw DockerSocketError("Truncated chunked body") }
            return nil
        }
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: position) else { return try incomplete() }
            let sizeLine = String(decoding: bytes[position..<lineEnd], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw DockerSocketError("Bad chunk size: \(sizeLine.prefix(20))") }
            let dataStart = lineEnd + 2
            if size == 0 { return body }  // trailers, if any, are ignored
            guard bytes.count >= dataStart + size + 2 else { return try incomplete() }
            body.append(contentsOf: bytes[dataStart..<(dataStart + size)])
            position = dataStart + size + 2
        }
    }

    static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var index = start
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0] && Array(bytes[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }
}

/// Sends HTTP requests to a unix-domain socket with the Network framework.
enum UnixHTTP {
    static func send(_ request: URLRequest, socketPath: String, timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        let limit = timeout ?? (request.timeoutInterval > 0 && request.timeoutInterval < 600 ? request.timeoutInterval : 60)
        let exchange = UnixHTTPExchange(socketPath: socketPath, request: HTTPWire.requestData(request), timeout: limit)
        let wire = try await exchange.run()
        let url = request.url ?? URL(string: "http://docker/")!
        guard let response = HTTPURLResponse(url: url, statusCode: wire.status, httpVersion: "HTTP/1.1", headerFields: wire.headers) else {
            throw DockerSocketError("Couldn't build HTTP response")
        }
        HTTPTrace.record(request, status: wire.status, bytes: wire.body.count, started: started, service: "Docker")
        return (wire.body, response)
    }
}

/// One request/response on a fresh connection. All mutable state lives on `queue`.
private final class UnixHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private let socketPath: String
    private let queue = DispatchQueue(label: "dash.docker.socket")
    private var buffer = Data()
    private var continuation: CheckedContinuation<HTTPWireResponse, Error>?
    private var done = false

    init(socketPath: String, request: Data, timeout: TimeInterval) {
        self.socketPath = socketPath
        self.request = request
        self.timeout = timeout
        connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
    }

    func run() async throws -> HTTPWireResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<HTTPWireResponse, Error>) {
        self.continuation = continuation
        if done { return finish(.failure(CancellationError())) }
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { [self] error in
                    if let error { finish(.failure(DockerSocketError("Couldn't write to \(socketPath): \(error.localizedDescription)"))) }
                })
                receive()
            case .waiting(let error), .failed(let error):
                finish(.failure(DockerSocketError("Can't connect to \(socketPath): \(error.localizedDescription)")))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(DockerSocketError("Docker didn't answer within \(Int(timeout)) s")))
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] content, _, isComplete, error in
            if let content { buffer.append(content) }
            do {
                if let response = try HTTPWire.parse(buffer, atEOF: isComplete || error != nil) {
                    return finish(.success(response))
                }
            } catch {
                return finish(.failure(error))
            }
            if let error { return finish(.failure(DockerSocketError("Read failed: \(error.localizedDescription)"))) }
            receive()
        }
    }

    private func finish(_ result: Result<HTTPWireResponse, Error>) {
        guard !done || continuation != nil else { return }
        done = true
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
