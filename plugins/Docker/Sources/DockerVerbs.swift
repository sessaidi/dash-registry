import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help container` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension DockerIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("container", "list", tool: "docker_containers", summary: "Containers (all=true for stopped ones)."),
            DashQLVerb("container", "find", tool: "docker_find_containers", summary: "Find containers by name=, image=, status=, project=."),
            DashQLVerb("container", "inspect", tool: "docker_inspect", arguments: ["id"], summary: "A container in full."),
            DashQLVerb("container", "logs", tool: "docker_logs", arguments: ["id"], summary: "A container's logs."),
            DashQLVerb("container", "stats", tool: "docker_stats", arguments: ["id"], summary: "CPU and memory now."),
            DashQLVerb("container", "health", tool: "docker_health", arguments: ["id"], summary: "Health check results."),
            DashQLVerb("container", "start", tool: "docker_container_action", arguments: ["id"], presets: ["action": "start"], summary: "Start a container (asks first)."),
            DashQLVerb("container", "stop", tool: "docker_container_action", arguments: ["id"], presets: ["action": "stop"], summary: "Stop a container (asks first)."),
            DashQLVerb("container", "restart", tool: "docker_container_action", arguments: ["id"], presets: ["action": "restart"], summary: "Restart a container (asks first)."),
            DashQLVerb("image", "list", tool: "docker_images", summary: "Local images."),
            DashQLVerb("image", "inspect", tool: "docker_image_inspect", arguments: ["image"], summary: "An image in full."),
            DashQLVerb("docker", "info", tool: "docker_info", summary: "The Docker engine."),
            DashQLVerb("docker", "disk", tool: "docker_disk_usage", summary: "Disk used by images, containers, volumes."),
            DashQLVerb("docker", "events", tool: "docker_events", summary: "Recent engine events."),
        ]
    }
}
