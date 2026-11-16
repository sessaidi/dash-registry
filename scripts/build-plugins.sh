#!/bin/sh
# Builds every plugin under plugins/ (or the ones named) into dist/<id>-<version>.dashplugin.zip,
# then regenerates registry.json with each zip's SHA-256. Needs Xcode and XcodeGen.
#
#   scripts/build-plugins.sh                 # all plugins
#   scripts/build-plugins.sh GitHub Docker   # some
#   TEST=1 scripts/build-plugins.sh          # also run each plugin's tests
#
# DashKit comes from a Dash checkout: DASH_ROOT, see scripts/dash-root.sh.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
. scripts/dash-root.sh
mkdir -p dist build
names="${*:-$(ls plugins)}"
for name in $names; do
  dir="plugins/$name"
  [ -f "$dir/project.yml" ] || { echo "skip $name: no project.yml" >&2; continue; }
  echo "==> $name"
  (cd "$dir" && xcodegen generate --quiet)
  if [ "${TEST:-0}" = 1 ]; then
    xcodebuild test -project "$dir/${name}Plugin.xcodeproj" -scheme "${name}PluginTests" \
      -derivedDataPath "build/$name" -quiet || { echo "$name: tests failed" >&2; exit 1; }
  fi
  xcodebuild build -project "$dir/${name}Plugin.xcodeproj" -scheme "${name}Plugin" -configuration Release \
    -derivedDataPath "build/$name" -quiet
  bundle="$(find "build/$name/Build/Products/Release" -maxdepth 1 -name '*.dashplugin' | head -1)"
  id="$(/usr/libexec/PlistBuddy -c 'Print DashPluginID' "$bundle/Contents/Info.plist")"
  version="$(/usr/libexec/PlistBuddy -c 'Print DashPluginVersion' "$bundle/Contents/Info.plist")"
  [ -f "$bundle/Contents/Resources/plugin.json" ] || { echo "$name: plugin.json missing from the bundle" >&2; exit 1; }
  for rules in "$dir"/Rules/*.md; do
    [ -e "$rules" ] || continue
    [ -f "$bundle/Contents/Resources/Rules/$(basename "$rules")" ] || { echo "$name: Rules/$(basename "$rules") missing from the bundle" >&2; exit 1; }
  done
  /usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$bundle/Contents/Info.plist" >/dev/null 2>&1 \
    || { echo "$name: Info.plist has no CFBundleExecutable; macOS can't load the bundle" >&2; exit 1; }
  codesign --verify --deep "$bundle" || { echo "$name: the bundle's signature doesn't verify" >&2; exit 1; }
  rm -f "dist/$id-"*.dashplugin.zip
  # No resource forks or extended attributes: the zip holds just the bundle (no __MACOSX/).
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$bundle" "dist/$id-$version.dashplugin.zip"
  echo "    dist/$id-$version.dashplugin.zip"
done
python3 -I scripts/build-index.py
