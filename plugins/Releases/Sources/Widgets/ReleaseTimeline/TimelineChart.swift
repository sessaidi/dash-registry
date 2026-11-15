import DashKit
import SwiftUI

/// The timeline itself, drawn in one Canvas.
struct TimelineChart: View {
    let model: TimelineModel
    let domain: ClosedRange<Date>
    let now: Date
    let compact: Bool
    let selected: String?
    let hovered: String?
    let query: String
    /// A date to mark with a dashed line (from a date search).
    var marker: Date? = nil

    var body: some View {
        GeometryReader { geometry in
            let layout = TimelineLayout(size: geometry.size, domain: domain, compact: compact, lanes: model.lanes)
            Canvas { context, size in
                draw(&context, layout)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ layout: TimelineLayout) {
        let plot = layout.plot
        let bands = layout.bands
        let bottom = layout.height
        let today = layout.x(now)
        let showToday = plot.contains(today) && !compact
        // Grid and axis; a label that would run into "today" is left out.
        for tick in layout.ticks() {
            let x = layout.x(tick.date)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: layout.axisHeight)); $0.addLine(to: CGPoint(x: x, y: bottom)) },
                           with: .color(.secondary.opacity(0.15)), lineWidth: 1)
            let label = context.resolve(Text(tick.label).font(.caption2).foregroundStyle(.secondary))
            let width = label.measure(in: CGSize(width: 200, height: 20)).width
            if showToday, x + 3 + width > today - 36, x < today + 4 { continue }
            context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
        }
        let plotClip = Path(CGRect(x: plot.lowerBound, y: 0, width: plot.upperBound - plot.lowerBound, height: bottom))
        for (lane, rect) in bands {
            if let group = lane.groupTitle {
                context.draw(Text(group).font(.caption.bold()), at: CGPoint(x: 4, y: rect.minY - layout.groupHeight + 1), anchor: .topLeading)
            }
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.secondary.opacity(0.07)))
            // Lane label.
            let title = Text(lane.title).font(compact ? .caption2.bold() : .caption.bold())
            if compact || lane.subtitle.isEmpty {
                context.draw(title, at: CGPoint(x: 4, y: rect.midY), anchor: .leading)
            } else {
                context.draw(title, at: CGPoint(x: 4, y: rect.midY - 1), anchor: .bottomLeading)
                context.draw(Text(lane.subtitle).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: rect.midY + 1), anchor: .topLeading)
            }
            var inner = context
            inner.clip(to: plotClip)
            if case .events = lane.kind { drawEvents(&inner, lane, rect, layout) } else { drawEras(&inner, lane, rect, layout) }
        }
        // The searched date.
        if let marker, plot.contains(layout.x(marker)) {
            let x = layout.x(marker)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: layout.axisHeight - 2)); $0.addLine(to: CGPoint(x: x, y: bottom)) },
                           with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        // Today.
        if plot.contains(today) {
            context.stroke(Path { $0.move(to: CGPoint(x: today, y: layout.axisHeight - 2)); $0.addLine(to: CGPoint(x: today, y: bottom)) },
                           with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2))
            if showToday {
                context.draw(Text("today").font(.caption2).foregroundStyle(.red), at: CGPoint(x: today - 3, y: 2), anchor: .topTrailing)
            }
        }
    }

    private func drawEras(_ context: inout GraphicsContext, _ lane: TimelineModel.Lane, _ band: CGRect, _ layout: TimelineLayout) {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        for release in lane.releases {
            let rect = layout.eraRect(release, in: band)
            guard rect.maxX >= layout.plot.lowerBound - 2, rect.minX <= layout.plot.upperBound + 2 else { continue }
            let dimmed = searching && !release.matches(query)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            let opacity = (release.index % 2 == 0 ? 0.88 : 0.68) * (dimmed ? 0.18 : 1)
            context.fill(path, with: .color(lane.color.opacity(release.isHotfix ? opacity * 0.55 : opacity)))
            if release.isHotfix {
                context.stroke(path, with: .color(lane.color.opacity(dimmed ? 0.3 : 1)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            }
            if release.id == selected || release.id == hovered {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                               with: .color(.primary.opacity(release.id == selected ? 0.9 : 0.45)), lineWidth: release.id == selected ? 2 : 1)
            }
            if searching, !dimmed, rect.width < 6 {
                // A match too thin to see: a dot above it.
                context.fill(Path(ellipseIn: CGRect(x: rect.midX - 2.5, y: band.minY - 3, width: 5, height: 5)), with: .color(.primary))
            }
            // Extra builds: ticks from the top edge; a build tagged after the era ended sits at the bottom.
            for build in release.builds.dropFirst() {
                let x = layout.x(build.date)
                let late = build.date > release.end
                let y0 = late ? band.maxY - 9 : band.minY + 2
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: y0)); $0.addLine(to: CGPoint(x: x, y: y0 + 7)) },
                               with: .color(build.onBase ? Color.primary.opacity(0.55) : .red), lineWidth: 1.5)
            }
            let label = Text(release.shortName).font(.caption2.monospaced()).foregroundStyle(.white)
            let resolved = context.resolve(label)
            let measured = resolved.measure(in: CGSize(width: 400, height: 20))
            // The label goes in the era's visible part (it may start off the left edge).
            let left = max(rect.minX, layout.plot.lowerBound)
            let right = min(rect.maxX, layout.plot.upperBound)
            if right - left > measured.width + 8, !dimmed {
                context.draw(resolved, at: CGPoint(x: left + 4, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func drawEvents(_ context: inout GraphicsContext, _ lane: TimelineModel.Lane, _ band: CGRect, _ layout: TimelineLayout) {
        var lastX = -CGFloat.infinity
        var row = 0
        for event in lane.events {
            let x = layout.x(event.date)
            row = x - lastX < 10 ? (row + 1) % 2 : 0
            lastX = x
            let y = band.midY + (row == 0 ? -3 : 4)
            let color: Color = switch event.kind { case .launch: .green; case .incident: .red; case .milestone: .purple }
            let size: CGFloat = compact ? 7 : 9
            let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            let path: Path = switch event.kind {
            case .launch: Path(ellipseIn: rect)
            case .incident: Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); $0.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); $0.closeSubpath() }
            case .milestone: Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); $0.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); $0.closeSubpath() }
            }
            let dimmed = !query.isEmpty && !(event.title + " " + event.note).lowercased().contains(query.lowercased())
            context.fill(path, with: .color(color.opacity(dimmed ? 0.2 : 0.95)))
        }
    }
}
