# Dash Registry

The marketplace for [Dash](https://github.com/sessaidi/dash): integrations and features
you install from Dash's Settings › Marketplace.

- **Integrations** connect an account or a local service (GitHub, GitLab, Atlassian, AWS,
  Google Cloud, Docker, Kubernetes). They hold the credentials and hand features an
  authenticated connection; features never see the secret.
- **Features** build on integrations (Pull Requests needs GitHub, Jira Board needs
  Atlassian) and add widgets, Claude tools and background work. A feature may mix several
  integrations, including ones written by someone else; it uses them only through DashKit.

## What's here

| Folder | What |
|---|---|
| `plugins/<Name>/` | Compiled Swift plugins (`.dashplugin`), each a standalone XcodeGen project with tests and a `plugin.json` |
| `dist/` | Built plugin zips, referenced by `registry.json` |
| `registry.json` | The index Dash reads (generated) |
| `scripts/` | `new-plugin.py` (start a plugin), `build-plugins.sh` (build, test, zip, index), `build-index.py` |

## Using it

In Dash, Settings › Marketplace › Registries, add one line:

```
sessaidi/dash-registry              # from GitHub (private repos need the GitHub integration)
~/code/dash-registry                # or a local checkout while developing
```

Install a plugin and it loads right away. Each download is checked against the SHA-256 in
`registry.json`, and that exact build is approved. Updating or removing a loaded plugin
finishes at the next launch.

## Building

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and the Dash repository
at `~/code/perso/dash` (plugins compile against `../../../perso/dash/Packages/DashKit`).

```sh
TEST=1 scripts/build-plugins.sh          # build + test + zip every plugin, regenerate registry.json
scripts/build-plugins.sh GitHub          # just one
python3 scripts/build-index.py           # re-index after editing a plugin.json
```

Commit `dist/` and `registry.json` together so the hashes match the zips.

## Writing one

```sh
scripts/new-plugin.py Weather --feature          # or --integration; --requires github,atlassian
TEST=1 scripts/build-plugins.sh Weather
```

Then copy the built `.dashplugin` into `~/Library/Application Support/Dash/Plugins`: Dash
asks to load it and starts it without a relaunch.

See Dash's `docs/PLUGINS.md`. Keep extension ids, widget kinds, model names and preference keys stable
across versions: users' dashboards and settings refer to them.
