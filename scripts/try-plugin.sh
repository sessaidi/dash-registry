#!/bin/sh
# Builds one plugin (from plugins/<Name> or examples/<Name>) and installs it in Dash, to try it
# while you work on it. Doesn't zip or touch registry.json: scripts/build-plugins.sh publishes.
#
#   scripts/try-plugin.sh Acme          # build and install
#   TEST=1 scripts/try-plugin.sh Acme   # run its tests first
#
# The first time, Dash asks before loading it. After that, relaunch Dash to switch to a new
# build: loaded code can't be swapped while Dash runs. PLUGINS_DIR overrides the destination.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
name="${1:?usage: scripts/try-plugin.sh <Name>}"
dir="plugins/$name"
[ -f "$dir/project.yml" ] || dir="examples/$name"
[ -f "$dir/project.yml" ] || { echo "No plugins/$name or examples/$name with a project.yml." >&2; exit 1; }
dest="${PLUGINS_DIR:-$HOME/Library/Application Support/Dash/Plugins}"
derived="build/try/$name"

(cd "$dir" && xcodegen generate --quiet)
if [ "${TEST:-0}" = 1 ]; then
  echo "==> testing $dir"
  xcodebuild test -project "$dir/${name}Plugin.xcodeproj" -scheme "${name}PluginTests" -derivedDataPath "$derived" -quiet
fi
echo "==> building $dir"
xcodebuild build -project "$dir/${name}Plugin.xcodeproj" -scheme "${name}Plugin" -configuration Release \
  -derivedDataPath "$derived" -quiet
bundle="$(find "$derived/Build/Products/Release" -maxdepth 1 -name '*.dashplugin' | head -1)"
[ -n "$bundle" ] || { echo "No .dashplugin was built." >&2; exit 1; }
mkdir -p "$dest"
rm -rf "$dest/$(basename "$bundle")"
cp -R "$bundle" "$dest/"
echo "==> installed $(basename "$bundle") in $dest"
echo "    First time: Dash asks to load it. Otherwise: relaunch Dash to use this build."
