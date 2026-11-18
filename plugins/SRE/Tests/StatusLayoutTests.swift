import DashKit
import DashKitUI
import SwiftUI
import Testing

/// Every size family renders the sample status (the gallery shows each).
@MainActor
struct StatusLayoutTests {
    static let sizes: [WidgetLayout.Family: CGSize] = [
        .narrow: CGSize(width: 280, height: 260), .medium: CGSize(width: 480, height: 320),
        .wide: CGSize(width: 720, height: 300), .large: CGSize(width: 720, height: 480),
    ]

    @Test(arguments: WidgetLayout.Family.allCases)
    func rendersEachFamily(_ family: WidgetLayout.Family) throws {
        let size = try #require(Self.sizes[family])
        #expect(WidgetLayout.family(for: size) == family)
        for snapshot in [StatusSnapshot.sample, StatusSnapshot(signals: Signals(sources: ["datadog"]), lastReport: nil)] {
            let renderer = ImageRenderer(content: StatusView(snapshot: snapshot, family: family, ask: { _ in }).frame(width: size.width, height: size.height))
            #expect(renderer.nsImage != nil)
        }
    }

    @Test func headlineCounts() {
        #expect(StatusSnapshot.sample.countLine == "3 critical · 3 warning")
        #expect(StatusSnapshot.sample.tone == .danger)
    }
}

/// The report sheet draws a Dash note: callouts for the summary and each finding.
struct ReportDocumentTests {
    @Test func eachFindingIsACalloutInItsSeverityWithEverythingInside() {
        let report = StatusSnapshot.Report(
            summary: "billing-api is down in `bill-eu`.", at: .now, findings: [], critical: true,
            items: [AgentFinding(severity: .critical, title: "api crash-loops", detail: "Evidence:\n\n- 14 restarts\n- `BackOff` since 10:02",
                                 target: "deployment bill-eu/api", suggestion: "1. Roll back to v1.41\n2. Add the key"),
                    AgentFinding(severity: .warning, title: "checkout slow", target: "", suggestion: "Wait for api."),
                    AgentFinding(severity: .info, title: "a `flaky` monitor")])
        let lines = report.markdown.components(separatedBy: "\n")
        #expect(lines.prefix(2) == ["> [!summary] Summary", "> billing-api is down in `bill-eu`."])
        #expect(lines.contains("## Findings"))
        #expect(lines.contains("> [!danger] api crash-loops") && lines.contains("> [!warning] checkout slow") && lines.contains("> [!note] a `flaky` monitor"))
        #expect(lines.contains("> `deployment bill-eu/api`"))
        #expect(lines.contains("> - `BackOff` since 10:02") && lines.contains("> **What to do**") && lines.contains("> 2. Add the key"))
        #expect(lines.contains("> **What to do:** Wait for api."))
        // Between the callouts only blank lines and the heading: nothing escapes a callout.
        #expect(lines.allSatisfy { $0.hasPrefix(">") || $0.isEmpty || $0 == "## Findings" })
    }

    @Test func aQuietReportIsTheSummaryAlone() {
        let report = StatusSnapshot.Report(summary: "All clear.", at: .now, findings: [], critical: false)
        #expect(report.markdown == "> [!summary] Summary\n> All clear.")
    }

    @Test func theWholeReportIsTheSummaryThenEachFinding() {
        let finding = AgentFinding(severity: .warning, title: "checkout slow")
        let report = StatusSnapshot.Report(summary: "One issue.", at: .now, findings: [], critical: false, items: [finding])
        #expect(report.markdown == [report.summaryMarkdown, "## Findings", StatusSnapshot.Report.markdown(for: finding)].joined(separator: "\n\n"))
    }

    @MainActor
    @Test func theSheetDrawsEveryFindingWithItsButtons() {
        let report = StatusSnapshot.Report(summary: "One issue.", at: .now, findings: ["api crash-loops"], critical: true,
                                           items: [AgentFinding(severity: .critical, title: "api crash-loops", detail: "- 14 restarts", suggestion: "Roll back.")])
        let sheet = ReportSheet(report: report).environment(\.sreAsk) { _ in }.environment(\.sreMarkdown) { AnyView(Text($0)) }
        #expect(ImageRenderer(content: sheet.frame(width: 680, height: 560)).nsImage != nil)
    }

    @Test func theAgentsWriteInNoteSyntax() {
        #expect(SREAgents.all.allSatisfy { $0.instructions.contains("Dash's note syntax") })
    }
}

/// Asking about one item: the prompt names that item alone.
struct SignalQuestionTests {
    @Test func aPodOrMonitorIsAskedAboutOnItsOwn() {
        let pod = StatusSnapshot.sample.signals.pods[0]
        let monitor = StatusSnapshot.sample.signals.monitors[0]
        #expect(pod.subject == "Pod api-7d9f8-x2k (pod bill-eu/api-7d9f8-x2k: CrashLoopBackOff in bill-eu · 14 restarts · BackOff)")
        #expect(monitor.subject.hasPrefix("api 5xx rate (monitor 1201:"))
        let investigate = SREQuestion.investigate.prompt(about: pod.subject)
        #expect(investigate.hasPrefix("Ask the on-call SRE (agent sre.oncall ask): investigate only this"))
        #expect(investigate.contains("bill-eu/api-7d9f8-x2k") && !investigate.contains("api 5xx rate"))
        #expect(SREQuestion.explain.prompt(about: monitor.subject).hasPrefix("Explain this to me in plain words"))
    }

    @Test func aFindingIsAskedAboutWithItsEvidenceAndTheUserFixesIt() {
        let finding = AgentFinding(severity: .warning, title: "api never becomes Ready", detail: "Evicted every 2 minutes.",
                                   target: "deployment bill-eu/api", suggestion: "Add anti-affinity.")
        #expect(finding.subject == "the on-call SRE's warning finding “api never becomes Ready” on deployment bill-eu/api "
            + "(evidence: Evicted every 2 minutes.; suggested: Add anti-affinity.)")
        let fix = SREQuestion.fix.prompt(about: finding.subject)
        #expect(fix.hasPrefix("Ask the on-call SRE (agent sre.oncall ask): only this") && fix.contains("You change nothing yourself"))
        #expect(SREQuestion.allCases.map(\.shortLabel) == ["Explain", "Dig Deeper", "How to Fix"])
    }
}
