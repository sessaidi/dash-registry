import DashKit
import DashKitUI
import SwiftUI

/// The containers the widget shows, laid out for its size family:
/// - narrow: a verdict ("2 need attention" or "5 running") and the three most urgent containers;
/// - medium: the list, image and uptime on one line;
/// - wide: a table with Name, Image, State, Uptime and ID columns;
/// - large: a summary strip, the table, and the containers grouped by image.
/// The live widget and the gallery preview both render this, so it takes plain data.
struct ContainersContent: View {
    let containers: [DockerContainer]
    /// How many there were before the query bar (for "12 of 40").
    let total: Int
    var queryText = ""
    var error: String?
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch layout.family {
            case .narrow:
                ContainersNarrowView(containers: containers)
            case .wide:
                ContainersHeadline(containers: containers, shown: containers.count, total: total, queryText: queryText)
                ContainerTable(containers: containers)
            case .large:
                ContainersHeadline(containers: containers, shown: containers.count, total: total, queryText: queryText)
                ContainersLargeView(containers: containers)
            default:
                QueryCount(shown: containers.count, total: total, query: queryText)
                ContainersMediumView(containers: containers)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .lineLimit(layout.family == .narrow ? 1 : 2).help(error)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Families

/// Narrow: the verdict and the three containers most in need of a look.
struct ContainersNarrowView: View {
    let containers: [DockerContainer]

    var body: some View {
        let problems = containers.filter(\.needsAttention)
        let running = containers.count { $0.state == "running" }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(problems.isEmpty ? .success : problems.contains { $0.tone == .danger } ? .danger : .warning)
                Text(problems.isEmpty ? "\(running) running" : "\(problems.count) need attention")
                    .font(.headline).lineLimit(1)
            }
            if !problems.isEmpty {
                Text("\(running) of \(containers.count) running").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach((problems.isEmpty ? containers : problems).prefix(3)) { container in
                    HStack(spacing: 6) {
                        StatusDot(container.tone, help: container.state)
                        Text(container.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(container.badgeText).font(.caption).foregroundStyle(container.tone == .success ? .secondary : container.tone.color)
                            .lineLimit(1).fixedSize()
                    }
                    .help("\(container.image) · \(container.status)")
                }
            }
        }
    }
}

/// Medium: one row per container, image and uptime on the second line.
struct ContainersMediumView: View {
    let containers: [DockerContainer]

    var body: some View {
        List(containers) { container in
            ItemRow(container.name, subtitle: "\(container.image) · \(container.status)", leading: {
                StatusDot(container.tone, help: container.state)
            }, trailing: {
                Badge(container.badgeText, tone: container.tone)
            })
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Large: counts across the top, then the table beside the containers grouped by image.
struct ContainersLargeView: View {
    let containers: [DockerContainer]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContainersSummaryStrip(containers: containers)
            HStack(alignment: .top, spacing: 16) {
                ContainerTable(containers: containers)
                    .frame(maxWidth: .infinity)
                ImageBreakdown(containers: containers)
                    .frame(maxWidth: 240)
            }
        }
    }
}

// MARK: - Pieces

/// "8 containers · 2 need attention", with the query count, above the table.
private struct ContainersHeadline: View {
    let containers: [DockerContainer]
    let shown: Int
    let total: Int
    let queryText: String

    var body: some View {
        let problems = containers.count(where: \.needsAttention)
        HStack(spacing: 8) {
            Text("\(containers.count) containers").font(.callout.weight(.semibold))
            if problems > 0 {
                Badge("\(problems) need attention", tone: containers.contains { $0.tone == .danger } ? .danger : .warning,
                      systemImage: "exclamationmark.triangle")
            } else {
                Badge("all healthy", tone: .success, systemImage: "checkmark")
            }
            Spacer(minLength: 4)
            QueryCount(shown: shown, total: total, query: queryText)
        }
    }
}

/// Running, unhealthy, restarting and stopped counts.
private struct ContainersSummaryStrip: View {
    let containers: [DockerContainer]

    var body: some View {
        let failing = containers.count { $0.tone == .danger }
        let restarting = containers.count { $0.tone != .danger && ($0.state == "restarting" || $0.state == "paused") }
        let running = containers.count { $0.tone != .danger && $0.state == "running" }
        let stopped = containers.count - failing - restarting - running
        HStack(alignment: .top, spacing: 16) {
            MetricView("\(running)", label: "Running", tone: running > 0 ? .success : .neutral)
            MetricView("\(failing)", label: "Failing", tone: failing > 0 ? .danger : .neutral)
            MetricView("\(restarting)", label: "Restarting", tone: restarting > 0 ? .warning : .neutral)
            MetricView("\(stopped)", label: "Stopped")
        }
    }
}

/// How many containers run each image, worst tone first.
private struct ImageBreakdown: View {
    let containers: [DockerContainer]

    var body: some View {
        let groups = Dictionary(grouping: containers, by: \.image)
            .map { (image: $0.key, containers: $0.value) }
            .sorted { ($0.containers.count, $1.image) > ($1.containers.count, $0.image) }
        VStack(alignment: .leading, spacing: 6) {
            Text("By image").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.image) { group in
                        HStack(spacing: 6) {
                            HStack(spacing: 2) {
                                ForEach(group.containers) { StatusDot($0.tone, help: "\($0.name): \($0.badgeText)") }
                            }
                            Text(group.image).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 4)
                            Text("\(group.containers.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help(group.containers.map(\.name).joined(separator: ", "))
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}

/// `docker ps` as a table: the header and rows share one set of columns.
struct ContainerTable: View {
    let containers: [DockerContainer]
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            columns(dot: AnyView(Color.clear.frame(width: 8, height: 8)), name: Text("Name"), image: Text("Image"),
                    state: AnyView(Text("State")), uptime: Text("Uptime"), id: Text("ID"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(containers) { container in
                        columns(dot: AnyView(StatusDot(container.tone, help: container.state)),
                                name: Text(container.name),
                                image: Text(container.image).foregroundStyle(.secondary),
                                state: AnyView(Badge(container.badgeText, tone: container.tone)),
                                uptime: Text(container.statusDetail).monospacedDigit().foregroundStyle(.secondary),
                                id: Text(container.shortID).font(.caption.monospaced()).foregroundStyle(.secondary))
                            .font(.callout)
                            .padding(.vertical, 5)
                            .background(hovered == container.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                            .onHover { hovered = $0 ? container.id : (hovered == container.id ? nil : hovered) }
                            .help(container.status)
                        Divider().opacity(0.5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// One line, header or container: the name and image share the room, the rest is fixed.
    private func columns(dot: AnyView, name: Text, image: Text, state: AnyView, uptime: Text, id: Text) -> some View {
        HStack(spacing: 12) {
            dot.frame(width: 10)
            name.lineLimit(1).truncationMode(.middle).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            image.lineLimit(1).truncationMode(.head).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            state.lineLimit(1).frame(width: 96, alignment: .leading)
            uptime.lineLimit(1).frame(width: 110, alignment: .leading)
            id.lineLimit(1).frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 8)
    }
}
