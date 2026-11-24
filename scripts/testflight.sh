#!/usr/bin/env bash
# For whoever ships builds to their OWN App Store Connect account (the maintainer, or you
# for your own fork): archives Beeline and uploads it, where it appears in TestFlight once
# Apple has processed it (~10-30 min). Internal testing only: no beta review, installable
# by the team's own testers. Building from source for yourself doesn't need it.
#
# Needs BEELINE_BUNDLE_ID and DEVELOPMENT_TEAM in Config/Secrets.xcconfig, and an app record
# with that bundle ID in your App Store Connect account. Signing and upload use the Apple ID
# signed in to Xcode on this Mac (automatic signing, -allowProvisioningUpdates). Keys from
# Config/Secrets.xcconfig are compiled in, so only distribute to people you'd give them to.
#
# Usage: scripts/testflight.sh [--no-upload]   (--no-upload: archive + export an .ipa only)
set -euo pipefail
cd "$(dirname "$0")/.."
UPLOAD=1; [[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

# Build numbers must only go up. YYMMDD.HHMM (UTC) does, and stays a valid
# CFBundleVersion (period-separated integers, each well under 2^31).
BUILD="${BUILD_NUMBER:-$(date -u +%y%m%d.%H%M)}"
AUTH=(-allowProvisioningUpdates)

scripts/generate.sh

# Refuse a build that would go out as the example app or unsigned.
setting() { xcodebuild -project Beeline.xcodeproj -target Beeline -configuration Release -showBuildSettings 2>/dev/null | sed -n "s/^ *$1 = //p" | head -1; }
TEAM="$(setting DEVELOPMENT_TEAM)"; BUNDLE="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$TEAM" || -z "$BUNDLE" || "$BUNDLE" == com.example.* ]]; then
  echo "Set BEELINE_BUNDLE_ID and DEVELOPMENT_TEAM in Config/Secrets.xcconfig first (now: '${BUNDLE}', team '${TEAM}')." >&2
  exit 1
fi
echo "Archiving $BUNDLE for team $TEAM"
rm -rf build/Beeline.xcarchive build/export
xcodebuild -project Beeline.xcodeproj -scheme Beeline -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Beeline.xcarchive \
  CURRENT_PROJECT_VERSION="$BUILD" "${AUTH[@]}" -quiet archive

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
