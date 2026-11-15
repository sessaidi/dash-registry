import DashKit
import SwiftUI

/// What the chart draws: lanes top to bottom.
struct TimelineModel {
    struct Lane: Identifiable {
        enum Kind { case events, train(repository: String, train: String) }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let color: Color
        let releases: [Release]
        let events: [ReleaseEvent]
        /// First lane of a repository's group (draws its name above when there are several).
        var groupTitle: String?
    }

    var lanes: [Lane] = []
    var releases: [Release] { lanes.flatMap(\.releases) }
    var earliest: Date?

    static let palette: [Color] = [.blue, .orange, .teal, .pink, .purple, .green, .brown]

    init(timelines: [RepositoryTimeline], events: [ReleaseEvent], train: String?, showEvents: Bool) {
        if showEvents, !events.isEmpty {
            lanes.append(Lane(id: "events", kind: .events, title: "Events", subtitle: "", color: .secondary, releases: [], events: events))
        }
        for timeline in timelines {
            var first = true
            for (index, name) in timeline.trains.enumerated() where train == nil || train == name {
                let releases = timeline.releases(on: name)
                guard !releases.isEmpty else { continue }
                let color = name.isEmpty && timeline.trains.count > 1 ? Color.gray : Self.palette[index % Self.palette.count]
                let since = releases.first.map { "since " + $0.start.formatted(.dateTime.month(.abbreviated).year()) } ?? ""
                lanes.append(Lane(id: timeline.repository.id + "|" + name, kind: .train(repository: timeline.repository.id, train: name),
                                  title: timeline.trainTitle(name), subtitle: since, color: color, releases: releases, events: [],
                                  groupTitle: first && timelines.count > 1 ? timeline.repository.name : nil))
                first = false
            }
        }
        earliest = (releases.map(\.start) + (showEvents ? events.map(\.date) : [])).min()
    }
}

/// Positions shared by drawing and hit-testing.
struct TimelineLayout {
    let size: CGSize
    let domain: ClosedRange<Date>
    let compact: Bool
    let lanes: [TimelineModel.Lane]

    var labelWidth: CGFloat { compact ? 40 : 92 }
    var axisHeight: CGFloat { 18 }
    var laneHeight: CGFloat { compact ? 24 : 32 }
    var eventsHeight: CGFloat { compact ? 20 : 26 }
    var groupHeight: CGFloat { 14 }
    var gap: CGFloat { 5 }
    var plot: ClosedRange<CGFloat> { labelWidth...max(labelWidth + 40, size.width - 4) }

    func x(_ date: Date) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return plot.lowerBound }
        return plot.lowerBound + CGFloat(date.timeIntervalSince(domain.lowerBound) / span) * (plot.upperBound - plot.lowerBound)
    }

    func date(_ x: CGFloat) -> Date {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return domain.lowerBound.addingTimeInterval(Double((x - plot.lowerBound) / (plot.upperBound - plot.lowerBound)) * span)
    }

    /// Each lane's vertical band.
    var bands: [(lane: TimelineModel.Lane, rect: CGRect)] {
        var y = axisHeight + 2
        return lanes.map { lane in
            if lane.groupTitle != nil { y += groupHeight }
            let height: CGFloat = if case .events = lane.kind { eventsHeight } else { laneHeight }
            defer { y += height + gap }
            return (lane, CGRect(x: plot.lowerBound, y: y, width: plot.upperBound - plot.lowerBound, height: height))
        }
    }

    var height: CGFloat { (bands.last?.rect.maxY ?? axisHeight) + 4 }

    func eraRect(_ release: Release, in band: CGRect) -> CGRect {
        let start = x(release.start)
        return CGRect(x: start, y: band.minY + 2, width: max(1.5, x(release.end) - start), height: band.height - 4)
    }

    func release(at point: CGPoint) -> Release? {
        for (lane, rect) in bands where rect.insetBy(dx: -2, dy: -2).contains(point) {
            // The last era starting before the point, with a little slack for thin ones.
            return lane.releases.last { eraRect($0, in: rect).insetBy(dx: -3, dy: 0).contains(point) }
        }
        return nil
    }

    func event(at point: CGPoint) -> ReleaseEvent? {
        for (lane, rect) in bands where rect.contains(point) {
            return lane.events.min { abs(x($0.date) - point.x) < abs(x($1.date) - point.x) }.flatMap { abs(x($0.date) - point.x) < 8 ? $0 : nil }
        }
        return nil
    }

    /// Axis ticks: days, weeks, months, quarters or years, whichever keeps labels apart.
    func ticks() -> [(date: Date, label: String)] {
        let calendar = Calendar.current
        let width = plot.upperBound - plot.lowerBound
        let days = domain.upperBound.timeIntervalSince(domain.lowerBound) / 86_400
        let fit = max(1, Double(width) / (compact ? 64 : 84))
        let steps: [(Calendar.Component, Int)] = [(.day, 1), (.day, 2), (.weekOfYear, 1), (.weekOfYear, 2), (.month, 1), (.month, 3), (.month, 6), (.year, 1), (.year, 2)]
        let approx: [Calendar.Component: Double] = [.day: 1, .weekOfYear: 7, .month: 30.4, .year: 365]
        let (unit, count) = steps.first { days / (approx[$0.0]! * Double($0.1)) <= fit } ?? (.year, 5)
        var start: Date
        switch unit {
        case .year: start = calendar.dateInterval(of: .year, for: domain.lowerBound)?.start ?? domain.lowerBound
        case .month: start = calendar.dateInterval(of: .month, for: domain.lowerBound)?.start ?? domain.lowerBound
        case .weekOfYear: start = calendar.dateInterval(of: .weekOfYear, for: domain.lowerBound)?.start ?? domain.lowerBound
        default: start = calendar.startOfDay(for: domain.lowerBound)
        }
        var ticks: [(Date, String)] = []
        while start <= domain.upperBound, ticks.count < 60 {
            if start >= domain.lowerBound {
                let label = switch unit {
                case .year: start.formatted(.dateTime.year())
                case .month: calendar.component(.month, from: start) == 1 ? start.formatted(.dateTime.month(.abbreviated).year()) : start.formatted(.dateTime.month(.abbreviated))
                default: start.formatted(.dateTime.month(.abbreviated).day())
                }
                ticks.append((start, label))
            }
            guard let next = calendar.date(byAdding: unit, value: count, to: start) else { break }
            start = next
        }
        return ticks
    }
}
