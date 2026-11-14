# AWS

Connects Dash to an AWS account through a profile in `~/.aws`, using static keys or IAM
Identity Center (SSO). Dash reads the config files and signs every request with SigV4
in-process, so it never runs the `aws` CLI. Other features reach AWS through this
integration's connection, and Claude gets two tools to call AWS APIs as you. It is meant
for engineers who want Claude and Dash features to read their AWS resources.

| | |
|---|---|
| Plugin id | `aws` |
| Version | 1.1.0 |
| Minimum DashKit | 1.3.0 |
| Layer | integration (provides `aws`) |
| Requires | nothing |

## Setup

Prerequisites: a profile in `~/.aws/config` or `~/.aws/credentials`. A profile works if it has
one of these:

- Static keys: `aws_access_key_id`, `aws_secret_access_key` and, optionally, `aws_session_token`.
- An SSO profile (`sso_session` or `sso_start_url`, plus `sso_account_id` and
  `sso_role_name`). Run `aws sso login` first: Dash reads the token cached in
  `~/.aws/sso/cache` and exchanges it for short-lived role credentials. When the login expires,
  run `aws sso login` again.

Not supported: `credential_process`, because Dash won't run a program, and `role_arn`
profiles, because role chaining isn't implemented yet.

Settings › AWS:

- **Profile**: picks from the profiles found in both files. SSO profiles are marked "(SSO)".
  Defaults to `$AWS_PROFILE`, else `default`.
- **Region**: overrides the profile's region. Empty uses the profile's region, else `us-east-1`.
- **Check**: re-reads `~/.aws` and calls STS `GetCallerIdentity`. The status shows the ARN
  Dash acts as.
- **Features using this integration**: lists the installed features that require or
  optionally use `aws`.

## Claude tools

| Tool | What it does | Needs approval |
|---|---|---|
| `aws_whoami` | Returns the identity ARN, profile and region Dash uses. | No |
| `aws_api` | Calls any AWS API on `https://*.amazonaws.com`, signed with SigV4. The service and region come from the host name. Takes a method (GET or POST), a URL, a body, a content type and an `X-Amz-Target` for JSON-protocol services. Responses longer than 100,000 characters are truncated. | Yes |

## For feature authors

The connection signs requests to `*.amazonaws.com` with SigV4 (`sign`). The integration
exports nothing.

## Build & test

From the registry root. You need Xcode, XcodeGen, and the Dash repository at `~/code/perso/dash`.

```sh
TEST=1 scripts/build-plugins.sh AWS   # generate the project, run AWSPluginTests, build, zip
scripts/build-plugins.sh AWS          # build and zip without the tests
```

The script writes `dist/aws-1.1.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/AWS/Build/Products/Release/AWSPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
