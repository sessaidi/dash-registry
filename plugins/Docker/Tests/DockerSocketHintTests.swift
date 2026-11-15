import Foundation
import Testing

/// A socket nothing answers on says which runtime to start.
struct DockerSocketHintTests {
    struct Refused: Error, CustomStringConvertible { var description: String { "POSIXErrorCode(rawValue: 61): Connection refused" } }
    struct Other: Error {}

    @Test func explainsAStoppedRuntime() {
        let message = DockerSocket.unreachable("/Users/me/.local/state/colima/default/docker.sock", error: Refused())
        #expect(message.contains("Docker isn't running") && message.contains("colima start"))
        #expect(DockerSocket.startHint("/Users/me/.orbstack/run/docker.sock") == "Open OrbStack.")
        #expect(DockerSocket.startHint("/var/run/docker.sock") == "Open Docker Desktop.")
        #expect(DockerSocket.unreachable("/var/run/docker.sock", error: Other()).hasPrefix("Can't connect to"))
    }
}
