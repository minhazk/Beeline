#!/usr/bin/env bash
# For whoever ships builds to their OWN App Store Connect account (the maintainer, or you
# for your own fork): archives Beeline and uploads it, where it appears in TestFlight once
# Apple has processed it (~10-30 min). Internal testing only: no beta review, installable
# by the team's own testers. Building from source for yourself doesn't need it.
#
# Needs BEELINE_BUNDLE_ID and DEVELOPMENT_TEAM in Config/Secrets.xcconfig, and an app record
# with that bundle ID in your App Store Connect account. Signing and upload use the Apple ID
# signed in to Xcode on this Mac (automatic signing, -allowProvisioningUpdates). Keys from
# Config/Secrets.xcconfig are compiled in and can be read out of the .ipa by anyone who gets it,
# so a build that has any is refused unless you pass --embed-keys (your own phones only).
#
# Usage: scripts/testflight.sh --upload | --no-upload [--embed-keys]
#   --upload      archive and upload to App Store Connect
#   --no-upload   archive and export an .ipa only
#   --embed-keys  allow a build with a Google key, TfL key or alerts invitation compiled in
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  cat >&2 <<'USAGE'
Usage: scripts/testflight.sh --upload | --no-upload [--embed-keys]
  --upload      archive and upload to App Store Connect
  --no-upload   archive and export an .ipa only
  --embed-keys  allow a build with a Google key, TfL key or alerts invitation compiled in
USAGE
  exit 2
}
UPLOAD=""; EMBED=0
for arg in "$@"; do
  case "$arg" in
    # One or the other, once: a wrapper that adds its usual --upload to an export-only run
    # must not win by coming last.
    --upload) [[ -z "$UPLOAD" ]] || usage; UPLOAD=1 ;;
    --no-upload) [[ -z "$UPLOAD" ]] || usage; UPLOAD=0 ;;
    --embed-keys) EMBED=1 ;;
    # Not repeated back: something pasted here by mistake shouldn't end up in a log.
    *) echo "Unknown option." >&2; usage ;;
  esac
done
# Uploading is said, never assumed: a mistyped flag must not ship a build.
[[ -n "$UPLOAD" ]] || usage

# Build numbers must only go up. YYMMDD.HHMM (UTC) does, and stays a valid
# CFBundleVersion (period-separated integers, each well under 2^31).
BUILD="${BUILD_NUMBER:-$(date -u +%y%m%d.%H%M)}"
[[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "BUILD_NUMBER must be up to three period-separated numbers (now: '$BUILD')." >&2; exit 1; }
AUTH=(-allowProvisioningUpdates)

scripts/generate.sh

# Refuse a build that would go out as the example app or unsigned.
# Read once, and the script stops here if they can't be read: a setting that couldn't be looked
# up must never pass for one that is empty.
SETTINGS="$(xcodebuild -project Beeline.xcodeproj -target Beeline -configuration Release -showBuildSettings 2>/dev/null)"
[[ "$SETTINGS" == *"PRODUCT_BUNDLE_IDENTIFIER"* ]] || { echo "Couldn't read the project's build settings." >&2; exit 1; }
setting() { printf '%s\n' "$SETTINGS" | sed -n "s/^ *$1 = //p" | head -1; }
TEAM="$(setting DEVELOPMENT_TEAM)"; BUNDLE="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$TEAM" || -z "$BUNDLE" || "$BUNDLE" == com.example.* ]]; then
  echo "Set BEELINE_BUNDLE_ID and DEVELOPMENT_TEAM in Config/Secrets.xcconfig first (now: '${BUNDLE}', team '${TEAM}')." >&2
  exit 1
fi
# Whatever these hold ends up in the app's Info.plist, in plain text, for every recipient.
EMBEDDED=""
for key in GOOGLE_ROUTES_API_KEY TFL_APP_KEY BEELINE_ALERTS_TOKEN; do
  [[ -z "$(setting "$key")" ]] || EMBEDDED="$EMBEDDED $key"
done
if [[ -n "$EMBEDDED" && $EMBED != 1 ]]; then
  echo "Refusing:$EMBEDDED would be compiled into the app, readable by anyone with the .ipa." >&2
  echo "Empty them in Config/Secrets.xcconfig and enter them in the app's Settings, or pass --embed-keys for a build only your own phones get." >&2
  exit 1
fi
# From a checkout, what ships is what's committed: local edits are refused, and the commit is said.
COMMIT=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git diff --quiet HEAD -- .; then
    echo "Refusing: uncommitted changes would ship. Commit them first." >&2
    exit 1
  fi
  # Every file in these folders is compiled or bundled, tracked or not: a stray source file, or
  # a key dropped beside them, would ship too.
  STRAY="$(git status --porcelain --untracked-files=all --ignored=matching -- Beeline BeelineWidgets BeelineNotifications | grep -v '\.DS_Store$' || true)"
  if [[ -n "$STRAY" ]]; then
    echo "Refusing: files git doesn't track would be built into the app:" >&2
    echo "$STRAY" >&2
    exit 1
  fi
  COMMIT=" at $(git rev-parse --short HEAD)"
fi
echo "Archiving $BUNDLE for team $TEAM$COMMIT${EMBEDDED:+ (compiled in:$EMBEDDED)}"
rm -rf build/Beeline.xcarchive build/export
xcodebuild -project Beeline.xcodeproj -scheme Beeline -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Beeline.xcarchive \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet archive

# What was built is what's checked, whatever the settings said: the three values as they are in
# the archived app. Only their names are ever printed.
PLIST="build/Beeline.xcarchive/Products/Applications/Beeline.app/Info.plist"
[[ -f "$PLIST" ]] || { echo "The archive has no app to check." >&2; exit 1; }
BUILT=""
for key in GoogleRoutesAPIKey TfLAppKey BeelineAlertsToken; do
  # Each is always there, empty or not: one that can't be read is not one that's empty.
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null)" || { echo "Couldn't read $key from the archived app." >&2; exit 1; }
  [[ -z "${value//[[:space:]]/}" ]] || BUILT="$BUILT $key"
done
if [[ -n "$BUILT" && $EMBED != 1 ]]; then
  echo "Refusing:$BUILT in the archived app's Info.plist would be readable by anyone with the .ipa." >&2
  exit 1
fi

DEST=export; [[ $UPLOAD == 1 ]] && DEST=upload
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath build/Beeline.xcarchive \
  -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${AUTH[@]}"
echo "Build $BUILD: $([[ $UPLOAD == 1 ]] && echo 'uploaded to App Store Connect' || echo "exported to build/export")"
