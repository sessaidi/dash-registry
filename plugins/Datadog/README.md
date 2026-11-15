# Datadog

Connects Dash to a Datadog site, read-only. Claude gets tools to search monitors, query
metrics, search logs, list events, incidents, dashboards, SLOs, hosts and catalog services.
None of them changes Datadog: every call is a GET, except the logs search, which is a POST
that only reads. The Datadog Monitors feature adds a widget of the monitors in Alert, Warn or
No Data, and posts activity when a monitor starts alerting.

| | |
|---|---|
| Plugin id | `datadog` |
| Version | 1.0.0 |
| Minimum DashKit | 1.5.0 |
| Layers | integration (provides `datadog`), feature `datadog-monitors` (requires `datadog`) |

## Setup

1. In Datadog, Organization Settings › API Keys: copy an API key.
2. Organization Settings › Application Keys: create one, ideally scoped read-only
   (monitors_read, metrics_read, logs_read_data, events_read, incident_read, dashboards_read,
   slos_read, hosts_read, apm_service_catalog_read).
3. Settings › Datadog in Dash: pick the site (datadoghq.com, datadoghq.eu, us3, us5, ap1…),
   paste both keys. The status shows the key's owner once `/api/v1/validate` accepts it.

## Claude tools

| Tool | What it reads |
|---|---|
| `datadog_api_get` | Any `/api/` path, GET only |
| `datadog_monitors`, `datadog_monitor` | Monitor search with status; one monitor with group states |
| `datadog_metrics_query` | `/api/v1/query` over a window |
| `datadog_logs_search` | Logs, newest first (trimmed lines) |
| `datadog_events` | Events in a window |
| `datadog_incidents` | Incident search (active by default) |
| `datadog_dashboards`, `datadog_dashboard` | Dashboard list and one dashboard's widgets |
| `datadog_slos`, `datadog_slo_history` | SLOs and their history |
| `datadog_hosts` | Hosts with apps, tags, up and muted state |
| `datadog_services` | Service catalog entries |

Outputs over 60,000 characters are cut.

## Widget

`datadog.monitors`: narrow shows counts (Alert, Warn, No data); medium a list, worst first;
wide and large add a detail pane for the selected monitor. Dashii can `filter`, `select` and
`refresh` it.
