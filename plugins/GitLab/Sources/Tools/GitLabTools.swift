import DashKit
import Foundation

/// GitLab for Dashii: readers of what Dash fetched (merge requests, raw calls, tags, ranges), then
/// the release mirror's sync tools, which only other extensions run.
extension GitLabIntegration {
    var tools: [DashiiTool] { readers + syncTools }
}
