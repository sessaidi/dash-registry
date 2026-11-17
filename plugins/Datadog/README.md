# Datadog

Connects Dash to a Datadog site, read-only. Its fetchers store monitors, metrics, logs, events,
incidents, dashboards, SLOs, hosts and catalog services in Dash, and Dashii reads them from there.
Nothing here changes Datadog: every call is a GET, except the logs search, which is a POST that
only reads. The Datadog Monitors feature adds a widget of the monitors in Alert, Warn or No Data,
and posts activity when a monitor starts alerting.

| | |
|---|---|
| Plugin id | `datadog` |
| Version | 1.5.0 |
| Minimum DashKit | 2.4.0 |
| Layers | integration (provides `datadog`), feature `datadog-monitors` (requires `datadog`) |

## Setup

1. In Datadog, Organization Settings › API Keys: copy an API key.
2. Organization Settings › Application Keys: create one, ideally scoped read-only
   (monitors_read, metrics_read, logs_read_data, events_read, incident_read, dashboards_read,
   slos_read, hosts_read, apm_service_catalog_read).
3. Settings › Datadog in Dash: pick the site (datadoghq.com, datadoghq.eu, us3, us5, ap1…),
   paste both keys. The status shows the key's owner once `/api/v1/validate` accepts it.

## Fetch, then read

Dashii and agents never call Datadog. They read what Dash has stored. When it's missing or stale,
they ask the integration to fetch it with `data_fetch`, then read it again. Each fetcher calls
Datadog and stores a sanitized answer (at most 200 KB) in Dash's database, per site, then returns a
receipt: `{stored, unchanged, keys, synced_at, read_with}`. Each reader has the old tool's name and
input. It returns the stored answer with `synced_at`, `stale` and `refresh` (the `data_fetch` call
that refreshes it). If nothing is stored yet, it returns `{"fetched": false, "hint", "refresh"}`.
Answers to queries are kept for a day.

| Fetcher (`data_fetch`) | Reader (Dashii tool) | What | Fresh for |
|---|---|---|---|
| `datadog.monitors` | `datadog_monitors` | Monitor search with status (default: not OK) | 1 min |
| `datadog.monitor` | `datadog_monitor` | One monitor with its group states | 1 min |
| `datadog.metrics` | `datadog_metrics_query` | `/api/v1/query` over a window | 5 min |
| `datadog.logs` | `datadog_logs_search` | Logs, newest first (trimmed lines) | 5 min |
| `datadog.events` | `datadog_events` | Events in a window | 5 min |
| `datadog.incidents` | `datadog_incidents` | Incident search (active by default) | 5 min |
| `datadog.dashboards` | `datadog_dashboards` | Dashboard list | 1 hour |
| `datadog.dashboard` | `datadog_dashboard` | One dashboard's widgets | 1 hour |
| `datadog.slos` | `datadog_slos` | SLOs | 15 min |
| `datadog.slo_history` | `datadog_slo_history` | An SLO's history | 15 min |
| `datadog.hosts` | `datadog_hosts` | Hosts with apps, tags, up and muted state | 15 min |
| `datadog.services` | `datadog_services` | Service catalog entries | 1 hour |
| `datadog.api` | `datadog_api_read` | Any `/api/` path, GET only (no full URLs, no `..`) | 5 min |

Relative windows (`minutes`, `now-15m`) count from the fetch. Answers over 60,000 characters are
cut. DashQL datasets: `datadog_logs` and `datadog_events`, the fetched rows with the fetch's
`query`, `synced_at` and `stale`; `monitors` is the Monitors feature's, checked every minute.

## Widget

`datadog.monitors`: narrow shows counts (Alert, Warn, No data); medium a list, worst first;
wide and large add a detail pane for the selected monitor. Dashii can `filter`, `select` and
`refresh` it.
