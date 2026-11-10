#!/usr/bin/env bash
# Archive Daymark, upload it to App Store Connect and submit it for App Review.
#
#   scripts/release.sh [release]     test, archive, upload, then submit for review (default)
#   scripts/release.sh upload        test, archive and upload; don't submit
#   scripts/release.sh archive       test, archive and export an .ipa locally; nothing leaves the Mac
#   scripts/release.sh submit-only   submit an already-uploaded build (after a processing timeout)
#   scripts/release.sh check         show the app's versions and recent builds in App Store Connect
#
# Options:
#   --minor       bump x instead of y: 1.x.y -> 1.(x+1).0 (only when Aaron asks for a big release)
#   --version V   use exactly this version
#   --build N     build number (default: highest uploaded build of this version + 1)
#   --skip-tests  don't run daymarkTests on the iPhone first
#   --dry-run     for release/submit-only: print what would change in App Store Connect
#   --keep        skip the cleanup at exit (prints where the archive is)
#
# Versions are 1.x.y. By default the version is the latest one already in review or on the
# App Store with y + 1 (1.3.1 -> 1.3.2); --minor gives 1.4.0. The version and build number
# are written into the project before archiving, and after a successful upload the project
# change is committed ("Bump version to V (build B)") and pushed when on main.
# submit-only uses the version and build already in the project.
#
# Release notes ("What's New") come from release-notes/<version>/<locale>.txt, one file per
# App Store localization (en-US.txt today).
#
# Credentials: ~/.appstoreconnect/daymark.env sets ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH (the .p8 in ~/.appstoreconnect/private_keys). Neither file is in git.
#
# At exit it runs `scripts/build.sh clean` (removes the temp archive/build dirs and
# Daymark's DerivedData, shuts down simulators) and prints df -h.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="release"; KEEP=0; SKIP_TESTS=0; DRY=0; BUILD=""; VERSION=""; MINOR=0
while (( $# )); do
  case "$1" in
    --keep) KEEP=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --dry-run) DRY=1 ;;
    --build) BUILD="${2:?--build needs a number}"; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift ;;
    --minor) MINOR=1 ;;
    release|upload|archive|submit-only|check) MODE="$1" ;;
    *) echo "usage: $0 [release|upload|archive|submit-only|check] [--minor] [--version V] [--build N] [--skip-tests] [--dry-run] [--keep]" >&2; exit 2 ;;
  esac
  shift
done

ENV_FILE="${ASC_ENV_FILE:-$HOME/.appstoreconnect/daymark.env}"
[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE not found (see the header of this script)" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[[ -f "$ASC_KEY_PATH" ]] || { echo "error: API key not found at $ASC_KEY_PATH" >&2; exit 1; }
export ASC_KEY_PATH
asc() { python3 -I "$REPO/scripts/asc.py" "$@"; }

TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT="${TMP_ROOT%/}"
WORK=""
on_exit() {
  local status=$?
  if (( KEEP )); then
    echo "==> --keep: skipped cleanup${WORK:+; archive is in $WORK}"
    echo "==> Disk space"; df -h "$HOME"
  else
    # Xcode's export logs and SwiftPM lock files for our temp build dirs.
    find "$TMP_ROOT" -maxdepth 1 \( -name 'daymark_*.xcdistributionlogs' -o -name '_*daymark-build.*.lock' \) \
      -exec rm -rf {} + 2>/dev/null || true
    "$REPO/scripts/build.sh" clean || true   # also prints df -h
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" == check ]]; then asc check; exit 0; fi

if [[ "$MODE" == submit-only ]]; then
  read -r P_VERSION P_BUILD < <(asc project-version)
  VERSION="${VERSION:-$P_VERSION}"; BUILD="${BUILD:-$P_BUILD}"
else
  if [[ -z "$VERSION" ]]; then
    if (( MINOR )); then VERSION="$(asc next-version --minor)"; else VERSION="$(asc next-version)"; fi
  fi
  [[ -n "$BUILD" ]] || BUILD="$(asc next-build "$VERSION")"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "error: bad version/build: '$VERSION' '$BUILD'" >&2; exit 1; }
NOTES_DIR="$REPO/release-notes/$VERSION"
echo "==> Daymark $VERSION ($BUILD)"

if [[ "$MODE" == release || "$MODE" == submit-only ]]; then
  if [[ ! -d "$NOTES_DIR" ]]; then
    echo "error: no release notes; write $NOTES_DIR/en-US.txt first" >&2; exit 1
  fi
fi

submit() {
  local args=(submit "$VERSION" "$BUILD" --notes-dir "$NOTES_DIR")
  (( DRY )) && args+=(--dry-run)
  asc "${args[@]}"
}

if [[ "$MODE" == submit-only ]]; then submit; echo "==> Done"; exit 0; fi

if (( DRY )) && [[ "$MODE" == release ]]; then
  echo "==> --dry-run: not archiving or uploading"; submit; exit 0
fi

# Commit the version bump only if the project's diff is nothing but version lines.
commit_version() {
  local pbx=daymark.xcodeproj/project.pbxproj other
  if git diff --quiet -- "$pbx"; then return; fi
  other="$(git diff -U0 -- "$pbx" | grep -E '^[-+][^-+]' | grep -vE '^[-+]\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = ' || true)"
  if [[ -n "$other" ]]; then
    echo "   note: project.pbxproj has other changes; not committing the version bump"; return
  fi
  git commit -q -m "Bump version to $VERSION (build $BUILD)" -- "$pbx"
  echo "   committed: Bump version to $VERSION (build $BUILD)"
  if [[ "$(git branch --show-current)" == main ]]; then git push -q origin main && echo "   pushed to main"; fi
}

echo "==> Setting project version to $VERSION ($BUILD)"
asc project-version --set "$VERSION" "$BUILD"

if (( ! SKIP_TESTS )); then
  # build.sh cleans up after itself; the trap here is a second sweep.
  "$REPO/scripts/build.sh" test
fi

WORK="$(mktemp -d "$TMP_ROOT/daymark-build.release.XXXXXX")"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> Archiving"
xcodebuild -project daymark.xcodeproj -scheme daymark -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/daymark.xcarchive" \
  -derivedDataPath "$WORK/DerivedData" "${auth[@]}" -quiet \
  CURRENT_PROJECT_VERSION="$BUILD" COMPILER_INDEX_STORE_ENABLE=NO \
  MODULE_CACHE_DIR="$HOME/Library/Developer/Xcode/DerivedData/ModuleCache.noindex" \
  archive

DESTINATION=upload; [[ "$MODE" == archive ]] && DESTINATION=export
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${APP_TEAM:-DC9UKDP974}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

if [[ "$DESTINATION" == export ]]; then echo "==> Exporting .ipa"; else echo "==> Uploading to App Store Connect"; fi
xcodebuild -exportArchive -archivePath "$WORK/daymark.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" "${auth[@]}"

case "$MODE" in
  archive) ls -lh "$WORK/export"/*.ipa; echo "==> Archive OK (not uploaded)"; ((KEEP)) || echo "   (pass --keep to keep the .ipa)" ;;
  upload)  commit_version; echo "==> Uploaded $VERSION ($BUILD); submit later with: scripts/release.sh submit-only" ;;
  release) commit_version; submit ;;
esac
echo "==> Done"
