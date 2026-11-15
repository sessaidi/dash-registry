import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help aws` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension AWSIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("aws", "whoami", tool: "aws_whoami", summary: "The AWS identity in use."),
            DashQLVerb("aws", "get", tool: "aws_api", arguments: ["url"], summary: "Call an AWS API (read)."),
        ]
    }
}
