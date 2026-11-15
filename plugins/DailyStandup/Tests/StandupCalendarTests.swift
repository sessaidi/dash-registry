import Foundation
import Testing
@testable import DailyStandupPlugin

/// Sprints, ceremony and chapter days, French holidays.
struct StandupCalendarTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func frenchHolidays() {
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 4, 6), calendar: calendar) == "Lundi de Pâques")
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 5, 14), calendar: calendar) == "Ascension")
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 5, 25), calendar: calendar) == "Lundi de Pentecôte")
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 7, 14), calendar: calendar) == "Fête nationale")
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 11, 11), calendar: calendar) == "Armistice")
        #expect(StandupCalendar.frenchHoliday(on: day(2026, 11, 16), calendar: calendar) == nil)
        #expect(StandupCalendar.frenchHoliday(on: day(2027, 3, 29), calendar: calendar) == "Lundi de Pâques")
    }

    @Test func ceremonyDayIsTheLastWeeksDayOfEachSprint() {
        // Two-week sprints starting Monday 2 Nov 2026; ceremony on Thursday of week 2.
        var standup = StandupCalendar(sprintWeeks: 2, sprintStart: day(2026, 11, 2), ceremonyWeekday: 5, ceremonyWeek: 2, frenchHolidays: false)
        #expect(standup.skip(on: day(2026, 11, 5), calendar: calendar) == nil)       // week 1 Thursday
        #expect(standup.skip(on: day(2026, 11, 12), calendar: calendar) == .ceremony) // week 2 Thursday
        #expect(standup.skip(on: day(2026, 11, 26), calendar: calendar) == .ceremony) // next sprint's week 2
        #expect(standup.skip(on: day(2026, 10, 29), calendar: calendar) == .ceremony) // before the anchor too
        #expect(standup.sprint(on: day(2026, 11, 12), calendar: calendar)?.week == 2)
        standup.sprintWeeks = 0
        #expect(standup.skip(on: day(2026, 11, 12), calendar: calendar) == nil)
    }

    @Test func chapterDayEveryNWeeksAndHolidaysWin() {
        let standup = StandupCalendar(sprintWeeks: 0, chapterWeekday: 6, chapterEveryWeeks: 3, chapterAnchor: day(2026, 11, 16), frenchHolidays: true)
        #expect(standup.skip(on: day(2026, 11, 20), calendar: calendar) == .chapter)
        #expect(standup.skip(on: day(2026, 11, 27), calendar: calendar) == nil)
        #expect(standup.skip(on: day(2026, 12, 11), calendar: calendar) == .chapter)
        #expect(standup.skip(on: day(2026, 12, 25), calendar: calendar) == .holiday("Noël"))
    }
}
