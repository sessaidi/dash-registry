import DashKit
import Foundation

/// What Dashii can do with a Pods widget, kept apart from the view so it can be tested.
enum PodsWidgetActions {
    static let actions = [
        WidgetAction(name: "filter", description: "Search the pods: words match name, node, status, IP or owner; key=value matches a label; !word excludes. Empty clears it. Temporary: the widget's saved search stays.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
        WidgetAction(name: "set_status", description: "Show pods by status. Temporary: the widget's saved filters stay.",
                     properties: ["status": JSONSchema.string("all, problems, running, pending, failed or completed.", enum: ["all", "problems", "running", "pending", "failed", "completed"])], required: ["status"]),
        WidgetAction(name: "show_problems_only", description: "Only pods that aren't healthy (on), or every pod (off). Temporary: the widget's saved filters stay.",
                     properties: ["on": JSONSchema.boolean("true for problems only.")], required: ["on"]),
        WidgetAction(name: "set_namespace", description: "Show another namespace: a name, \"*\" for every namespace, or \"\" for the context's own. Temporary: the widget's saved namespace stays.",
                     properties: ["namespace": JSONSchema.string("Namespace.")], required: ["namespace"]),
        WidgetAction(name: "set_context", description: "Show another kubeconfig context; \"\" follows the one the Kubernetes integration uses. Temporary: the widget's saved context stays.",
                     properties: ["context": JSONSchema.string("Context name.")], required: ["context"]),
        WidgetAction(name: "select_pod", description: "Select a pod by name (or a unique part) and open its detail (containers, events, logs, YAML); linked widgets follow the selection.",
                     properties: ["name": JSONSchema.string("Pod name.")], required: ["name"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected pod."),
        WidgetAction(name: "clear_filters", description: "Drop Dashii's temporary changes (namespace, context, search, status): back to the widget's settings."),
    ]

    struct Outcome {
        var reply: JSONValue
        var select: PodSummary?
    }

    static func perform(_ name: String, _ input: JSONValue, config: inout PodsWidget.Config, pods: [PodSummary]) throws -> Outcome {
        switch name {
        case "filter":
            let text = input["text"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.search = text.isEmpty ? nil : text
            return Outcome(reply: ["search": text.isEmpty ? .null : .string(text)])
        case "set_status":
            guard let raw = input["status"]?.string, let status = PodSummary.Filter(rawValue: raw) else {
                throw ToolError("Status is one of all, problems, running, pending, failed, completed.")
            }
            config.filter = status.rawValue
            config.problemsOnly = status == .problems
            return Outcome(reply: ["status": .string(status.rawValue)])
        case "show_problems_only":
            let on = input["on"]?.bool ?? true
            config.filter = on ? PodSummary.Filter.problems.rawValue : PodSummary.Filter.all.rawValue
            config.problemsOnly = on
            return Outcome(reply: ["problems_only": .bool(on)])
        case "set_namespace":
            let namespace = input["namespace"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.namespace = namespace.isEmpty ? nil : namespace
            return Outcome(reply: ["namespace": namespace.isEmpty ? "context's own" : .string(namespace)])
        case "set_context":
            let context = input["context"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.context = context.isEmpty ? nil : context
            config.namespace = nil
            return Outcome(reply: ["context": context.isEmpty ? "integration's" : .string(context)])
        case "select_pod":
            let wanted = input["name"]?.string?.lowercased() ?? ""
            let matches = pods.filter { $0.name.lowercased().contains(wanted) }
            guard !wanted.isEmpty, let pod = pods.first(where: { $0.name.lowercased() == wanted }) ?? (matches.count == 1 ? matches[0] : nil) else {
                throw ToolError(matches.count > 1 ? "Several pods match “\(wanted)”: \(matches.prefix(8).map(\.name).joined(separator: ", "))."
                                                  : "No pod matching “\(wanted)” is shown.")
            }
            return Outcome(reply: ["opened": .string(pod.id)], select: pod)
        case "clear_filters":
            config.search = nil
            config.filter = nil
            config.problemsOnly = false
            return Outcome(reply: "cleared")
        default:
            throw ToolError("Unknown action \(name).")
        }
    }

    static func state(config: PodsWidget.Config, pods: [PodSummary], total: Int, namespace: String, selected: PodSummary?) -> JSONValue {
        [
            "context": config.context.map(JSONValue.string) ?? "integration's",
            "namespace": .string(namespace),
            "status": .string(config.statusFilter.rawValue),
            "search": config.search.map(JSONValue.string) ?? .null,
            "filters": .array(config.activeFilters.map { .string($0) }),
            "shown": .number(Double(pods.count)), "total": .number(Double(total)),
            "counts": [
                "running": .number(Double(pods.filter { $0.tone == .success }.count)),
                "failing": .number(Double(pods.filter { $0.tone == .danger }.count)),
                "not_ready": .number(Double(pods.filter { $0.tone == .warning }.count)),
                "completed": .number(Double(pods.filter { $0.phase == "Succeeded" }.count)),
                "restarts": .number(Double(pods.reduce(0) { $0 + $1.restarts })),
            ],
            "open_pod": selected.map { .string($0.id) } ?? .null,
        ]
    }
}
