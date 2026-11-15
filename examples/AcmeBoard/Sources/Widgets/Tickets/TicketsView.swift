import DashKit
import DashKitUI
import SwiftUI

/// One view, a layout per size family:
/// - narrow (Small): how many are open and the most urgent one;
/// - medium: a list, most urgent first;
/// - wide: a column per status;
/// - large: the columns and the triage agent's last report.
struct TicketsView: View {
    let snapshot: TicketsSnapshot
    let family: WidgetLayout.Family
    @State private var search = ""

    private var shown: [AcmeTicket] {
        search.isEmpty ? snapshot.tickets
            : snapshot.tickets.filter { $0.id.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        content
            // In the card's header, not in the content: a count of what's shown.
            .widgetHeader { Badge("\(shown.filter { $0.status != "done" }.count) open", tone: shown.contains(where: \.isUrgent) ? .danger : .neutral) }
            // What Dashii may do while the widget is on screen (TicketsWidget.actions).
            .handlesWidgetActions { name, input in
                guard name == "search" else { throw ToolError("Unknown action \(name).") }
                search = input["text"]?.string ?? ""
                return ["shown": .number(Double(shown.count))]
            }
            // What the widget shows beyond its settings, for Dashii.
            .reportsWidgetState(["search": .string(search)])
    }

    @ViewBuilder private var content: some View {
        if shown.isEmpty {
            StateView(.empty(title: search.isEmpty ? "No tickets" : "Nothing matches", systemImage: "ticket", message: nil))
        } else {
            switch family {
            case .narrow: glance
            case .wide: columns
            case .large:
                HStack(alignment: .top, spacing: 12) {
                    columns
                    triage.frame(minWidth: 140, maxWidth: 220)
                }
            default: list
            }
        }
    }

    private var glance: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricView("\(shown.filter { $0.status != "done" }.count)", label: "open tickets",
                       tone: shown.contains(where: \.isUrgent) ? .danger : .neutral)
            if let first = shown.first {
                Text(first.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(first.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(shown) { ticket in
                    ItemRow(ticket.title, subtitle: "\(ticket.id) · \(ticket.assignee ?? "Unassigned")",
                            leading: { StatusDot(Self.tone(ticket)) }, trailing: { Badge(ticket.status, tone: .neutral) })
                }
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 10) {
            // No empty "done" column when done tickets are hidden.
            ForEach(TicketsSnapshot.statuses.filter { $0 != "done" || shown.contains { $0.status == "done" } }, id: \.self) { status in
                let tickets = shown.filter { $0.status == status }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Badge("\(tickets.count)", tone: .neutral)
                    }
                    ForEach(tickets) { ticket in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ticket.title).font(.callout).lineLimit(2)
                            HStack {
                                Text(ticket.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                StatusDot(Self.tone(ticket), help: ticket.priority)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var triage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Triage", systemImage: "stethoscope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(snapshot.triage ?? "The triage agent hasn't reported yet. Turn it on in Acme Board's AI tab.")
                .font(.callout)
                .foregroundStyle(snapshot.triage == nil ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }

    static func tone(_ ticket: AcmeTicket) -> Tone {
        switch ticket.priority {
        case "urgent": .danger
        case "high": .warning
        default: .neutral
        }
    }
}

/// The sample at whatever size the gallery measures.
struct TicketsPreview: View {
    @Environment(\.widgetLayout) private var layout
    var body: some View { TicketsView(snapshot: .sample, family: layout.family) }
}
