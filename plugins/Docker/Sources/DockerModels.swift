import DashKit
import Foundation

/// Finds the Docker Engine socket.
enum DockerSocket {
    /// Well-known sockets, in discovery order (Docker Desktop, system, Colima, OrbStack, Rancher Desktop).
    /// Dash's environment plus your login shell's (DOCKER_HOST is usually set in your shell config).
    static var environment: [String: String] { ShellEnvironment.current }

    /// In order: DOCKER_HOST, the Docker CLI's contexts (current first), then the usual places.
    static func candidates(home: String = NSHomeDirectory(), environment: [String: String] = DockerSocket.environment) -> [String] {
        var paths: [String] = []
        // DOCKER_HOST (when Dash was started from a shell that sets it).
        if let host = environment["DOCKER_HOST"], let path = normalize(host, home: home), host.hasPrefix("unix://") || host.hasPrefix("/") { paths.append(path) }
        // Docker contexts (`docker context use`), current one first.
        paths += contextSockets(home: home)
        paths += [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.rd/docker.sock",
        ]
        // Colima, every profile: newer versions keep sockets in ~/.local/state/colima, older in ~/.colima.
        for folder in ["\(home)/.local/state/colima", "\(home)/.colima"] {
            let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted { a, b in a == "default" || (b != "default" && a < b) }
            paths += profiles.map { "\(folder)/\($0)/docker.sock" }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Sockets of the Docker CLI's contexts (~/.docker/contexts/meta/*/meta.json), the current one first.
    static func contextSockets(home: String) -> [String] {
        let meta = URL(fileURLWithPath: "\(home)/.docker/contexts/meta")
        let current = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(home)/.docker/config.json"))) as? [String: Any])?["currentContext"] as? String
        var found: [(name: String, path: String)] = []
        for folder in (try? FileManager.default.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appending(path: "meta.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = ((json["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String,
                  host.hasPrefix("unix://"), let path = normalize(host, home: home) else { continue }
            found.append((json["Name"] as? String ?? "", path))
        }
        return found.sorted { a, _ in a.name == current }.map(\.path)
    }

    /// "unix:///x", "~/x" or "/x" → "/x". Empty → nil.
    static func normalize(_ value: String?, home: String = NSHomeDirectory()) -> String? {
        guard var path = value?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("unix://") { path.removeFirst("unix://".count) }
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        return path
    }

    /// The preferred socket if set (even if missing, so errors name it), else the first existing candidate.
    static func resolve(preferred: String?, home: String = NSHomeDirectory(), environment: [String: String] = DockerSocket.environment,
                        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let preferred = normalize(preferred, home: home) { return preferred }
        return candidates(home: home, environment: environment).first(where: exists)
    }

    /// What to say when nothing answers on a socket: which runtime it belongs to and how to start it.
    static func unreachable(_ path: String, error: Error) -> String {
        let refused = "\(error)".contains("61") || "\(error)".localizedCaseInsensitiveContains("refused")
            || "\(error)".contains("ENOENT") || "\(error)".contains("No such file")
        guard refused else { return "Can't connect to \(path): \(error.localizedDescription)" }
        return "Docker isn't running: nothing answers on \(path). " + startHint(path) + " Then check the connection again."
    }

    /// How to start the runtime a socket belongs to.
    static func startHint(_ path: String) -> String {
        if path.contains("colima") { return "Colima is stopped; start it with `colima start`." }
        if path.contains(".orbstack") { return "Open OrbStack." }
        if path.contains(".rd/") { return "Open Rancher Desktop." }
        if path.contains("podman") { return "Start Podman (`podman machine start`)." }
        return "Open Docker Desktop."
    }

    static func detected(home: String = NSHomeDirectory(), environment: [String: String] = DockerSocket.environment,
                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        candidates(home: home, environment: environment).filter(exists)
    }
}

/// Docker's log stream format: frames of an 8-byte header (stream type, 3 zero bytes,
/// big-endian UInt32 length) and payload. TTY containers send raw bytes instead.
enum DockerLogs {
    struct Frame: Equatable {
        /// 0 stdin, 1 stdout, 2 stderr.
        var stream: UInt8
        var payload: Data
    }

    static func isMultiplexed(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        return bytes.count == 8 && bytes[0] <= 2 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0
    }

    /// Splits a multiplexed stream into frames; a truncated last frame keeps what arrived.
    static func frames(_ data: Data) -> [Frame] {
        let bytes = [UInt8](data)
        var frames: [Frame] = []
        var index = 0
        while index + 8 <= bytes.count {
            let length = Int(bytes[index + 4]) << 24 | Int(bytes[index + 5]) << 16 | Int(bytes[index + 6]) << 8 | Int(bytes[index + 7])
            let start = index + 8
            let end = min(start + length, bytes.count)
            frames.append(Frame(stream: bytes[index], payload: Data(bytes[start..<end])))
            index = start + length
        }
        return frames
    }

    /// Log text: demultiplexed when framed (stderr lines prefixed with "[stderr] " if `markStderr`), raw otherwise.
    static func text(_ data: Data, markStderr: Bool = false) -> String {
        guard isMultiplexed(data) else { return String(decoding: data, as: UTF8.self) }
        var output = ""
        for frame in frames(data) {
            let chunk = String(decoding: frame.payload, as: UTF8.self)
            output += markStderr && frame.stream == 2 ? "[stderr] " + chunk : chunk
        }
        return output
    }

    /// Keeps the last `limit` characters, noting the cut.
    static func truncate(_ text: String, limit: Int = 50_000) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return ("…(earlier output cut)\n" + String(text.suffix(limit)), true)
    }
}

/// One row of GET /containers/json.
struct DockerContainer: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var image: String
    /// created, running, paused, restarting, removing, exited, dead.
    var state: String
    /// "Up 3 hours (healthy)", "Exited (1) 2 minutes ago".
    var status: String

    var shortID: String { String(id.prefix(12)) }

    /// "healthy", "unhealthy", "starting" or nil.
    var health: String? {
        if status.contains("(unhealthy)") { return "unhealthy" }
        if status.contains("(healthy)") { return "healthy" }
        if status.contains("(health: starting)") { return "starting" }
        return nil
    }

    /// The code in "Exited (137) …".
    var exitCode: Int? {
        guard status.hasPrefix("Exited ("), let close = status.firstIndex(of: ")") else { return nil }
        return Int(status[status.index(status.startIndex, offsetBy: 8)..<close])
    }

    init(id: String, name: String, image: String, state: String, status: String) {
        self.id = id
        self.name = name
        self.image = image
        self.state = state
        self.status = status
    }

    init?(json: JSONValue) {
        guard let id = json["Id"]?.string else { return nil }
        self.id = id
        let names = json["Names"]?.array?.compactMap(\.string) ?? []
        name = names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12))
        image = json["Image"]?.string ?? ""
        state = json["State"]?.string ?? ""
        status = json["Status"]?.string ?? ""
    }

    static func list(_ json: JSONValue) -> [DockerContainer] {
        (json.array ?? []).compactMap(DockerContainer.init(json:))
    }

    var json: JSONValue {
        ["id": .string(shortID), "name": .string(name), "image": .string(image), "state": .string(state), "status": .string(status)]
    }

    /// Matches a full id, an id prefix or a name.
    func matches(_ reference: String) -> Bool {
        let reference = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        return name == reference || (reference.count >= 4 && id.hasPrefix(reference))
    }
}

/// Activity worth reporting between two container listings.
enum ContainerChanges {
    struct Event: Equatable {
        var kind: String
        var title: String
        var detail: String?
        var importance: ActivityEvent.Importance
    }

    /// A running container that exited (non-zero, or dead) and wasn't stopped on purpose,
    /// and a container that turned unhealthy.
    static func events(previous: [DockerContainer], current: [DockerContainer], intentional: [String] = []) -> [Event] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [Event] = []
        for container in current {
            guard let old = before[container.id] else { continue }
            let onPurpose = intentional.contains { container.matches($0) }
            if old.state == "running", container.state == "exited" || container.state == "dead", !onPurpose {
                let code = container.exitCode
                if container.state == "dead" || (code ?? 1) != 0 {
                    events.append(Event(
                        kind: "docker.container.exited",
                        title: "Container \(container.name) exited unexpectedly" + (code.map { " (code \($0))" } ?? ""),
                        detail: "\(container.image) · \(container.status)", importance: .notable))
                }
            }
            if container.health == "unhealthy", old.health != "unhealthy" {
                events.append(Event(
                    kind: "docker.container.unhealthy", title: "Container \(container.name) is unhealthy",
                    detail: "\(container.image) · \(container.status)", importance: .notable))
            }
        }
        return events
    }
}

extension DockerContainer {
    /// Sort order: unhealthy first, then running, transitional, stopped.
    var stateRank: Int {
        switch state {
        case "running": health == "unhealthy" ? 0 : 1
        case "restarting", "paused": 2
        default: 3
        }
    }
}
