# Examples

The code from the Dash plugin tutorials (`docs/tutorials` in the Dash repository).
They build and their tests pass, but they aren't published: `scripts/build-plugins.sh` and the
registry only look at `plugins/`.

| Folder | What it is | Tutorial |
|---|---|---|
| `Acme` | integration: an API token, a server setting, a connection, read-only tools | 1. Build an integration |
| `AcmeBoard` | feature: the Acme Tickets widget (a layout per size), tools, DashQL, a triage agent | 2. Build a widget, 3. Build an agent |
| `MockAcme` | a local stand-in for the Acme API, so the plugins show real data | all three |

Acme is a made-up ticket service. To see the plugins work, run the mock server and point Acme
at it:

```sh
python3 examples/MockAcme/server.py          # http://localhost:8787; Ctrl-C stops it
```

In Dash, open **Settings › Acme**, set **Server** to `http://localhost:8787` (press Return) and
paste any token (`wrong` is refused, to see the error state). The tickets come from
`examples/MockAcme/tickets.json`, read on every request, so you can edit it while Dash runs.

Build, test and install one in Dash:

```sh
TEST=1 scripts/try-plugin.sh AcmeBoard
```

The first time, Dash asks before loading it; after that, relaunch Dash to use a new build.

To start your own plugin from one, copy it into `plugins/` under a new name and change its ids,
or run `scripts/new-plugin.py`.
