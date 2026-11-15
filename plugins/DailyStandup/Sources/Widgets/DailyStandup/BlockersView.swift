import DashKit
import DashKitUI
import SwiftUI

/// Open blockers, with Resolved.
struct BlockersSection: View {
    let blockers: [StandupBlockerRow]
    let resolve: (UUID) -> Void

    var body: some View {
        if blockers.isEmpty {
            Label("No open blockers", systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(blockers) { blocker in
                ItemRow(blocker.text, subtitle: blocker.subtitle) {
                    StatusDot(blocker.daysOpen >= 3 ? .danger : .warning, help: blocker.daysOpen >= 3 ? "Open for days" : "Open")
                } trailing: {
                    Button("Resolved", systemImage: "checkmark.circle") { resolve(blocker.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Mark as resolved")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}
