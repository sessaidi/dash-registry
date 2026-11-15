# Sourced by the build scripts: sets DASH_ROOT, the Dash checkout whose Packages/DashKit the
# plugins compile against (each project.yml reads it). In order: $DASH_ROOT, the path in a
# .dash-root file at the registry root (not committed), then a `dash` checkout next to the registry.
if [ -z "${DASH_ROOT:-}" ] && [ -f "$root/.dash-root" ]; then
  DASH_ROOT="$(sed -n 1p "$root/.dash-root")"
  case "$DASH_ROOT" in "~"*) DASH_ROOT="$HOME${DASH_ROOT#\~}" ;; esac
fi
DASH_ROOT="${DASH_ROOT:-$root/../dash}"
[ -f "$DASH_ROOT/Packages/DashKit/Package.swift" ] || {
  echo "No Dash checkout at $DASH_ROOT. Clone https://github.com/sessaidi/dash and set DASH_ROOT" >&2
  echo "(or write its path in $root/.dash-root)." >&2
  exit 1
}
DASH_ROOT="$(cd "$DASH_ROOT" && pwd)"
export DASH_ROOT
