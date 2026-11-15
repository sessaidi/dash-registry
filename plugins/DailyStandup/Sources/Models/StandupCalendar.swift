import Foundation

/// The team calendar the standup follows: sprints of N weeks with a ceremony day (review,
/// retro, planning: no daily), a chapter day every M weeks (no daily either), and French public
/// holidays (no standup at all).
struct StandupCalendar: Equatable, Sendable {
    /// Sprint length in weeks; 0 means no sprints.
    var sprintWeeks: Int = 2
    /// Any day of the first week of a sprint.
    var sprintStart: Date = StandupCalendar.defaultAnchor
    /// The ceremony day: a weekday (1 Sunday … 7 Saturday) in the sprint's `ceremonyWeek`; 0 none.
    var ceremonyWeekday: Int = 0
    /// Which week of the sprint (1-based) the ceremony day falls in; usually the last.
    var ceremonyWeek: Int = 2
    /// The chapter day: a weekday (1 Sunday … 7 Saturday) every `chapterEveryWeeks`; 0 none.
    var chapterWeekday: Int = 0
    var chapterEveryWeeks: Int = 4
    /// Any day of a week that has a chapter day.
    var chapterAnchor: Date = StandupCalendar.defaultAnchor
    /// France's public holidays: no standup.
    var frenchHolidays = true

    static let defaultAnchor = Calendar.current.startOfDay(for: .now)

    enum Skip: Equatable, Sendable {
        case holiday(String)
        case ceremony
        case chapter

        var reason: String {
            switch self {
            case .holiday(let name): "Public holiday: \(name)"
            case .ceremony: "Sprint ceremony day: no daily"
            case .chapter: "Chapter day: no daily"
            }
        }
    }

    /// Why there's no standup meeting on `date`, if there isn't one.
    func skip(on date: Date, calendar: Calendar = .current) -> Skip? {
        if frenchHolidays, let name = Self.frenchHoliday(on: date, calendar: calendar) { return .holiday(name) }
        let weekday = calendar.component(.weekday, from: date)
        if sprintWeeks > 0, ceremonyWeekday != 0, weekday == ceremonyWeekday,
           Self.mod(Self.weekIndex(of: date, from: sprintStart, calendar: calendar), sprintWeeks) == min(max(ceremonyWeek, 1), sprintWeeks) - 1 {
            return .ceremony
        }
        if chapterWeekday != 0, chapterEveryWeeks > 0, weekday == chapterWeekday,
           Self.mod(Self.weekIndex(of: date, from: chapterAnchor, calendar: calendar), chapterEveryWeeks) == 0 {
            return .chapter
        }
        return nil
    }

    /// The sprint `date` falls in (1-based) and its day count, for display.
    func sprint(on date: Date, calendar: Calendar = .current) -> (number: Int, week: Int)? {
        guard sprintWeeks > 0 else { return nil }
        let week = Self.weekIndex(of: date, from: sprintStart, calendar: calendar)
        return (Int((Double(week) / Double(sprintWeeks)).rounded(.down)) + 1, Self.mod(week, sprintWeeks) + 1)
    }

    /// Whole weeks (Monday-based) from `anchor`'s week to `date`'s week; negative before it.
    static func weekIndex(of date: Date, from anchor: Date, calendar: Calendar = .current) -> Int {
        var monday = calendar
        monday.firstWeekday = 2
        guard let start = monday.dateInterval(of: .weekOfYear, for: anchor)?.start,
              let current = monday.dateInterval(of: .weekOfYear, for: date)?.start else { return 0 }
        let days = monday.dateComponents([.day], from: start, to: current).day ?? 0
        return Int((Double(days) / 7).rounded())
    }

    /// A modulo that stays positive before the anchor, so cycles line up both ways.
    static func mod(_ value: Int, _ modulus: Int) -> Int { ((value % modulus) + modulus) % modulus }

    // MARK: French public holidays

    /// The holiday's name when `date` is a French public holiday.
    static func frenchHoliday(on date: Date, calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let fixed: [String: String] = [
            "1-1": "Jour de l'an", "5-1": "Fête du Travail", "5-8": "Victoire 1945", "7-14": "Fête nationale",
            "8-15": "Assomption", "11-1": "Toussaint", "11-11": "Armistice", "12-25": "Noël",
        ]
        if let name = fixed["\(month)-\(day)"] { return name }
        guard let easter = easter(year, calendar: calendar) else { return nil }
        let moving: [(Int, String)] = [(1, "Lundi de Pâques"), (39, "Ascension"), (50, "Lundi de Pentecôte")]
        for (offset, name) in moving {
            if let holiday = calendar.date(byAdding: .day, value: offset, to: easter), calendar.isDate(holiday, inSameDayAs: date) { return name }
        }
        return nil
    }

    /// Easter Sunday (Gregorian, anonymous algorithm).
    static func easter(_ year: Int, calendar: Calendar = .current) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
