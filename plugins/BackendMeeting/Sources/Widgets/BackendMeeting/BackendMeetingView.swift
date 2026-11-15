import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The widget body: the stored reports and the live feature, laid out per size by
/// `BackendMeetingLayout`.
struct BackendMeetingView: View {
    let feature: BackendMeetingFeature
    @Binding var config: BackendMeetingWidget.Config
    @Query(sort: \BackendReport.end, order: .reverse) private var reports: [BackendReport]

    var body: some View {
        BackendMeetingLayout(
            reports: reports.map { report in
                let file = feature.fileURL(for: report).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                return ReportDigest(report, file: file)
            },
            progress: feature.progress, config: $config,
            commands: BackendMeetingCommands(
                generate: { range, weeks in try await feature.generate(range: range, cycleWeeks: weeks).id },
                delete: { id in if let report = reports.first(where: { $0.id == id }) { feature.delete(report) } }))
    }
}
