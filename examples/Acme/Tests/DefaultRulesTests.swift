import DashKit
import Foundation
import Testing

/// Every extension of the plugin gives Dashii default rules, shipped as Rules/<id>.md.
@MainActor
struct DefaultRulesTests {
    @Test func everyExtensionHasRules() {
        for item in AcmePlugin.makeExtensions() {
            #expect(item.defaultRules?.isEmpty == false, "\(item.id) has no default rules")
            #expect(RulesFile.load(id: item.id, bundle: Bundle(for: type(of: item))) == item.defaultRules)
        }
    }
}
