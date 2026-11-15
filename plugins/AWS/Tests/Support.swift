import DashKit
import Foundation
import SwiftData

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(_ prompt: PermissionPrompt) async -> Bool { false }
}

@MainActor
final class FakeDashii: DashiiService {
    var model: String { "test" }
    func complete(_ request: DashiiRequest) async throws -> String { "" }
}

/// A feature that declares which integrations it needs or can use.
@MainActor
final class FakeFeature: DashExtension {
    let id: String
    let name: String
    let systemImage = "testtube.2"
    let requires: [String]
    let optional: [String]

    init(_ id: String, requires: [String] = [], optional: [String] = []) {
        self.id = id
        self.name = id.capitalized
        self.requires = requires
        self.optional = optional
    }
}

/// Stands in for Dash's extension host.
@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let dashii: any DashiiService = FakeDashii()
    let activity = ActivityLog()

    init(_ extensions: [any DashExtension]) {
        let container = try! ModelContainer(for: Schema([]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) {}
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}
