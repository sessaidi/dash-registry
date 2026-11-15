import DashKit
import Foundation
import Testing

/// Every extension of the plugin gives Dashii default rules, specific to it.
@MainActor
struct DefaultRulesTests {
    @Test func everyExtensionHasRules() {
        let extensions = GitLabPlugin.makeExtensions()
        #expect(!extensions.isEmpty)
        for item in extensions {
            #expect(item.defaultRules?.isEmpty == false, "\(item.id) has no default rules")
            #expect(item.defaultRules?.contains("IMPORTANT") == false)
            // Rules are Markdown shipped in the bundle (Rules/<id>.md), not code.
            #expect(RulesFile.load(id: item.id, bundle: Bundle(for: type(of: item))) == item.defaultRules, "\(item.id): Rules/\(item.id).md isn't in the bundle")
        }
        let rules = extensions.compactMap(\.defaultRules).joined(separator: "\n")
        #expect(rules.contains("gitlab_merge_requests"))
        #expect(rules.contains("Nothing here writes to GitLab"))
    }
}
