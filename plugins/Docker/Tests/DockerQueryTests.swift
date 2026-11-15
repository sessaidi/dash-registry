import DashKit
import Foundation
import Testing

/// Docker containers in DashQL: rows, the `containers` dataset, and the widget's query.
@MainActor
struct DockerQueryTests {
    @Test func rowsDatasetAndWidgetQuery() async throws {
        let containers = [
            DockerContainer(id: "a1b2c3d4e5f6a7b8", name: "api", image: "ghcr.io/acme/api:1.42", state: "running", status: "Up 3 hours (healthy)"),
            DockerContainer(id: "b1", name: "migrations", image: "ghcr.io/acme/api:1.42", state: "exited", status: "Exited (1) 2 minutes ago"),
            DockerContainer(id: "c1", name: "postgres", image: "postgres:16", state: "running", status: "Up 3 hours (unhealthy)"),
        ]
        #expect(containers[0].queryRow["id"] == "a1b2c3d4e5f6" && containers[1].queryRow["exit_code"] == 1)
        let failing = try #require(try WidgetQuery("where health = unhealthy or exit_code > 0 | sort name", fields: ContainersWidget.queryFields))
        #expect(await failing.apply(to: containers, row: \.queryRow).map(\.name) == ["migrations", "postgres"])
        let feature = DockerContainersFeature()
        #expect(feature.datasets.map(\.name) == ["containers"])
    }
}
