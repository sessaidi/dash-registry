import DashKit
import DashKitUI
import SwiftUI

/// Open blockers, with Resolved.
struct BlockersView: View {
    let standup: DailyStandupFeature

    var body: some View {
        let _ = standup.revision
        let blockers = standup.openBlockers()
        if blockers.isEmpty {
            ContentUnavailableView("No open blockers", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(blockers) { blocker in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.text).font(.callout)
                        Text("\(blocker.owner) · open \(blocker.daysOpen) day\(blocker.daysOpen == 1 ? "" : "s")\(blocker.reference.isEmpty ? "" : " · \(blocker.reference)")")
                            .font(.caption).foregroundStyle(blocker.daysOpen >= 3 ? .red : .secondary)
                    }
                    Spacer()
                    Button("Resolved", systemImage: "checkmark.circle") { standup.resolve(blocker) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }
}
