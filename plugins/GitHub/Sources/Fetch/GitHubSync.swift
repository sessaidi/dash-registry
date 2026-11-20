import DashKit
import Foundation
import Ingestor

/// What GitHub keeps fetched in the background (Settings › GitHub).
extension GitHubIntegration {
    var syncItems: [IngestSyncItem] {
        let perRepo: @MainActor () -> [JSONValue] = { [weak self] in (self?.repos ?? []).map { ["repo": .string($0)] } }
        return [
            IngestSyncItem(id: "pulls", title: "Open pull requests", detail: "Of each watched repository.",
                           fetcher: "github.pulls", defaultMinutes: 5, inputs: perRepo),
            IngestSyncItem(id: "runs", title: "Actions runs", detail: "The latest runs of each watched repository.",
                           fetcher: "github.workflow_runs", defaultMinutes: 10, inputs: perRepo),
            IngestSyncItem(id: "issues", title: "Open issues", detail: "Of each watched repository.",
                           fetcher: "github.issues", defaultMinutes: 30, defaultOn: false, inputs: perRepo),
            IngestSyncItem(id: "releases", title: "Releases", detail: "The recent releases of each watched repository.",
                           fetcher: "github.releases", defaultMinutes: 60, defaultOn: false, inputs: perRepo),
            IngestSyncItem(id: "notifications", title: "Notifications", detail: "Your unread notifications (none are marked read).",
                           fetcher: "github.notifications", defaultMinutes: 10, defaultOn: false),
        ]
    }

    /// Why the schedule can't fetch now.
    var syncBlocked: String? {
        guard hasToken else { return "Add a token first." }
        if let until = IngestRateLimit.pausedUntil(service: GitHubAPI.service, scope: storeScope, now: now()) {
            return "GitHub's rate limit is used up until \(until.formatted(date: .omitted, time: .shortened))."
        }
        return nil
    }
}
