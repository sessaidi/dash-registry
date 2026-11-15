import DashKit
import Darwin
import Foundation
import Testing

@Suite struct HTTPWireTests {
    @Test func contentLength() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n"
        let response = try #require(try HTTPWire.parse(Data(raw.utf8), atEOF: false))
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"ok\":true}\r\n")
    }

    @Test func contentLengthIncompleteWaitsThenThrowsAtEOF() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)
        #expect(try HTTPWire.parse(raw, atEOF: false) == nil)
        #expect(throws: DockerSocketError.self) { try HTTPWire.parse(raw, atEOF: true) }
        #expect(try HTTPWire.parse(Data("HTTP/1.1 200 OK\r\nContent-Le".utf8), atEOF: false) == nil)
    }

    @Test func chunked() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n6;ext=1\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\n\r\n"
        let response = try #require(try HTTPWire.parse(Data(raw.utf8), atEOF: false))
        #expect(String(decoding: response.body, as: UTF8.self) == "Wikipedia in \r\n\r\nchunks.")
        // Incomplete until the terminating chunk arrives.
        let partial = Data(raw.utf8.prefix(raw.utf8.count - 7))
        #expect(try HTTPWire.parse(partial, atEOF: false) == nil)
        #expect(throws: DockerSocketError.self) { try HTTPWire.parse(partial, atEOF: true) }
    }

    @Test func noContentAndReadToEOF() throws {
        let empty = try #require(try HTTPWire.parse(Data("HTTP/1.1 204 No Content\r\nServer: Docker\r\n\r\n".utf8), atEOF: false))
        #expect(empty.status == 204 && empty.body.isEmpty)
        let raw = Data("HTTP/1.0 200 OK\r\n\r\nstream body".utf8)
        #expect(try HTTPWire.parse(raw, atEOF: false) == nil)
        #expect(try HTTPWire.parse(raw, atEOF: true)?.body == Data("stream body".utf8))
    }

    @Test func skipsContinue() throws {
        let raw = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nhi"
        let response = try #require(try HTTPWire.parse(Data(raw.utf8), atEOF: false))
        #expect(response.status == 201 && response.body == Data("hi".utf8))
    }

    @Test func malformedStatus() {
        #expect(throws: DockerSocketError.self) { try HTTPWire.parse(Data("garbage\r\n\r\n".utf8), atEOF: false) }
    }

    @Test func requestSerialization() throws {
        var request = URLRequest(url: URL(string: "http://docker/containers/web/logs?stdout=1&tail=5")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let text = String(decoding: HTTPWire.requestData(request), as: UTF8.self)
        #expect(text.hasPrefix("GET /containers/web/logs?stdout=1&tail=5 HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n"))
        #expect(text.contains("Accept: application/json\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
        let post = try HTTP.request(URL(string: "http://docker/containers/web/stop")!, method: "POST")
        #expect(String(decoding: HTTPWire.requestData(post), as: UTF8.self).contains("Content-Length: 0\r\n"))
    }
}

@Suite struct LogDemuxTests {
    static func frame(_ stream: UInt8, _ text: String) -> Data {
        let payload = Data(text.utf8)
        let n = UInt32(payload.count)
        return Data([stream, 0, 0, 0, UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]) + payload
    }

    @Test func demultiplexes() {
        let data = Self.frame(1, "hello\n") + Self.frame(2, "oops\n") + Self.frame(1, "bye\n")
        #expect(DockerLogs.isMultiplexed(data))
        #expect(DockerLogs.frames(data).map(\.stream) == [1, 2, 1])
        #expect(DockerLogs.text(data) == "hello\noops\nbye\n")
        #expect(DockerLogs.text(data, markStderr: true) == "hello\n[stderr] oops\nbye\n")
    }

    @Test func largeAndTruncatedFrames() {
        let big = String(repeating: "x", count: 70_000)
        let data = Self.frame(1, big) + Self.frame(1, "tail")
        #expect(DockerLogs.text(data).count == 70_004)
        let cut = data.prefix(data.count - 2)
        #expect(DockerLogs.text(cut).hasSuffix("ta"))
    }

    @Test func rawTTYOutput() {
        let data = Data("plain tty output\n".utf8)
        #expect(!DockerLogs.isMultiplexed(data))
        #expect(DockerLogs.text(data) == "plain tty output\n")
    }

    @Test func truncatesTo50k() {
        let text = String(repeating: "z", count: 10) + String(repeating: "b", count: 50_000)
        let (result, truncated) = DockerLogs.truncate(text)
        #expect(truncated)
        #expect(result.hasSuffix(String(repeating: "b", count: 50_000)))
        #expect(!result.contains("z"))
        #expect(DockerLogs.truncate("short") == ("short", false))
    }
}

@Suite struct SocketDiscoveryTests {
    let home = "/Users/test"

    @Test func preferenceWins() {
        #expect(DockerSocket.resolve(preferred: "unix:///tmp/d.sock", home: home, exists: { _ in true }) == "/tmp/d.sock")
        #expect(DockerSocket.resolve(preferred: "~/x.sock", home: home, exists: { _ in false }) == "/Users/test/x.sock")
    }

    @Test func firstExistingCandidate() {
        let existing: Set = ["/Users/test/.orbstack/run/docker.sock", "/Users/test/.colima/default/docker.sock"]
        // Colima profiles are listed only when their folder exists (this fake home has none).
        #expect(DockerSocket.resolve(preferred: "  ", home: home, environment: [:], exists: existing.contains) == "/Users/test/.orbstack/run/docker.sock")
        #expect(DockerSocket.resolve(preferred: nil, home: home, environment: [:], exists: { _ in true }) == "/Users/test/.docker/run/docker.sock")
        #expect(DockerSocket.resolve(preferred: nil, home: home, environment: [:], exists: { _ in false }) == nil)
        #expect(DockerSocket.detected(home: home, environment: [:], exists: existing.contains).count == 1)
    }

    @Test func candidateOrder() {
        #expect(DockerSocket.candidates(home: home, environment: [:]) == [
            "/Users/test/.docker/run/docker.sock", "/var/run/docker.sock",
            "/Users/test/.orbstack/run/docker.sock", "/Users/test/.rd/docker.sock",
        ])
    }

    @Test func findsColimaProfilesContextsAndDockerHost() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for folder in ["\(home)/.local/state/colima/work", "\(home)/.local/state/colima/default", "\(home)/.colima/old",
                       "\(home)/.docker/contexts/meta/abc"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try #"{"Name":"remote","Endpoints":{"docker":{"Host":"unix:///tmp/ctx.sock"}}}"#.write(toFile: "\(home)/.docker/contexts/meta/abc/meta.json", atomically: true, encoding: .utf8)
        let paths = DockerSocket.candidates(home: home, environment: ["DOCKER_HOST": "unix://\(home)/.local/state/colima/default/docker.sock"])
        #expect(paths.first == "\(home)/.local/state/colima/default/docker.sock")
        #expect(paths[1] == "/tmp/ctx.sock")
        #expect(paths.contains("\(home)/.local/state/colima/work/docker.sock") && paths.contains("\(home)/.colima/old/docker.sock"))
        #expect(Set(paths).count == paths.count)
    }
}

@Suite struct ContainerTests {
    @Test func parsesList() throws {
        let json = try JSONValue.parse(#"[{"Id":"abcdef1234567890","Names":["/web"],"Image":"nginx","State":"running","Status":"Up 2 hours (unhealthy)"},{"Id":"0011223344556677","Names":["/job"],"Image":"busybox","State":"exited","Status":"Exited (137) 5 minutes ago"}]"#)
        let list = DockerContainer.list(json)
        #expect(list.map(\.name) == ["web", "job"])
        #expect(list[0].health == "unhealthy")
        #expect(list[1].exitCode == 137)
        #expect(list[0].json["id"] == "abcdef123456")
        #expect(list[0].matches("abcd") && list[0].matches("web") && !list[0].matches("ab"))
    }

    @Test func changeEvents() {
        func c(_ id: String, _ state: String, _ status: String) -> DockerContainer {
            DockerContainer(id: id, name: "n" + id, image: "img", state: state, status: status)
        }
        let before = [c("a1b2c3", "running", "Up 1 hour"), c("d4e5f6", "running", "Up 1 hour (healthy)"),
                      c("g7h8i9", "running", "Up 1 hour"), c("j0k1l2", "running", "Up")]
        let after = [c("a1b2c3", "exited", "Exited (1) 1 second ago"), c("d4e5f6", "running", "Up 1 hour (unhealthy)"),
                     c("g7h8i9", "exited", "Exited (0) 1 second ago"), c("j0k1l2", "exited", "Exited (143) now")]
        let events = ContainerChanges.events(previous: before, current: after, intentional: ["nj0k1l2"])
        #expect(events.map(\.kind) == ["docker.container.exited", "docker.container.unhealthy"])
        #expect(events[0].title == "Container na1b2c3 exited unexpectedly (code 1)")
        #expect(ContainerChanges.events(previous: after, current: after).isEmpty)
    }

    @Test func containerPathValidation() throws {
        #expect(try DockerIntegration.containerPath("/web", "json") == "/containers/web/json")
        #expect(throws: ToolError.self) { try DockerIntegration.containerPath("../etc", "json") }
        #expect(throws: ToolError.self) { try DockerIntegration.containerPath("a?b", "json") }
    }
}

/// A one-shot HTTP server on a temporary unix socket.
final class TestSocketServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private(set) var receivedRequest = ""

    init(response: Data) throws {
        path = "/tmp/dash-docker-\(UUID().uuidString.prefix(8)).sock"
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerSocketError("socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { throw DockerSocketError("bind/listen failed: \(errno)") }
        let fd = fd
        let thread = Thread { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains(Data("\r\n\r\n".utf8)) {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                request.append(contentsOf: buffer[0..<count])
            }
            receivedRequest = String(decoding: request, as: UTF8.self)
            // Write in two pieces so the client sees a split response.
            let half = response.count / 2
            response.prefix(half).withUnsafeBytes { _ = write(client, $0.baseAddress, half) }
            usleep(20_000)
            response.dropFirst(half).withUnsafeBytes { _ = write(client, $0.baseAddress, response.count - half) }
            close(client)
        }
        thread.start()
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

@Suite struct TransportTests {
    @Test func endToEndThroughConnection() async throws {
        let body = #"{"Version":"27.3.1","ApiVersion":"1.47"}"#
        let half = body.count / 2
        let chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(half, radix: 16) + "\r\n" + body.prefix(half) + "\r\n"
            + String(body.count - half, radix: 16) + "\r\n" + body.dropFirst(half) + "\r\n0\r\n\r\n"
        let server = try TestSocketServer(response: Data(chunked.utf8))
        let path = server.path
        let connection = IntegrationConnection(baseURL: URL(string: "http://docker")!, headers: ["Accept": "application/json"],
                                               transport: { try await UnixHTTP.send($0, socketPath: path, timeout: 5) })
        let version = try await connection.get("/version", service: "Docker")
        #expect(version["Version"] == "27.3.1")
        #expect(server.receivedRequest.hasPrefix("GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n"))
        #expect(server.receivedRequest.contains("Accept: application/json"))
    }

    @Test func errorStatusThrowsHTTPError() async throws {
        let body = #"{"message":"No such container: nope1"}"#
        let server = try TestSocketServer(response: Data("HTTP/1.1 404 Not Found\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        let path = server.path
        let connection = IntegrationConnection(baseURL: URL(string: "http://docker")!, transport: { try await UnixHTTP.send($0, socketPath: path, timeout: 5) })
        await #expect(throws: HTTPError.self) { try await connection.get("/containers/nope1/json", service: "Docker") }
    }

    @Test func missingSocketFails() async {
        await #expect(throws: DockerSocketError.self) {
            try await UnixHTTP.send(URLRequest(url: URL(string: "http://docker/version")!), socketPath: "/tmp/dash-docker-missing.sock", timeout: 3)
        }
    }
}
