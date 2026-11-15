import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Containers feature: a dashboard widget of local containers, refreshed every 15 s,
/// and activity when a container exits unexpectedly or turns unhealthy.
@MainActor
@Observable
final class DockerContainersFeature: DashExtension {
    let id = "docker-containers"
    let name = "Containers"
    let systemImage = "shippingbox.fill"
    let metadata = ExtensionMetadata(
        version: "1.1.0", author: .dash,
        summary: "A dashboard widget of local Docker containers, with alerts when one crashes or turns unhealthy.",
        category: .cloud, tags: ["docker", "containers"])
    let requires = ["docker"]

    static let interval: Duration = .seconds(15)

    private(set) var containers: [DockerContainer] = []
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var loading = false
    @ObservationIgnored private weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var widgets: [WidgetType] { [WidgetType(ContainersWidget.self)] }

    var integration: DockerIntegration? { host?.integration(DockerIntegration.self) }

    func start(host: any ExtensionContext) {
        self.host = host
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    func refresh() async {
        guard let connection = host?.integration("docker")?.connection else {
            error = "No Docker socket found."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let current = DockerContainer.list(try await connection.get("/containers/json?all=1", service: "Docker"))
            if lastUpdated != nil, let host {
                let intentional = integration?.intentionalReferences ?? []
                for event in ContainerChanges.events(previous: containers, current: current, intentional: intentional) {
                    host.emit(event.kind, from: self, title: event.title, detail: event.detail, importance: event.importance)
                }
            }
            containers = current
            error = nil
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
