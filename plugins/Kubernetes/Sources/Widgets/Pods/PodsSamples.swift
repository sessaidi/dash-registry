import Foundation

/// Sample pods for the widget gallery (never the cluster): healthy, crash-looping, pending and
/// completed pods over two namespaces and three nodes.
enum PodsSamples {
    static let pods: [PodSummary] = [
        pod("api-7d9f8c6b5-x2lqp", "papi-eu", "Running", ready: 2, of: 2, node: "gke-pool-a-1", age: 3 * 86_400),
        pod("api-7d9f8c6b5-k9wzt", "papi-eu", "Running", ready: 2, of: 2, node: "gke-pool-a-2", age: 3 * 86_400),
        pod("api-8b1e2f4c7-q4m8n", "papi-eu", "Running", status: "CrashLoopBackOff", ready: 1, of: 2, restarts: 14, node: "gke-pool-a-2", age: 1_500),
        pod("api-8b1e2f4c7-t7hzd", "papi-eu", "Running", status: "CrashLoopBackOff", ready: 1, of: 2, restarts: 9, node: "gke-pool-a-1", age: 1_500),
        pod("worker-5c4b7d8f9-mn3vr", "papi-us", "Running", status: "CrashLoopBackOff", ready: 0, of: 1, restarts: 7, node: "gke-pool-b-1", age: 720),
        pod("worker-5c4b7d8f9-p2c6k", "papi-us", "Running", ready: 1, of: 1, restarts: 1, node: "gke-pool-b-1", age: 2 * 86_400),
        pod("search-0", "papi-us", "Running", ready: 0, of: 1, node: "gke-pool-b-2", age: 300),
        pod("redis-0", "papi-us", "Running", ready: 1, of: 1, node: "gke-pool-b-2", age: 9 * 86_400),
        pod("web-6f8d9c7b4-zz81s", "papi-eu", "Pending", ready: 0, of: 1, node: nil, age: 90),
        pod("migrate-28431-q8s7d", "papi-eu", "Succeeded", status: "Completed", ready: 0, of: 1, node: "gke-pool-a-1", age: 7_200),
    ]

    static let warnings: [String: [String]] = [
        "papi-eu/api-8b1e2f4c7-q4m8n": ["BackOff"],
        "papi-eu/api-8b1e2f4c7-t7hzd": ["BackOff"],
        "papi-us/search-0": ["Unhealthy"],
        "papi-eu/web-6f8d9c7b4-zz81s": ["FailedScheduling"],
    ]

    static let scope = PodsScope(context: "gke-prod", namespace: "all namespaces", allNamespaces: true, lastSync: .now.addingTimeInterval(-20))

    private static func pod(_ name: String, _ namespace: String, _ phase: String, status: String? = nil, ready: Int, of total: Int,
                            restarts: Int = 0, node: String?, age: TimeInterval) -> PodSummary {
        var pod = PodSummary(namespace: namespace, name: name, phase: phase, status: status, ready: ready, total: total, restarts: restarts, node: node)
        pod.created = .now.addingTimeInterval(-age)
        pod.owner = name.contains("-0") ? "StatefulSet/\(name.dropLast(2))" : "ReplicaSet/\(name.split(separator: "-").dropLast().joined(separator: "-"))"
        pod.podIP = "10.4.\(namespace == "papi-eu" ? 1 : 2).\(name.count * 7 % 250)"
        return pod
    }
}
