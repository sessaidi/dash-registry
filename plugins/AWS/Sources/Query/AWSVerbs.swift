import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help aws` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension AWSIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("aws", "whoami", tool: "aws_whoami", summary: "The AWS identity in use."),
            DashQLVerb("aws", "get", tool: "aws_api_read", arguments: ["url"], summary: "A read-only AWS call Dash fetched."),
            DashQLVerb("aws", "logs", tool: "aws_logs", arguments: ["group"], summary: "CloudWatch Logs events of a group (filter=, minutes=)."),
            DashQLVerb("aws", "groups", tool: "aws_log_groups", summary: "CloudWatch Logs log groups (prefix=)."),
            DashQLVerb("aws", "lambdas", tool: "aws_lambda_functions", summary: "Lambda functions."),
            DashQLVerb("aws", "eks", tool: "aws_eks_clusters", summary: "EKS clusters."),
        ]
    }
}
