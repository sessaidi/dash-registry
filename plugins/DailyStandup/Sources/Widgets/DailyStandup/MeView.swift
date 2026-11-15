import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Your update for today, or Prepare Now.
struct MeSection: View {
    let state: StandupState
    let commands: StandupCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let update = state.update {
                StandupUpdateView(update: update, preparedAt: state.preparedAt, onRefresh: commands.prepare)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label(state.unpreparedTitle, systemImage: "person.3.sequence").font(.headline)
                    Text(state.prepareHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let prepare = commands.prepare {
                        Button("Prepare Now", systemImage: "sparkles", action: prepare)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(state.isPreparing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            if state.isPreparing { ProgressView("Preparing…").controlSize(.small) }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct StandupUpdateView: View {
    let update: StandupUpdate
    let preparedAt: Date?
    let onRefresh: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Yesterday I did", update.yesterday, icon: "checkmark.circle")
                section("Today I will", update.today, icon: nil)
                section("Blockers", update.blockers, icon: "exclamationmark.octagon")
                HStack {
                    if let preparedAt { Text("Prepared \(preparedAt.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary) }
                    Spacer()
                    CopyUpdateButton(update: update)
                    if let onRefresh { Button("Redo", systemImage: "arrow.clockwise", action: onRefresh) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [StandupItem], icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            if items.isEmpty { Text("Nothing").font(.callout).foregroundStyle(.tertiary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon ?? StandupItem.icon(item.kind)).foregroundStyle(title == "Blockers" ? .red : .accentColor).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if let ticket = item.ticket, !ticket.isEmpty { Text(ticket).font(.callout.monospaced().bold()) }
                            if let label = StandupItem.label(item.kind) { Text(label).font(.caption.bold()).foregroundStyle(.secondary) }
                            Text(item.text).font(.callout)
                        }
                        if !item.refs.isEmpty { Text(item.refs.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }
                }
            }
        }
    }
}

/// Copies the update, ready for Slack.
struct CopyUpdateButton: View {
    let update: StandupUpdate

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(update.text, forType: .string)
        }
        .help("Copy for Slack")
    }
}
