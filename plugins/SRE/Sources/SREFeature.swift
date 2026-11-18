import DashKit
import SwiftUI

/// A senior on-call SRE for Dash: agents that watch and investigate, tools that gather evidence
/// from Datadog, Google Cloud and Kubernetes (through their own read tools, never their APIs) and
/// hand narrow jobs to smaller models, a status widget, and presets that wake the agent.
/// Read-only: it proposes, the user acts.
@MainActor
final class SREFeature: DashExtension {
    let id = "sre"
    let name = "SRE"
    let systemImage = "stethoscope"
    let metadata = ExtensionMetadata(
        version: "1.3.3", summary: "A senior on-call SRE: watches monitors and pods, investigates with evidence, reports likely causes and next steps. Read-only.",
        category: .monitoring, tags: ["sre", "on-call", "incident"], homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.4.0")
    let layer = ExtensionLayer.feature
    /// Each one adds evidence when present; none is required.
    let optional = ["datadog", "datadog-monitors", "gcp", "kubernetes", "kubernetes-pods", "releases"]

    private(set) weak var host: (any ExtensionContext)?

    func start(host: any ExtensionContext) { self.host = host }
    func stop() {}

    var agents: [AgentDefinition] { SREAgents.all }
    var tools: [DashiiTool] { SRETools.tools(feature: self) }
    var functions: [AnyDashiiFunction] { [SREFunctions.severity.erased] }
    var aiTasks: [AITask] {
        [AITask(id: "severity", title: "Severity rating", summary: "Rates incidents S1–S4 for sre.severity.", models: [.fast, .balanced], defaultModel: .fast)]
    }
    var widgets: [WidgetType] { [WidgetType(StatusWidget.self)] }

    /// The host, or an error a tool can return.
    func requireHost() throws -> any ExtensionContext {
        guard let host else { throw ToolError("SRE isn't started yet.") }
        return host
    }
}
