import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The widget body: the stored sessions, filtered by its query, with selection and widget actions.
struct AgentList: View {
    let showFinished: Bool
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after "show finished".
    let query: WidgetQuery?
    let queryText: String
    @State private var queryIDs: [UUID]?
    /// The session the user picked: highlighted and published for linked widgets until another
    /// is picked or it's clicked again.
    @State private var selectedID: UUID?
    @Query(sort: \AgentSession.updatedAt, order: .reverse) private var sessions: [AgentSession]

    private var shown: [AgentSession] { sessions.filter { showFinished || $0.prURL == nil } }

    var body: some View {
        let visible = QueryRows.ordered(shown, by: queryIDs)
        VStack(alignment: .leading, spacing: 4) {
            QueryCount(shown: visible.count, total: shown.count, query: queryText)
            AgentRows(rows: visible.map(AgentSummary.init), selectedID: selectedID) { id in
                // Clicking selects and opens; clicking the selected one again unselects it.
                if selectedID == id {
                    selectedID = nil
                } else {
                    selectedID = id
                    host.ext(AgentsExtension.self)?.openWindow(id)
                }
            }
        }
        .onExitCommand { selectedID = nil }
        .reportsSelection(selectedID.flatMap { id in sessions.first { $0.id == id }?.queryRow })
        .handlesWidgetActions { name, input in
            switch name {
            case "select":
                let wanted = input["key"]?.string ?? ""
                guard let session = AgentSession.find(wanted, in: visible) else { throw ToolError("No shown session matches “\(wanted)”.") }
                selectedID = session.id
                return ["selected": .string(session.issueKey)]
            case "clear_selection":
                selectedID = nil
                return "cleared"
            default:
                throw ToolError("Unknown action \(name).")
            }
        }
        .task(id: QueryRows.key(queryText, shown, row: \.queryRow)) {
            queryIDs = await QueryRows.ids(query, shown, row: \.queryRow)
        }
    }
}

extension AgentSession {
    /// A session by ticket key (case-insensitive) or id.
    static func find(_ text: String, in sessions: [AgentSession]) -> AgentSession? {
        sessions.first { $0.issueKey.caseInsensitiveCompare(text) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(text) == .orderedSame }
    }
}
