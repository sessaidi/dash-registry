import DashKit
import Foundation
import Testing

/// Workspaces in DashQL: rows, datasets and the widgets' queries.
@MainActor
struct WorkspacesQueryTests {
    @Test func workspaceRowsAndQuery() async throws {
        let items = WorkspaceItem.samples
        let row = try #require(items.first { $0.name == "epg-refresh" }?.queryRow)
        #expect(row["tickets"] == ["LAF-1234"] && row["owner"] == "jrivera")
        let query = try #require(try WidgetQuery("owner:sadik cleanable=true", fields: WorkspacesWidget.queryFields))
        #expect(await query.apply(to: items, row: \.queryRow).map(\.name) == ["old-search"])
        let recent = try #require(try WidgetQuery("last_deploy>-1d | sort -last_deploy", fields: WorkspacesWidget.queryFields))
        #expect(await recent.apply(to: items, row: \.queryRow).map(\.name) == ["epg-refresh", "checkout-flow"])
    }

    @Test func trainRowsAndDatasets() async throws {
        let cars = [
            TrainCar(id: "1", workspace: "laf-5680", kind: "worktree", app: "papi", version: "a1b2", branch: "feat/LAF-5680-renewals", by: "ada",
                     at: .now.addingTimeInterval(-600), duration: 300, status: "succeeded", error: ""),
            TrainCar(id: "2", workspace: "ops-212", kind: "worktree", app: "user", version: "9f8e", branch: "fix/ops-212", by: "sam",
                     at: .now.addingTimeInterval(-7200), duration: 95, status: "failed", error: "CrashLoopBackOff"),
        ]
        #expect(cars[1].queryRow["tickets"] == ["OPS-212"])
        let failed = try #require(try WidgetQuery("status:failed", fields: DeploymentTrainWidget.queryFields))
        #expect(await failed.apply(to: cars, row: \.queryRow).map(\.id) == ["2"])

        let feature = WorkspacesFeature(defaults: UserDefaults(suiteName: "workspaces-query-\(UUID().uuidString)")!)
        #expect(feature.datasets.map(\.name) == ["workspaces", "deploys"])
        #expect(try await feature.datasets[1].rows(nil).isEmpty)
    }

    @Test func selectionsFindWhatTheUserNames() {
        let items = WorkspaceItem.samples
        #expect(WorkspaceItem.find("EPG-REFRESH", in: items)?.name == "epg-refresh")
        #expect(WorkspaceItem.find("", in: items) == nil)
        let cars = [
            TrainCar(id: "1", workspace: "laf-5680", kind: "worktree", app: "papi", version: "a1b2", branch: "b", by: "ada", at: .now, duration: 1, status: "succeeded", error: ""),
            TrainCar(id: "2", workspace: "laf-5680", kind: "worktree", app: "papi", version: "c3d4", branch: "b", by: "ada", at: .now.addingTimeInterval(-60), duration: 1, status: "failed", error: ""),
        ]
        #expect(TrainCar.find("2", in: cars)?.version == "c3d4")
        #expect(TrainCar.find("LAF-5680", in: cars)?.id == "1")
        #expect(WorkspacesWidget.actions.map(\.name) == ["select", "clear_selection"])
        #expect(DeploymentTrainWidget.actions.map(\.name) == ["select", "clear_selection"])
    }
}
