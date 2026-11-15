import DashKit
import Foundation

/// GitLab for Dashii: merge requests, read-only REST calls, and the release mirror's sync tools.
extension GitLabIntegration {
    private struct GetInput: Decodable { let path: String }
    private struct MRInput: Decodable { let project: String?; let scope: String? }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "gitlab_merge_requests",
                description: "Open merge requests on a GitLab project (default: every watched project), or across the instance for the user with scope assigned_to_me / created_by_me.",
                properties: [
                    "project": JSONSchema.string("Project path, e.g. group/service."),
                    "scope": JSONSchema.string("For instance-wide lists.", enum: ["assigned_to_me", "created_by_me", "all"]),
                ]
            ) { [weak self] input in
                guard let self else { return [] }
                let request = try input.toolInput(MRInput.self)
                var items: [JSONValue] = []
                if let scope = request.scope, request.project == nil {
                    items = try await get("/merge_requests?state=opened&scope=\(scope)&per_page=50").array ?? []
                } else {
                    for project in request.project.map({ [$0] }) ?? projects {
                        items += try await get("/projects/\(Self.projectID(project))/merge_requests?state=opened&per_page=50").array ?? []
                    }
                }
                return .array(items.map {
                    ["project": $0["references"]?["full"] ?? .null, "title": $0["title"] ?? .null, "author": $0["author"]?["username"] ?? .null,
                     "draft": $0["draft"] ?? .null, "updated_at": $0["updated_at"] ?? .null, "url": $0["web_url"] ?? .null,
                     "pipeline": $0["head_pipeline"]?["status"] ?? .null]
                })
            },
            DashiiTool(
                name: "gitlab_api_get",
                description: "Read any GitLab REST v4 endpoint as the user (GET only), e.g. /projects/group%2Fservice/pipelines?per_page=5. Responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("Path after /api/v4, starting with /.")], required: ["path"]
            ) { [weak self] input in
                guard let self else { return nil }
                let path = try input.toolInput(GetInput.self).path
                guard path.hasPrefix("/") else { throw ToolError("path must start with /") }
                let json = try await get(path)
                let text = json.jsonString()
                return text.count > Self.maxToolCharacters
                    ? ["truncated": true, "json": .string(String(text.prefix(Self.maxToolCharacters)))] : json
            },
        ] + syncTools
    }
}
