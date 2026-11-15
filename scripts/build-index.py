#!/usr/bin/env python3
"""Regenerates registry.json from plugins/*/plugin.json, each plugin's Info.plist, and the zip in
dist/ with its SHA-256. Run by scripts/build-plugins.sh; run it alone after editing a plugin.json."""
import hashlib
import json
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
index = json.loads((root / "registry.json").read_text()) if (root / "registry.json").exists() else {"format": 1, "name": root.name}
entries = []

for meta_path in sorted((root / "plugins").glob("*/plugin.json")):
    meta = json.loads(meta_path.read_text())
    info = plistlib.loads((meta_path.parent / "Info.plist").read_bytes())
    plugin_id = info["DashPluginID"]
    version = info.get("DashPluginVersion", "1.0.0")
    zip_path = root / "dist" / f"{plugin_id}-{version}.dashplugin.zip"
    entry = {
        "id": plugin_id, "name": meta["name"], "kind": meta.get("kind", "integration"), "version": version,
        "plugin": {
            "download": str(zip_path.relative_to(root)),
            "minimumDashKit": info.get("DashKitMinimumVersion", "1.0.0"),
            # The extensions the plugin adds (integration and feature ids).
            "provides": meta.get("provides", [plugin_id]),
        },
    }
    if zip_path.exists():
        entry["plugin"]["sha256"] = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    else:
        print(f"warning: {zip_path.name} not built yet; no sha256", file=sys.stderr)
    for key in ("description", "icon", "author", "label", "requires", "optional"):
        if key in meta:
            entry[key] = meta[key]
    # The plugin's README, shown on its Marketplace page.
    readme = meta_path.parent / "README.md"
    if readme.exists():
        entry["readme"] = str(readme.relative_to(root))
    entries.append(entry)

ids = [e["id"] for e in entries]
if len(ids) != len(set(ids)):
    sys.exit("duplicate extension ids")
index["format"] = 2
index["extensions"] = entries
(root / "registry.json").write_text(json.dumps(index, indent=2) + "\n")
print(f"registry.json: {len(entries)} entries")
