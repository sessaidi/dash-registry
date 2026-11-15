import Foundation

extension TrainCar {
    /// A deployment by id, else a workspace's latest one (cars are newest first).
    static func find(_ text: String, in cars: [TrainCar]) -> TrainCar? {
        cars.first { $0.id == text } ?? cars.first { $0.workspace.caseInsensitiveCompare(text) == .orderedSame }
    }
}

struct TrainCar: Identifiable, Hashable {
    let id: String
    let workspace: String
    let kind: String
    let app: String
    let version: String
    let branch: String
    let by: String
    let at: Date
    let duration: TimeInterval?
    let status: String
    let error: String
}

extension TrainCar {
    var failed: Bool { status == "failed" }
    var succeeded: Bool { status == "succeeded" }

    /// "Succeeded", "Failed", else "Running": the three a chart colours.
    var statusTitle: String { succeeded ? "Succeeded" : failed ? "Failed" : "Running" }

    /// What the deployment did, in a few words.
    var title: String {
        switch kind {
        case "worktree": "deployed \(app)"
        case "image": "image \(app)"
        case "config": "configuration"
        default: "created"
        }
    }

    /// The app, or what the deployment did when it has none (configuration, creation).
    var what: String { app.isEmpty ? title : app }

    /// The newest deployment of each workspace (cars newest first), in that order.
    static func latestPerWorkspace(_ cars: [TrainCar]) -> [TrainCar] {
        var seen: Set<String> = []
        return cars.sorted { $0.at > $1.at }.filter { seen.insert($0.workspace).inserted }
    }

    /// Sample deployments over the last week, for the gallery: four workspaces, a failure, one running.
    static var samples: [TrainCar] {
        let now = Date()
        func car(_ id: Int, _ workspace: String, _ kind: String, _ app: String, _ version: String, _ branch: String, _ by: String,
                 hoursAgo: Double, _ duration: TimeInterval?, _ status: String, _ error: String = "") -> TrainCar {
            TrainCar(id: "\(id)", workspace: workspace, kind: kind, app: app, version: version, branch: branch, by: by,
                     at: now.addingTimeInterval(-hoursAgo * 3_600), duration: duration, status: status, error: error)
        }
        return [
            car(1, "laf-5680", "worktree", "services-presentation-api", "a1b2c3d", "feat/laf-5680-renewals", "ada", hoursAgo: 0.1, nil, "running"),
            car(2, "ops-212", "worktree", "services-user", "9f8e7d6", "fix/ops-212", "sam", hoursAgo: 2, 95, "failed", "CrashLoopBackOff"),
            car(3, "laf-5680", "config", "", "", "", "ada", hoursAgo: 3, 8, "succeeded"),
            car(4, "checkout-flow", "worktree", "services-checkout", "4c5d6e7", "feat/checkout", "sadik", hoursAgo: 6, 241, "succeeded"),
            car(5, "ops-212", "worktree", "services-user", "8e7d6c5", "fix/ops-212", "sam", hoursAgo: 20, 102, "succeeded"),
            car(6, "epg-refresh", "image", "services-epg", "v2.14.0", "", "jrivera", hoursAgo: 26, 64, "succeeded"),
            car(7, "laf-5680", "worktree", "services-presentation-api", "f0e1d2c", "feat/laf-5680-renewals", "ada", hoursAgo: 30, 330, "failed", "ImagePullBackOff"),
            car(8, "checkout-flow", "worktree", "services-checkout", "3b4c5d6", "feat/checkout", "sadik", hoursAgo: 49, 225, "succeeded"),
            car(9, "epg-refresh", "worktree", "services-epg", "77aa88b", "LAF-1234", "jrivera", hoursAgo: 75, 180, "succeeded"),
            car(10, "laf-5680", "worktree", "services-presentation-api", "c9d8e7f", "feat/laf-5680-renewals", "ada", hoursAgo: 98, 298, "succeeded"),
            car(11, "checkout-flow", "create", "", "", "", "sadik", hoursAgo: 120, 41, "succeeded"),
            car(12, "epg-refresh", "worktree", "services-epg", "66bb77c", "LAF-1234", "jrivera", hoursAgo: 140, 170, "failed", "readiness probe failed"),
            car(13, "ops-212", "create", "", "", "", "sam", hoursAgo: 150, 38, "succeeded"),
        ]
    }
}
