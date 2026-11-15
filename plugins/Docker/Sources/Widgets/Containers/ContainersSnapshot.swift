import DashKit
import DashKitUI

/// How a container shows in the widget: its tone and badge.
extension DockerContainer {
    var tone: Tone {
        if health == "unhealthy" { return .danger }
        switch state {
        case "running": return health == "starting" ? .info : .success
        case "restarting", "paused": return .warning
        case "dead": return .danger
        case "exited": return (exitCode ?? 0) == 0 ? .neutral : .danger
        default: return .neutral
        }
    }

    var badgeText: String {
        if let health, state == "running" { return health }
        if state == "exited", let exitCode { return "exited \(exitCode)" }
        return state
    }
}
