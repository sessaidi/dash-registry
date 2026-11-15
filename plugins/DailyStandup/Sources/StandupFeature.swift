import DashKit
import Foundation
import Observation
import SwiftData
import SwiftUI

/// The daily standup, every working day: your update (what you did since the last standup,
/// what's next, what blocks you) prepared before the meeting from what Dash already knows
/// (commits, PRs, tickets, agents, workspaces, notes, meetings), blockers carried until they're
/// resolved, and on the days the standup is on Zoom, the meeting followed live (who spoke,
/// who's left) and a report at the end (each person's update, blockers, action items).
@MainActor
@Observable
final class DailyStandupFeature: DashExtension {
    let id = "daily-standup"
    let name = "Daily Standup"
    let systemImage = "person.3.sequence"
    let metadata = ExtensionMetadata(
        version: "1.0.0", author: .dash,
        summary: "Your daily update from commits, PRs, tickets and agents; blockers tracked day to day; Zoom standups followed and reported.",
        category: .productivity, tags: ["standup", "daily", "zoom"], homepage: "https://github.com/sessaidi/dash", minimumDashKit: "1.2.0")
    /// Zoom for the meeting days; the rest (PRs, Jira, Agents, Workspaces, Notes, Knowledge) is used when installed.
    let requires = ["zoom"]
    let optional = ["pull-requests", "jira-board", "agents", "workspaces"]

    /// The standup's time, "HH:mm".
    var time: String { didSet { defaults.set(time, forKey: "daily-standup.time") } }
    /// Working days (1 = Sunday … 7 = Saturday): a report every one of them.
    var workdays: Set<Int> { didSet { defaults.set(Array(workdays).sorted(), forKey: "daily-standup.workdays") } }
    /// The days the standup is a Zoom meeting: transcribed, followed and reported.
    var zoomDays: Set<Int> { didSet { defaults.set(Array(zoomDays).sorted(), forKey: "daily-standup.zoomDays") } }
    /// Meeting titles that mean "the standup".
    var keywords: String { didSet { defaults.set(keywords, forKey: "daily-standup.keywords") } }
    /// Your name as Zoom shows it, and your git email (for your commits).
    var myName: String { didSet { defaults.set(myName, forKey: "daily-standup.myName") } }
    var gitEmail: String { didSet { defaults.set(gitEmail, forKey: "daily-standup.gitEmail") } }
    /// Where clones live (the Agents plugin's code folder).
    var codeRoot: String { didSet { defaults.set(codeRoot, forKey: "daily-standup.codeRoot") } }
    /// Prepare your update this many minutes before the standup.
    var prepareMinutesBefore: Int { didSet { defaults.set(prepareMinutesBefore, forKey: "daily-standup.prepareBefore") } }
    /// Sprints, ceremony and chapter days, and French holidays.
    var calendar: StandupCalendar {
        didSet {
            defaults.set(calendar.sprintWeeks, forKey: "daily-standup.sprintWeeks")
            defaults.set(calendar.sprintStart, forKey: "daily-standup.sprintStart")
            defaults.set(calendar.ceremonyWeekday, forKey: "daily-standup.ceremonyWeekday")
            defaults.set(calendar.ceremonyWeek, forKey: "daily-standup.ceremonyWeek")
            defaults.set(calendar.chapterWeekday, forKey: "daily-standup.chapterWeekday")
            defaults.set(calendar.chapterEveryWeeks, forKey: "daily-standup.chapterEveryWeeks")
            defaults.set(calendar.chapterAnchor, forKey: "daily-standup.chapterAnchor")
            defaults.set(calendar.frenchHolidays, forKey: "daily-standup.frenchHolidays")
        }
    }

    private(set) var isPreparing = false
    private(set) var isReporting = false
    private(set) var lastError: String?
    /// The meeting followed live: who spoke, who's speaking, who's left (from Zoom).
    private(set) var live: JSONValue?
    var revision = 0

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var meetings: ActivitySubscription?
    @ObservationIgnored private var reportedMeetings = Set<String>()

    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        time = defaults.string(forKey: "daily-standup.time") ?? "10:00"
        workdays = Set(defaults.array(forKey: "daily-standup.workdays") as? [Int] ?? [2, 3, 4, 5, 6])
        zoomDays = Set(defaults.array(forKey: "daily-standup.zoomDays") as? [Int] ?? [2, 3, 4, 5, 6])
        var calendar = StandupCalendar()
        calendar.sprintWeeks = defaults.object(forKey: "daily-standup.sprintWeeks") as? Int ?? 2
        calendar.sprintStart = defaults.object(forKey: "daily-standup.sprintStart") as? Date ?? StandupCalendar.defaultAnchor
        calendar.ceremonyWeekday = defaults.object(forKey: "daily-standup.ceremonyWeekday") as? Int ?? 0
        calendar.ceremonyWeek = defaults.object(forKey: "daily-standup.ceremonyWeek") as? Int ?? 2
        calendar.chapterWeekday = defaults.object(forKey: "daily-standup.chapterWeekday") as? Int ?? 0
        calendar.chapterEveryWeeks = defaults.object(forKey: "daily-standup.chapterEveryWeeks") as? Int ?? 4
        calendar.chapterAnchor = defaults.object(forKey: "daily-standup.chapterAnchor") as? Date ?? StandupCalendar.defaultAnchor
        calendar.frenchHolidays = defaults.object(forKey: "daily-standup.frenchHolidays") as? Bool ?? true
        self.calendar = calendar
        keywords = defaults.string(forKey: "daily-standup.keywords") ?? "standup, stand-up, daily, scrum"
        myName = defaults.string(forKey: "daily-standup.myName") ?? NSFullUserName()
        gitEmail = defaults.string(forKey: "daily-standup.gitEmail") ?? ""
        codeRoot = defaults.string(forKey: "daily-standup.codeRoot") ?? (DashStorage.defaults.string(forKey: "agents.codeRoot") ?? "~/Codes")
        prepareMinutesBefore = defaults.object(forKey: "daily-standup.prepareBefore") as? Int ?? 20
    }

    var models: [any PersistentModel.Type] { [StandupDay.self, StandupBlocker.self] }
    var widgets: [WidgetType] { [WidgetType(DailyStandupWidget.self)] }
    func settingsView() -> AnyView { AnyView(StandupSettings(standup: self)) }

    func start(host: any ExtensionContext) {
        self.host = host
        // The meeting's end on a Zoom day: report it.
        meetings?.cancel()
        meetings = host.activity.onEmit { [weak self] event in
            guard event.kind == "meeting.ended" else { return }
            Task { @MainActor in await self?.meetingEnded() }
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        meetings?.cancel()
        meetings = nil
    }

    // MARK: Days

    /// A working day that isn't a public holiday: an update is prepared.
    func isWorkday(_ date: Date = .now) -> Bool {
        guard workdays.contains(Calendar.current.component(.weekday, from: date)) else { return false }
        if case .holiday = calendar.skip(on: date) { return false }
        return true
    }

    /// The daily happens on Zoom: a Zoom weekday that isn't a holiday, ceremony or chapter day.
    func isZoomDay(_ date: Date = .now) -> Bool {
        isWorkday(date) && zoomDays.contains(Calendar.current.component(.weekday, from: date)) && calendar.skip(on: date) == nil
    }

    /// Today's standup time.
    func standupDate(on day: Date = .now) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 10, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: day) ?? day
    }

    func day(_ date: Date = .now) -> StandupDay? {
        let key = StandupDayKey.key(date)
        return try? host?.context.fetch(FetchDescriptor<StandupDay>(predicate: #Predicate { $0.day == key })).first
    }

    func days(limit: Int = 30) -> [StandupDay] {
        var descriptor = FetchDescriptor<StandupDay>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? host?.context.fetch(descriptor)) ?? []
    }

    private func dayRecord(_ date: Date = .now) -> StandupDay? {
        if let existing = day(date) { return existing }
        guard let context = host?.context else { return nil }
        let record = StandupDay(day: StandupDayKey.key(date), date: Calendar.current.startOfDay(for: date), onZoom: isZoomDay(date))
        context.insert(record)
        try? context.save()
        return record
    }

    /// Every 15 s: prepare the update before the standup; during it on a Zoom day, follow the meeting.
    func tick(now: Date = .now) async {
        guard isWorkday(now) else { live = nil; return }
        let meeting = standupDate(on: now)
        if now >= meeting.addingTimeInterval(-Double(prepareMinutesBefore) * 60), day(now)?.preparedAt == nil, !isPreparing {
            _ = try? await prepare()
        }
        if isZoomDay(now), abs(now.timeIntervalSince(meeting)) < 3600 {
            live = try? await tool("meeting_speakers", ["meeting_id": "current"])
        } else {
            live = nil
        }
    }

    // MARK: Your update

    static let prepareTask = AITask(
        id: "prepare", title: "Your update",
        summary: "Writes your standup update (since the last standup, today, blockers) from your commits, PRs, tickets, agents, deploys, notes and meetings.",
        models: [.balanced, .fast, .strong], defaultModel: .balanced, efforts: [.low, .medium], defaultEffort: .low,
        templates: [AITemplate(id: "style", title: "Style", defaultText: "Short bullets in the first person, the way I'd say them in the standup. Group related work. No jargon nobody else knows.", multiline: true)])

    static let reportTask = AITask(
        id: "report", title: "Meeting report",
        summary: "After a Zoom standup: each person's update, blockers and action items, from the transcript and who spoke.",
        models: [.balanced, .strong, .fast], defaultModel: .balanced, efforts: [.low, .medium, .high], defaultEffort: .medium)

    var aiTasks: [AITask] { [Self.prepareTask, Self.reportTask] }
    var ai: AISettings { host?.aiSettings(.extension(id), tasks: aiTasks) ?? AISettings(tasks: aiTasks) }

    static let updateSchema: JSONValue = {
        let refs: JSONValue = ["type": "array", "items": ["type": "string"], "description": "Commit SHAs, PR ids, ticket keys, workspace names that show it."]
        let ticket: JSONValue = ["type": "string", "description": "The ticket key (e.g. LAF-5680) from the branch, commit, PR title or agent session; empty if none."]
        let item: JSONValue = ["type": "object", "additionalProperties": false, "required": ["ticket", "text", "refs"],
                               "properties": ["ticket": ticket, "text": ["type": "string"], "refs": refs]]
        let next: JSONValue = ["type": "object", "additionalProperties": false, "required": ["ticket", "text", "refs", "kind"],
                               "properties": ["ticket": ticket, "text": ["type": "string"], "refs": refs,
                                              "kind": ["type": "string", "enum": ["fix", "continue", "waiting", "review", "start", "other"],
                                                       "description": "fix: what broke or was flagged (failing build/workspace/agent, changes requested). continue: work in progress. waiting: on a review or someone else. review: someone's PR waiting for me. start: the next ticket to take. other."]]]
        return ["type": "object", "additionalProperties": false, "required": ["yesterday", "today", "blockers"],
                "properties": ["yesterday": ["type": "array", "items": item], "today": ["type": "array", "items": next], "blockers": ["type": "array", "items": item]]]
    }()

    /// Calls another extension's tool when it's installed (nil otherwise).
    func tool(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue? {
        guard let host, let tool = host.extensions.filter({ host.isEnabled($0) }).flatMap(\.tools).first(where: { $0.name == name }) else { return nil }
        return try await tool.run(input)
    }

    /// What happened since the last standup, from the data Dash already has.
    func evidence(since: Date) async -> JSONValue {
        var result: [String: JSONValue] = ["since": .string(since.formatted(.iso8601))]
        result["commits"] = .array(StandupGit.commits(root: codeRoot, email: gitEmail, since: since).map {
            ["repo": .string($0.repo), "sha": .string($0.sha), "subject": .string($0.subject), "at": .string($0.at.formatted(.iso8601)), "branch": .string($0.branch)]
        })
        if let pulls = try? await tool("github_list_prs") {
            result["pull_requests"] = .array((pulls.array ?? []).filter { pr in
                pr["mine"]?.bool == true || pr["review_requested"]?.bool == true
            })
        }
        if let issues = try? await tool("jira_list_issues", ["scope": "followed"]) {
            result["tickets"] = .array((issues.array ?? []).filter { issue in
                guard let updated = issue["updated"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return issue["statusCategory"]?.string == "indeterminate" }
                return updated >= since || issue["statusCategory"]?.string == "indeterminate"
            })
        }
        if let agents = try? await tool("agents_list") { result["agents"] = agents }
        if let workspaces = try? await tool("workspaces_list", ["mine": true]) { result["workspaces"] = workspaces }
        if let notes = try? await tool("notes_search", ["query": ""]) {
            result["notes"] = .array((notes.array ?? []).filter { note in
                note["modified"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0 >= since } ?? false
            })
        }
        if let meetings = try? await tool("meetings_list") {
            result["meetings"] = .array((meetings.array ?? []).filter { meeting in
                meeting["started"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0 >= since } ?? false
            }.map { ["title": $0["title"] ?? .null, "started": $0["started"] ?? .null, "action_items": $0["action_items"] ?? .null] })
        }
        if let host {
            result["dash_activity"] = .array(host.activity.events(since: since, minimum: .notable).suffix(80).map {
                ["at": .string($0.date.formatted(.iso8601)), "kind": .string($0.kind), "title": .string($0.title)]
            })
        }
        // Candidates for "take another ticket": followed tickets not started, most important first.
        if let todo = try? await tool("jira_list_issues", ["scope": "followed"]) {
            let order = ["highest": 0, "blocker": 0, "critical": 0, "high": 1, "medium": 2, "low": 3, "lowest": 4]
            result["next_tickets"] = .array(Array((todo.array ?? []).filter { $0["statusCategory"]?.string == "new" }
                .sorted { (order[($0["priority"]?.string ?? "").lowercased()] ?? 2) < (order[($1["priority"]?.string ?? "").lowercased()] ?? 2) }
                .prefix(5)))
        }
        result["open_blockers"] = .array(openBlockers().filter { $0.owner == myName || $0.owner.isEmpty }.map {
            ["text": .string($0.text), "since": .string($0.since.formatted(date: .abbreviated, time: .omitted)), "reference": .string($0.reference)]
        })
        return .object(result)
    }

    /// Prepares (or re-prepares) today's update.
    @discardableResult
    func prepare(now: Date = .now) async throws -> StandupUpdate {
        guard let host, let record = dayRecord(now) else { throw ToolError("Daily Standup isn't ready.") }
        isPreparing = true
        defer { isPreparing = false }
        let since = StandupDayKey.previousWorkday(before: now, workdays: workdays)
        let evidence = await evidence(since: since)
        let style = ai.render(Self.prepareTask.id, "style", [:])
        do {
            let text = try await host.dashii.complete(
                task: Self.prepareTask.id, settings: ai,
                system: """
                    You write \(myName)'s daily standup update from their activity, as they'd say it: "Yesterday I did…", "Today I will…". \
                    Every item names its ticket (the key from the branch, commit subjects, PR title or agent session) and says concretely what was done \
                    or will be done on it (e.g. "finished the renewal endpoint and its tests", "fix the failing proration test"). "yesterday": what they did since \(since.formatted(date: .complete, time: .omitted)) \
                    (merge the commits, PRs, tickets, agent work and deploys about the same thing into one item). "today": the next steps, each with its kind, \
                    most urgent first: fix what broke or was flagged yesterday (changes requested, failing workspace or agent, failing tests); continue the \
                    implementation in progress; say what's waiting for review or for someone; review PRs others asked them to; and when nothing is in \
                    progress, start the next ticket (the highest-priority followed ticket not started, from next_tickets). "blockers": what stops them \
                    (blocked tickets, PRs waiting for others for long, failing workspaces or agents, open blockers still true). Every item gives its refs. \
                    Only what the data shows. \(style)
                    """,
                prompt: evidence.jsonString(), outputSchema: Self.updateSchema)
            let update = try JSONValue.parse(text).decode(StandupUpdate.self)
            record.update = update
            record.evidenceData = Data(evidence.jsonString().utf8)
            record.preparedAt = .now
            for blocker in update.blockers { remember(blocker.text, owner: myName, reference: blocker.refs.first ?? "") }
            try? host.context.save()
            lastError = nil
            revision += 1
            host.emit("standup.prepared", from: self, title: "Your standup update is ready", detail: update.text, importance: .notable)
            return update
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: The meeting (Zoom days)

    static let reportSchema: JSONValue = {
        let person: JSONValue = ["type": "object", "additionalProperties": false, "required": ["name", "yesterday", "today", "blockers"],
                                 "properties": ["name": ["type": "string"], "yesterday": ["type": "array", "items": ["type": "string"]],
                                                "today": ["type": "array", "items": ["type": "string"]], "blockers": ["type": "array", "items": ["type": "string"]]]]
        let action: JSONValue = ["type": "object", "additionalProperties": false, "required": ["owner", "task"],
                                 "properties": ["owner": ["type": "string"], "task": ["type": "string"]]]
        return ["type": "object", "additionalProperties": false, "required": ["summary", "people", "blockers", "actionItems"],
                "properties": ["summary": ["type": "string"], "people": ["type": "array", "items": person],
                               "blockers": ["type": "array", "items": action], "actionItems": ["type": "array", "items": action]]]
    }()

    /// Whether a meeting is the standup: on a Zoom day, near the standup time or titled like one.
    func isStandup(title: String, started: Date) -> Bool {
        guard isZoomDay(started) else { return false }
        let words = keywords.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return abs(started.timeIntervalSince(standupDate(on: started))) < 45 * 60 || words.contains { title.lowercased().contains($0) }
    }

    func meetingEnded() async {
        guard let latest = (try? await tool("meetings_list"))??.array?.first, let id = latest["id"]?.string, !reportedMeetings.contains(id),
              let started = latest["started"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }),
              isStandup(title: latest["title"]?.string ?? "", started: started) else { return }
        reportedMeetings.insert(id)
        _ = try? await report(meetingID: id)
    }

    /// The report of a standup meeting: each person's update, blockers, action items; stored,
    /// written as a note, blockers remembered.
    @discardableResult
    func report(meetingID: String) async throws -> MeetingReport {
        guard let host else { throw ToolError("Daily Standup isn't ready.") }
        isReporting = true
        defer { isReporting = false }
        guard let transcript = try await tool("meeting_transcript", ["meeting_id": .string(meetingID)]) else { throw ToolError("Install the Zoom plugin.") }
        let speakers = try await tool("meeting_speakers", ["meeting_id": .string(meetingID)])
        let named = speakers?["named"]?.bool ?? false
        let started = transcript["started"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now
        let text = try await host.dashii.complete(
            task: Self.reportTask.id, settings: ai,
            system: """
                You write the report of a daily standup from its transcript. For each participant: what they did, what they'll do, what blocks them. \
                Then all blockers (with their owner) and action items. \(named ? "Lines carry each speaker's name from Zoom's captions." : "Lines from other people are labeled \"Others\": attribute them to participants from what they say (names, turn order, \"thanks X, your turn\"); when unsure, say \"unattributed\".") \
                The user is \(myName). Use only what was said.
                """,
            prompt: "Participants: \((transcript["participants"]?.array ?? []).compactMap(\.string).joined(separator: ", "))\nSpeakers: \(speakers?.jsonString() ?? "unknown")\n\nTranscript:\n\(transcript["transcript"]?.string ?? "")",
            outputSchema: Self.reportSchema)
        let json = try JSONValue.parse(text)
        let words = Dictionary((speakers?["speakers"]?.array ?? []).compactMap { speaker -> (String, Int)? in
            guard let name = speaker["name"]?.string else { return nil }
            return (name, speaker["words"]?.int ?? 0)
        }, uniquingKeysWith: { first, _ in first })
        var report = MeetingReport(
            summary: json["summary"]?.string ?? "",
            people: (try? json["people"]?.decode([MeetingReport.Person].self)) ?? [],
            blockers: (try? json["blockers"]?.decode([MeetingReport.Action].self)) ?? [],
            actionItems: (try? json["actionItems"]?.decode([MeetingReport.Action].self)) ?? [],
            notHeard: (speakers?["not_heard_yet"]?.array ?? []).compactMap(\.string), namesFromCaptions: named)
        for index in report.people.indices { report.people[index].words = words[report.people[index].name] }
        let record = dayRecord(started)
        record?.meetingID = meetingID
        record?.report = report
        record?.reportedAt = .now
        for blocker in report.blockers { remember(blocker.task, owner: blocker.owner) }
        if let url = try? host.createNote(title: "Standup \(StandupDayKey.key(started))", markdown: Self.markdown(report, update: record?.update, day: started), folder: "Standups") {
            record?.notePath = url.path
        }
        try? host.context.save()
        revision += 1
        host.emit("standup.reported", from: self, title: "Standup report ready", detail: report.summary, importance: .notable)
        return report
    }

    static func markdown(_ report: MeetingReport, update: StandupUpdate?, day: Date) -> String {
        var text = "# Standup \(day.formatted(date: .complete, time: .omitted))\n\n\(report.summary)\n\n"
        if let update {
            text += "## My update\n\n" + update.text.replacingOccurrences(of: "*", with: "**") + "\n"
        }
        text += "## Everyone\n\n"
        for person in report.people {
            text += "### \(person.name)\(person.words.map { " · \($0) words" } ?? "")\n\n"
            if !person.yesterday.isEmpty { text += "**Did:** " + person.yesterday.joined(separator: "; ") + "\n\n" }
            if !person.today.isEmpty { text += "**Next:** " + person.today.joined(separator: "; ") + "\n\n" }
            if !person.blockers.isEmpty { text += "**Blocked by:** " + person.blockers.joined(separator: "; ") + "\n\n" }
        }
        if !report.blockers.isEmpty { text += "## Blockers\n\n" + report.blockers.map { "- [ ] \($0.task) (\($0.owner))" }.joined(separator: "\n") + "\n\n" }
        if !report.actionItems.isEmpty { text += "## Action items\n\n" + report.actionItems.map { "- [ ] \($0.owner): \($0.task)" }.joined(separator: "\n") + "\n\n" }
        if !report.notHeard.isEmpty { text += "_Didn't speak: \(report.notHeard.joined(separator: ", "))._\n" }
        if !report.namesFromCaptions { text += "\n_Speakers were attributed from the conversation (Zoom captions were off)._\n" }
        return text
    }

    // MARK: Blockers

    func openBlockers() -> [StandupBlocker] {
        ((try? host?.context.fetch(FetchDescriptor<StandupBlocker>(sortBy: [SortDescriptor(\.since)]))) ?? []).filter { $0.resolvedAt == nil }
    }

    /// Adds a blocker, or marks a known one as mentioned again.
    func remember(_ text: String, owner: String, reference: String = "") {
        guard let context = host?.context, !text.isEmpty else { return }
        let key = text.lowercased().prefix(60)
        if let known = openBlockers().first(where: { $0.owner == owner && $0.text.lowercased().prefix(60) == key }) {
            known.lastMentioned = .now
        } else {
            context.insert(StandupBlocker(text: text, owner: owner, reference: reference))
        }
        try? context.save()
    }

    func resolve(_ blocker: StandupBlocker) {
        blocker.resolvedAt = .now
        try? host?.context.save()
        revision += 1
    }

    // MARK: Claude, Home, knowledge

    private struct DayInput: Decodable { let date: String? }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "standup_today", description: "Today's standup: my update (yesterday, today, blockers with references), and on Zoom days the meeting report (each person's update, blockers, action items).") { [weak self] _ in
                guard let self, let record = day() else { return ["prepared": false] }
                return ["prepared": .bool(record.preparedAt != nil), "update": .string(record.update?.text ?? ""),
                        "report": (try? JSONValue(encoding: record.report)) ?? .null, "on_zoom": .bool(record.onZoom)]
            },
            DashiiTool(name: "standup_prepare", description: "Prepare (or redo) my standup update now from my commits, PRs, tickets, agents, deploys, notes and meetings since the last standup.") { [weak self] _ in
                guard let self else { return nil }
                return .string(try await prepare().text)
            },
            DashiiTool(name: "standup_blockers", description: "Open blockers from past standups (mine and the team's), with how long they've been open.") { [weak self] _ in
                guard let self else { return [] }
                return .array(openBlockers().map { ["text": .string($0.text), "owner": .string($0.owner), "days_open": .number(Double($0.daysOpen)), "reference": .string($0.reference)] })
            },
            DashiiTool(name: "standup_history", description: "Past standups (date, my update, meeting summary).",
                       properties: ["date": JSONSchema.string("Optional yyyy-MM-dd.")]) { [weak self] input in
                guard let self else { return [] }
                let wanted = try input.toolInput(DayInput.self).date
                return .array(days().filter { wanted == nil || $0.day == wanted }.map {
                    ["date": .string($0.day), "update": .string($0.update?.text ?? ""), "summary": .string($0.report?.summary ?? "")]
                })
            },
        ]
    }

    var suggestions: [Suggestion] {
        guard isWorkday() else { return [] }
        let meeting = standupDate()
        let minutes = Int(meeting.timeIntervalSinceNow / 60)
        guard (-15...90).contains(minutes) else { return [] }
        if let update = day()?.update {
            return [Suggestion(id: "standup.ready", title: minutes > 0 ? "Standup in \(minutes) min: your update is ready" : "Standup now: your update",
                               detail: update.yesterday.first?.text, icon: "person.3.sequence", priority: .high,
                               prompt: "Show my standup update for today (standup_today).")]
        }
        return [Suggestion(id: "standup.prepare", title: "Prepare your standup update", detail: "From your commits, PRs, tickets and agents since the last standup.",
                           icon: "person.3.sequence", priority: .high, prompt: "Prepare my standup update (standup_prepare).")]
    }

    var events: [EventDefinition] {
        [EventDefinition("standup.prepared", "Your standup update was prepared."),
         EventDefinition("standup.reported", "The report of a Zoom standup is ready.")]
    }

    var knowledge: [KnowledgeEntity] {
        days(limit: 60).map { day in
            KnowledgeEntity(id: "standup:\(day.day)", kind: "meeting", title: "Standup \(day.day)",
                            text: (day.update?.text ?? "") + "\n" + (day.report?.summary ?? ""), updated: day.reportedAt ?? day.preparedAt ?? day.date)
        }
    }

    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "blockers", title: "Blockers raised", unit: "blockers", systemImage: "exclamationmark.octagon") { [weak self] interval in
            let all = (try? self?.host?.context.fetch(FetchDescriptor<StandupBlocker>())) ?? []
            return ActivitySeries.countPerDay(all.map(\.since), in: interval)
        }]
    }
}

/// Your commits in the clones under the code folder (worktrees share their clone's history).
enum StandupGit {
    struct Commit: Sendable, Hashable {
        let repo: String
        let sha: String
        let subject: String
        let at: Date
        let branch: String
    }

    static func commits(root: String, email: String, since: Date) -> [Commit] {
        let folder = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        let clones = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
        var result: [Commit] = []
        for clone in clones {
            let author = email.isEmpty ? (git(clone, ["config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : email
            guard !author.isEmpty,
                  let log = git(clone, ["log", "--all", "--no-merges", "--author=\(author)", "--since=\(ISO8601DateFormatter().string(from: since))",
                                        "--format=%h%x1f%ct%x1f%s%x1f%D"]) else { continue }
            for line in log.split(separator: "\n") {
                let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3, let seconds = Double(parts[1]) else { continue }
                let branch = parts.count > 3 ? (parts[3].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "HEAD -> ", with: "") } ?? "") : ""
                result.append(Commit(repo: clone.lastPathComponent, sha: parts[0], subject: parts[2], at: Date(timeIntervalSince1970: seconds), branch: branch))
            }
        }
        return result.sorted { $0.at > $1.at }
    }

    static func git(_ folder: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
