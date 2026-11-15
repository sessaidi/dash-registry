import DashKit
import SwiftUI

/// When the standup is, the team calendar, who you are and which Zoom meeting it is.
struct StandupSettings: View {
    @Bindable var standup: DailyStandupFeature
    private let days = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    /// The coming two weeks at a glance: which days have a Zoom daily, and why others don't.
    private var nextZoomDays: String {
        let calendar = Calendar.current
        let format = Date.FormatStyle().weekday(.abbreviated).day()
        return (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: .now)) }
            .filter { standup.workdays.contains(calendar.component(.weekday, from: $0)) }
            .prefix(8)
            .map { day in
                if standup.isZoomDay(day) { return day.formatted(format) }
                if let skip = standup.calendar.skip(on: day) {
                    switch skip {
                    case .holiday: return "\(day.formatted(format)) holiday"
                    case .ceremony: return "\(day.formatted(format)) ceremony"
                    case .chapter: return "\(day.formatted(format)) chapter"
                    }
                }
                return "\(day.formatted(format)) no Zoom"
            }
            .joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Take the time from my calendar", isOn: $standup.useCalendar)
                if let event = standup.calendarStandup(on: .now) {
                    LabeledContent("Today", value: "\(event.title) at \(event.start.formatted(date: .omitted, time: .shortened))")
                }
                TextField(standup.useCalendar ? "Otherwise at" : "Standup time", text: $standup.time, prompt: Text("10:00"))
                Stepper("Prepare my update \(standup.prepareMinutesBefore) min before", value: $standup.prepareMinutesBefore, in: 5...120, step: 5)
                dayToggles("Working days (an update every one)", $standup.workdays)
                dayToggles("On Zoom (followed and reported)", $standup.zoomDays)
            } header: {
                Text("When")
            } footer: {
                Text("Every working day you get your update: since the last standup, next steps, blockers. On Zoom days the meeting is also followed live and reported at the end. With the calendar, today's event titled like a standup (the words under Meeting) sets the time and the Join link, and a day it has one with a Zoom link counts as a Zoom day; it needs the Zoom plugin's calendar (Settings › Zoom).")
            }
            Section {
                Picker("Sprint length", selection: $standup.calendar.sprintWeeks) {
                    Text("No sprints").tag(0)
                    ForEach(1...6, id: \.self) { Text("\($0) week\($0 == 1 ? "" : "s")").tag($0) }
                }
                if standup.calendar.sprintWeeks > 0 {
                    DatePicker("A day in the first week of a sprint", selection: $standup.calendar.sprintStart, displayedComponents: .date)
                    Picker("Ceremony day (no daily)", selection: $standup.calendar.ceremonyWeekday) {
                        Text("None").tag(0)
                        ForEach(days, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if standup.calendar.ceremonyWeekday != 0, standup.calendar.sprintWeeks > 1 {
                        Picker("In week", selection: $standup.calendar.ceremonyWeek) {
                            ForEach(1...standup.calendar.sprintWeeks, id: \.self) { week in
                                Text(week == standup.calendar.sprintWeeks ? "\(week) (last)" : "\(week)").tag(week)
                            }
                        }
                    }
                    if let sprint = standup.calendar.sprint(on: .now) {
                        LabeledContent("Today", value: "Sprint week \(sprint.week) of \(standup.calendar.sprintWeeks)")
                    }
                }
                Picker("Chapter day (no daily)", selection: $standup.calendar.chapterWeekday) {
                    Text("None").tag(0)
                    ForEach(days, id: \.0) { Text($0.1).tag($0.0) }
                }
                if standup.calendar.chapterWeekday != 0 {
                    Stepper("Every \(standup.calendar.chapterEveryWeeks) week\(standup.calendar.chapterEveryWeeks == 1 ? "" : "s")",
                            value: $standup.calendar.chapterEveryWeeks, in: 1...12)
                    DatePicker("A week with a chapter day", selection: $standup.calendar.chapterAnchor, displayedComponents: .date)
                }
                Toggle("French public holidays (no standup)", isOn: $standup.calendar.frenchHolidays)
                LabeledContent("Next dailies on Zoom") { Text(nextZoomDays).foregroundStyle(.secondary) }
            } header: {
                Text("Team calendar")
            } footer: {
                Text("On ceremony and chapter days the Zoom daily is cancelled; you still get your update. On public holidays there's no standup at all.")
            }
            Section("You") {
                TextField("Your name in Zoom", text: $standup.myName)
                TextField("Your git email", text: $standup.gitEmail, prompt: Text("from each repository's git config"))
                TextField("Code folder", text: $standup.codeRoot, prompt: Text("~/Codes"))
            }
            Section {
                TextField("Meeting titles", text: $standup.keywords)
            } header: {
                Text("Which Zoom meeting is the standup")
            } footer: {
                Text("A meeting on a Zoom day within 45 minutes of the standup time, or whose title contains one of these words. Turn on Zoom captions so each line has its speaker's name.")
            }
        }
        .formStyle(.grouped)
    }

    private func dayToggles(_ title: String, _ selection: Binding<Set<Int>>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                ForEach(days, id: \.0) { day, label in
                    Toggle(label, isOn: Binding(get: { selection.wrappedValue.contains(day) },
                                                set: { on in if on { selection.wrappedValue.insert(day) } else { selection.wrappedValue.remove(day) } }))
                        .toggleStyle(.button)
                }
            }
        }
    }
}
