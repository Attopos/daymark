#!/usr/bin/env bash
# Build, test and install Daymark. Real iPhone by default; simulator only with --simulator.
#
#   scripts/build.sh [install]   build for the device and install it (default)
#   scripts/build.sh build       build only
#   scripts/build.sh test        run unit tests (daymarkTests)
#   scripts/build.sh all         test, then build and install
#   scripts/build.sh clean       only clean up, build nothing
#
# Options:
#   --keep        skip the cleanup at exit (prints where the build dir is)
#   --simulator   use the iOS Simulator instead of the iPhone (SIM_NAME, default "iPhone 18 Pro")
#
# Env: DEVICE_ID=<udid> picks a device (default: first paired physical iOS device).
#      CONFIG=Debug|Release (default Debug).
#
# At exit (success, failure or Ctrl-C) it removes this run's build dir, any leftover
# daymark-build.* dirs in the temp folders, Daymark's own folders in
# ~/Library/Developer/Xcode/DerivedData and build/ in the repo; shuts down simulators
# and quits Simulator.app; then prints df -h. The shared Swift/Clang module cache
# (~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex), simulator runtimes and
# devices, and the source are never touched.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="install"; KEEP=0; SIM=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --simulator) SIM=1 ;;
    build|install|test|all|clean) MODE="$arg" ;;
    *) echo "usage: $0 [build|install|test|all|clean] [--keep] [--simulator]" >&2; exit 2 ;;
  esac
done

CONFIG="${CONFIG:-Debug}"
SIM_NAME="${SIM_NAME:-iPhone 18 Pro}"
XC_DD="$HOME/Library/Developer/Xcode/DerivedData"
MODULE_CACHE="$XC_DD/ModuleCache.noindex"   # kept: small, speeds up the next build
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
DERIVED=""

# Echo Daymark's folders in Xcode's DerivedData. A folder counts only if its name is
# daymark-<hash> (Xcode names it after daymark.xcodeproj) and, when it has an
# info.plist, its WorkspacePath is this repo's project.
project_derived_dirs() {
  local d ws
  for d in "$XC_DD"/daymark-*; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/info.plist" ]]; then
      ws="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null || true)"
      [[ "$ws" == "$REPO/daymark.xcodeproj" || "$ws" == "$REPO/"* ]] || continue
    fi
    echo "$d"
  done
}

remove() {  # remove paths, refusing anything outside the expected roots
  local p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    case "$p" in
      "$TMP_ROOT"/daymark-build.*|/private/tmp/daymark-build.*|/tmp/daymark-build.*|"$XC_DD"/daymark-*|"$REPO"/build|"$REPO"/DerivedData) ;;
      *) echo "   skip (not ours): $p"; continue ;;
    esac
    echo "   rm $p ($(du -sh "$p" 2>/dev/null | cut -f1))"
    rm -rf "$p"
  done
}

clean_all() {
  echo "==> Cleaning up"
  local tmp_dirs=()
  shopt -s nullglob
  tmp_dirs=("$TMP_ROOT"/daymark-build.* /private/tmp/daymark-build.*)
  shopt -u nullglob
  # Leftovers from earlier runs are swept only when no other Daymark build is running.
  if pgrep -f "derivedDataPath $TMP_ROOT/daymark-build" >/dev/null 2>&1; then tmp_dirs=(); fi
  remove ${DERIVED:+"$DERIVED"} ${tmp_dirs[@]+"${tmp_dirs[@]}"} "$REPO/build" "$REPO/DerivedData"
  local dd; while IFS= read -r dd; do remove "$dd"; done < <(project_derived_dirs)
  if xcrun simctl list devices booted 2>/dev/null | grep -q Booted || pgrep -xq Simulator; then
    echo "   shutting down simulators"
    xcrun simctl shutdown all >/dev/null 2>&1 || true
    osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true
  fi
}

on_exit() {
  local status=$?
  if (( KEEP )); then
    echo "==> --keep: skipped cleanup${DERIVED:+; build dir is $DERIVED}"
  else
    clean_all
  fi
  echo "==> Disk space"
  df -h "$HOME"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" == clean ]]; then exit 0; fi

find_device() {
  if [[ -n "${DEVICE_ID:-}" ]]; then echo "$DEVICE_ID"; return; fi
  local json; json="$(mktemp "$TMP_ROOT/daymark-build.devices.XXXXXX")"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  python3 -I - "$json" <<'PY' || true
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        print(hw.get("udid", "")); break
PY
  rm -f "$json"
}

if (( SIM )); then
  DEST="platform=iOS Simulator,name=$SIM_NAME"; PRODUCTS="$CONFIG-iphonesimulator"
  echo "==> Simulator: $SIM_NAME ($CONFIG)"
else
  UDID="$(find_device)"
  if [[ -z "$UDID" ]]; then
    echo "error: no paired iPhone found. Plug it in, set DEVICE_ID, or pass --simulator." >&2
    exit 1
  fi
  DEST="id=$UDID"; PRODUCTS="$CONFIG-iphoneos"
  echo "==> Device: $UDID ($CONFIG)"
fi

DERIVED="$(mktemp -d "$TMP_ROOT/daymark-build.XXXXXX")"
common=(-project daymark.xcodeproj -scheme daymark -configuration "$CONFIG"
        -destination "$DEST" -derivedDataPath "$DERIVED" -allowProvisioningUpdates -quiet
        MODULE_CACHE_DIR="$MODULE_CACHE" COMPILER_INDEX_STORE_ENABLE=NO)

# The test targets are set to a different team than the app, so on a real device
# the injected test bundle fails library validation. Sign everything with the app's team.
APP_TEAM="${APP_TEAM:-DC9UKDP974}"
run_tests() { echo "==> Testing"; xcodebuild "${common[@]}" DEVELOPMENT_TEAM="$APP_TEAM" -only-testing:daymarkTests test; }
build_app() { echo "==> Building"; xcodebuild "${common[@]}" build; }
install_app() {
  local app
  app="$(find "$DERIVED/Build/Products/$PRODUCTS" -maxdepth 1 -name '*.app' | head -1)"
  [[ -n "$app" ]] || { echo "error: built .app not found" >&2; exit 1; }
  echo "==> Installing $(basename "$app")"
  if (( SIM )); then
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    xcrun simctl install "$SIM_NAME" "$app"
  else
    xcrun devicectl device install app --device "$UDID" "$app"
  fi
  # The app now lives on the device; the build dir is removed by the exit trap.
}

case "$MODE" in
  build)   build_app ;;
  install) build_app; install_app ;;
  test)    run_tests ;;
  all)     run_tests; build_app; install_app ;;
esac
echo "==> Done"
