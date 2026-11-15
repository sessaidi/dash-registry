import SwiftUI

/// The session list, fed by the store or by samples.
struct AgentRows: View {
    let rows: [AgentSummary]
    var selectedID: UUID? = nil
    let open: (UUID) -> Void

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("No agents", systemImage: "hammer", description: Text("Open a Jira ticket and choose Start Agent."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(rows) { row in
                HStack {
                    AgentStatusDot(status: row.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.issueKey) · \(row.title)").lineLimit(1)
                        Text("\(row.phase) · \(row.branch) · $\(row.costUSD, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if row.hasPullRequest { Image(systemName: "arrow.triangle.pull").foregroundStyle(.green) }
                }
                .contentShape(.rect)
                .onTapGesture { open(row.id) }
                .listRowBackground(selectedID == row.id ? Color.accentColor.opacity(0.18) : Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// Running, failed or done.
struct AgentStatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(status == "running" ? Color.blue : status == "failed" ? .red : .green)
            .frame(width: 8, height: 8)
            .help(status)
    }
}
