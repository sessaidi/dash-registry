import DashKit
import Foundation
import WorkspaceKit

/// What a row shows. Built from a WorkspaceKit `Workspace`, or by hand for previews
/// (`Workspace` has no public initializer).
extension WorkspaceItem {
    /// A workspace by exact name, else the only one whose name contains the text.
    static func find(_ text: String, in items: [WorkspaceItem]) -> WorkspaceItem? {
        let wanted = text.lowercased()
        if let exact = items.first(where: { $0.name.lowercased() == wanted }) { return exact }
        let hits = items.filter { $0.name.lowercased().contains(wanted) }
        return wanted.isEmpty || hits.count != 1 ? nil : hits[0]
    }
}

struct WorkspaceItem: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let deployedBy: String
    let gitBranch: String?
    /// Last deploy, else creation.
    let lastDeploy: Date?
    let persist: Bool
    let nodePool: NodePool
    /// Why `clean` would delete it; nil to keep (always nil when persisted).
    let cleanReason: String?

    init(name: String, deployedBy: String, gitBranch: String?, lastDeploy: Date?, persist: Bool, nodePool: NodePool, cleanReason: String?) {
        self.name = name
        self.deployedBy = deployedBy
        self.gitBranch = gitBranch
        self.lastDeploy = lastDeploy
        self.persist = persist
        self.nodePool = nodePool
        self.cleanReason = persist ? nil : cleanReason
    }

    init(_ workspace: Workspace, now: Date = Date()) {
        self.init(
            name: workspace.name, deployedBy: workspace.deployedBy, gitBranch: workspace.gitBranch,
            lastDeploy: workspace.deployedAt ?? workspace.createdAt, persist: workspace.persist,
            nodePool: workspace.nodePool, cleanReason: workspace.cleanReason(now: now))
    }

    var subtitle: String {
        [deployedBy, gitBranch, lastDeploy.map { "deployed \($0.relative)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static let sampleUser = "sadik"

    static var samples: [WorkspaceItem] {
        let now = Date()
        return [
            WorkspaceItem(name: "checkout-flow", deployedBy: sampleUser, gitBranch: "feat/checkout", lastDeploy: now.addingTimeInterval(-3_600),
                          persist: false, nodePool: .spot, cleanReason: nil),
            WorkspaceItem(name: "papi-perf", deployedBy: sampleUser, gitBranch: "main", lastDeploy: now.addingTimeInterval(-86_400 * 2),
                          persist: true, nodePool: .standard, cleanReason: nil),
            WorkspaceItem(name: "old-search", deployedBy: sampleUser, gitBranch: "search-v2", lastDeploy: now.addingTimeInterval(-86_400 * 12),
                          persist: false, nodePool: .legacy, cleanReason: "not deployed for over a week"),
            WorkspaceItem(name: "epg-refresh", deployedBy: "jrivera", gitBranch: "LAF-1234", lastDeploy: now.addingTimeInterval(-600),
                          persist: false, nodePool: .spot, cleanReason: nil),
            WorkspaceItem(name: "search-v3", deployedBy: sampleUser, gitBranch: "feat/LAF-5702-facets", lastDeploy: now.addingTimeInterval(-86_400 * 1.5),
                          persist: false, nodePool: .spot, cleanReason: nil),
            WorkspaceItem(name: "laf-5680", deployedBy: "ada", gitBranch: "feat/LAF-5680-renewals", lastDeploy: now.addingTimeInterval(-86_400 * 3),
                          persist: false, nodePool: .standard, cleanReason: nil),
            WorkspaceItem(name: "ops-212", deployedBy: "sam", gitBranch: "fix/OPS-212", lastDeploy: now.addingTimeInterval(-86_400 * 2.2),
                          persist: false, nodePool: .spot, cleanReason: nil),
            WorkspaceItem(name: "perf-baseline", deployedBy: "jrivera", gitBranch: "main", lastDeploy: now.addingTimeInterval(-86_400 * 20),
                          persist: true, nodePool: .standard, cleanReason: nil),
            WorkspaceItem(name: "legacy-epg", deployedBy: "ada", gitBranch: "epg-v1", lastDeploy: now.addingTimeInterval(-86_400 * 15),
                          persist: false, nodePool: .legacy, cleanReason: "not deployed for over a week"),
        ]
    }
}
