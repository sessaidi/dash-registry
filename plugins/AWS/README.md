# AWS

Connects Dash to an AWS account through a profile in `~/.aws`, using static keys or IAM
Identity Center (SSO). Dash reads the config files and signs every request with SigV4
in-process, so it never runs the `aws` CLI. Other features reach AWS through this
integration's connection. Its fetchers store CloudWatch Logs, Lambda functions, EKS clusters and
any read-only API answer in Dash, and Dashii reads them from there. Nothing here changes AWS.

| | |
|---|---|
| Plugin id | `aws` |
| Version | 1.4.0 |
| Minimum DashKit | 2.4.0 |
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

## Fetch, then read

Dashii and agents never call AWS. They read what Dash has stored. When it's missing or stale,
they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher calls AWS
in the profile's region and stores a sanitized answer (at most 200 KB) in Dash's database, per
profile and region, then returns a receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each
reader returns the stored answer with `synced_at`, `stale` and `refresh` (the `data_fetch` call
that refreshes it). If nothing is stored yet, it returns `{"fetched": false, "hint", "refresh"}`.
Answers to queries are kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `aws.log_groups` | `aws_log_groups` | CloudWatch Logs groups (optional name prefix) | 15 min |
| `aws.logs` | `aws_logs` | A group's events, newest first (`filter`, `minutes`, `limit`) | 5 min |
| `aws.lambda_functions` | `aws_lambda_functions` | Lambda functions | 15 min |
| `aws.eks_clusters` | `aws_eks_clusters` | EKS clusters, each described | 1 hour |
| `aws.api` | `aws_api_read` | Any call on `https://*.amazonaws.com`: GET, or a Describe/List/Get-style action | 5 min |

`aws.api` takes a method (GET or POST), a URL, a body, a content type and an `X-Amz-Target` for
JSON-protocol services; the service and region come from the host name. Actions that change AWS
are refused before anything is sent. Answers over 100,000 characters are cut. `aws_whoami`
returns the identity ARN, profile and region from the last check (when Dash starts, or
**Check**), with `checked_at`; it sends nothing. DashQL dataset: `aws_logs`, the fetched events
with their `group`, `synced_at` and `stale`.

## For feature authors

The connection signs requests to `*.amazonaws.com` with SigV4 (`sign`). The integration
exports nothing.

## Build & test

From the registry root. You need Xcode, XcodeGen, and a checkout of the [Dash repository](https://github.com/sessaidi/dash) (point `DASH_ROOT` at it; see `scripts/dash-root.sh`).

```sh
TEST=1 scripts/build-plugins.sh AWS   # generate the project, run AWSPluginTests, build, zip
scripts/build-plugins.sh AWS          # build and zip without the tests
```

The script writes `dist/aws-1.4.0.dashplugin.zip` and regenerates `registry.json`. To try a
build in a running Dash, copy `build/AWS/Build/Products/Release/AWSPlugin.dashplugin` into
`~/Library/Application Support/Dash/Plugins`.
