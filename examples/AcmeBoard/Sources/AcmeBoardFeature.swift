import DashKit
import Foundation
import Observation
import SwiftUI

/// Acme Board: the Acme tickets in a widget, tools and DashQL for Dashii, and a triage agent.
/// Uses the `acme` integration through DashKit only.
@MainActor
@Observable
final class AcmeBoardFeature: DashExtension {
    let id = "acme-board"
    let name = "Acme Board"
    let systemImage = "ticket"
    let metadata = ExtensionMetadata(version: "1.0.0", author: ExtensionAuthor(name: "Dash"),
                                     summary: "Your Acme tickets on the dashboard, with a triage agent.", category: .productivity, minimumDashKit: "2.0.0")
    let layer = ExtensionLayer.feature
    let requires = ["acme"]

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    private(set) var tickets: [AcmeTicket] = []
    private(set) var lastError: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// Urgent tickets already announced, kept across launches so a refresh (or a relaunch) only
    /// tells about new ones.
    @ObservationIgnored private var announced: Set<String> {
        get { Set(defaults.stringArray(forKey: "acme-board.announced") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "acme-board.announced") }
    }

    /// `defaults` is for tests; Dash uses the extensions' store.
    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
    }

    var widgets: [WidgetType] { [WidgetType(TicketsWidget.self)] }
    var tools: [DashiiTool] { AcmeBoardTools.tools(feature: self) }
    var functions: [AnyDashiiFunction] { [AcmeBoardTools.summary.erased] }
    var aiTasks: [AITask] {
        [AITask(id: "summary", title: "Summaries", summary: "Summarizes the open tickets.", models: [.fast, .balanced], defaultModel: .fast)]
    }
    var agents: [AgentDefinition] { [AcmeAgents.triage] }

    func start(host: any ExtensionContext) {
        self.host = host
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Reads the tickets through the integration's connection (auth included, token unseen) and
    /// tells the activity feed about new urgent ones, which wakes the triage agent.
    func refresh() async {
        guard let connection = host?.integration("acme")?.connection else {
            lastError = "Connect Acme in Settings."
            return
        }
        do {
            tickets = try await connection.get("/tickets", service: "Acme").array?.map(AcmeTicket.init) ?? []
            lastError = nil
            // Checked after the await: two refreshes in flight mustn't announce the same ticket twice.
            let urgent = tickets.filter(\.isUrgent)
            let seen = announced
            for ticket in urgent where !seen.contains(ticket.id) {
                host?.activity.emit("acme.urgent", source: id, title: "Urgent: \(ticket.title)", detail: ticket.id, importance: .notable)
            }
            // Only the ones still urgent: one that stops being urgent and comes back is news again.
            announced = Set(urgent.map(\.id))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requireHost() throws -> any ExtensionContext {
        guard let host else { throw ToolError("Acme Board isn't running.") }
        return host
    }
}
