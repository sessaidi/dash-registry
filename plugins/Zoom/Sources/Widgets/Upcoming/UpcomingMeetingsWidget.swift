import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Upcoming Meetings: the next Zoom meetings from the Mac's calendars, with a Join button.
struct UpcomingMeetingsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var count: Int
    }

    static let kind = "zoom.upcoming"
    static let sizeLimits = GridLimits(minW: 3, minH: 3, maxW: 12, maxH: 16)
    static let displayName = "Upcoming Meetings"
    static let summary = "The next Zoom meetings from your calendar, with a Join button."
    static let systemImage = "calendar"
    static let defaultSize = WidgetSize.medium
    static let defaultConfig = Config(count: 6)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["count": ["type": "integer", "description": "How many meetings to list."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        UpcomingMeetingsPanel(zoom: context.host.ext(ZoomExtension.self), count: config.wrappedValue.count)
    }

    static func preview(config: Config) -> some View {
        UpcomingMeetingsLayout(meetings: UpcomingSample.meetings, state: .ready).allowsHitTesting(false)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let zoom = context.host.ext(ZoomExtension.self) else { return .null }
        return ["calendar": .bool(zoom.useCalendar), "upcoming": .array(zoom.upcoming.prefix(config.count).map(\.json))]
    }
}

/// The widget body: the extension's upcoming meetings, or why there are none.
struct UpcomingMeetingsPanel: View {
    let zoom: ZoomExtension?
    let count: Int

    var body: some View {
        if let zoom {
            UpcomingMeetingsLayout(meetings: Array(zoom.upcoming.prefix(count)), state: state(zoom)) {
                Task { await zoom.enableCalendar() }
            }
        } else {
            StateView(.empty(title: "Zoom is off", systemImage: "video.slash", message: "Turn on the Zoom plugin in Settings › Plugins."))
        }
    }

    private func state(_ zoom: ZoomExtension) -> UpcomingMeetingsLayout.State {
        if zoom.calendarAccess == .denied { return .denied }
        return zoom.useCalendar ? .ready : .off
    }
}

/// One layout per size family: the next meeting alone (narrow), a list (medium), a list with
/// times and calendars (wide, large).
struct UpcomingMeetingsLayout: View {
    enum State { case off, denied, ready }

    let meetings: [CalendarMeeting]
    let state: State
    var enable: () -> Void = {}
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        switch state {
        case .off:
            StateView(.empty(title: "Calendar not connected", systemImage: "calendar.badge.plus",
                             message: "Read your Zoom meetings from the Mac's calendars (Google, Outlook or iCloud)."),
                      action: ("Use My Calendar", enable))
        case .denied:
            StateView(.empty(title: "No calendar access", systemImage: "calendar.badge.exclamationmark",
                             message: "Allow Dash in System Settings › Privacy & Security › Calendars."),
                      action: ("Open Settings", {
                          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                      }))
        case .ready where meetings.isEmpty:
            StateView(.empty(title: "No Zoom meetings", systemImage: "calendar", message: "Nothing with a Zoom link in the next 24 hours."))
        case .ready:
            if layout.family == .narrow, let next = meetings.first {
                NextMeeting(meeting: next)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(meetings) { MeetingRow(meeting: $0, detailed: layout.family == .wide || layout.family == .large) }
                    }
                }
            }
        }
    }
}

/// The next meeting, large: what, when, Join.
private struct NextMeeting: View {
    let meeting: CalendarMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.isHappening() ? "Now" : "Next").font(.caption).foregroundStyle(.secondary)
            Text(meeting.title).font(.headline).lineLimit(2)
            Text(meeting.start, style: meeting.isHappening() ? .time : .relative).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let link = meeting.joinURL {
                Button("Join", systemImage: "video") { ZoomCalendar.join(link) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MeetingRow: View {
    let meeting: CalendarMeeting
    let detailed: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(meeting.start, format: .dateTime.hour().minute()).font(.callout.monospacedDigit())
                if detailed { Text(meeting.end, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5).fill(meeting.isHappening() ? AnyShapeStyle(.green) : AnyShapeStyle(.tint)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).lineLimit(1)
                if detailed {
                    Text(meeting.calendar).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if meeting.isHappening() { Badge("now", tone: .success) }
            if let link = meeting.joinURL {
                Button("Join") { ZoomCalendar.join(link) }
                    .controlSize(.small)
                    .help(link.absoluteString)
            }
        }
        .frame(height: detailed ? 34 : 26)
    }
}

/// The gallery's sample day.
enum UpcomingSample {
    static var meetings: [CalendarMeeting] {
        let now = Date.now
        func meeting(_ title: String, in minutes: Double, length: Double = 30) -> CalendarMeeting {
            CalendarMeeting(id: title, title: title, start: now.addingTimeInterval(minutes * 60), end: now.addingTimeInterval((minutes + length) * 60),
                            calendar: "Work", joinURL: URL(string: "https://acme.zoom.us/j/123456789"))
        }
        return [meeting("Daily standup", in: -5, length: 15), meeting("Design review", in: 55, length: 60),
                meeting("1:1 with Ada", in: 180), meeting("Sprint planning", in: 300, length: 90)]
    }
}
