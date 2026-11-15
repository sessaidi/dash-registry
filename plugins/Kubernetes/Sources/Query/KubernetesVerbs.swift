import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help k8s` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension KubernetesIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("k8s", "contexts", tool: "k8s_contexts", summary: "Kubeconfig contexts."),
            DashQLVerb("k8s", "namespaces", tool: "k8s_namespaces", summary: "Namespaces."),
            DashQLVerb("k8s", "get", tool: "k8s_list", arguments: ["kind"], summary: "List objects of a kind (namespace=)."),
            DashQLVerb("k8s", "describe", tool: "k8s_describe", arguments: ["kind", "name"], summary: "One object with its events."),
            DashQLVerb("k8s", "logs", tool: "k8s_logs", arguments: ["pod"], summary: "A pod's logs (container=, previous=, tail=)."),
            DashQLVerb("k8s", "events", tool: "k8s_events", summary: "Events in a namespace."),
            DashQLVerb("k8s", "top", tool: "k8s_top_pods", summary: "CPU and memory per pod."),
            DashQLVerb("rollout", "status", tool: "k8s_rollout_status", arguments: ["name"], summary: "A deployment's rollout."),
            DashQLVerb("rollout", "restart", tool: "k8s_rollout_restart", arguments: ["name"], summary: "Restart a deployment (asks first)."),
        ]
    }
}
