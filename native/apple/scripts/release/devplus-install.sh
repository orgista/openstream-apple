#!/bin/zsh
# Build the iOS app with add-ons (TestFlight-equivalent Release), sign it Ad Hoc for the team's registered test
# iPhones (DevPlus + the owner's) and install it on one of them. Runs ON Dev-Mini — call it through scripts/mini.sh:
#   scripts/mini.sh 'zsh scripts/release/devplus-install.sh [build-number] [device-udid]'
# Default device: DevPlus. The IPA stays in ~/Developer/openstream-build/devplus/export even when the device is not
# reachable. Needs the "OpenStream AdHoc Team …" profiles and the build keychain (see workspace AGENTS.md).
set -euo pipefail
BUILD=${1:-1}
DEVICE=${2:-00008140-000809A82E89801C}
OUT=$HOME/Developer/openstream-build/devplus
ARCHIVE=$OUT/OpenStream-iOS-devplus.xcarchive
security unlock-keychain -p "$(cat ~/Developer/.build-keychain-pass)" ~/Library/Keychains/build.keychain-db
rm -rf "$ARCHIVE" "$OUT/export"; mkdir -p "$OUT"
xcodebuild -project Apps/OpenStreamApps.xcodeproj -scheme "OpenStream iOS" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath ~/Developer/openstream-build/dd-ios-release \
  CURRENT_PROJECT_VERSION=$BUILD \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OPENSTREAM_ADDONS' \
  archive 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)|Signing Identity" | tail -20
[[ -d $ARCHIVE ]] || { print -u2 "archive failed"; exit 1; }
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist scripts/release/ExportOptions-ios-adhoc.plist 2>&1 | grep -E "error|EXPORT (SUCCEEDED|FAILED)" | tail -10
IPA=$(ls "$OUT"/export/*.ipa | head -1)
if xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE"; then
  xcrun devicectl device install app --device "$DEVICE" "$IPA" 2>&1 | tail -3
  print -r -- "installed $IPA on $DEVICE"
else
  print -r -- "built $IPA — device $DEVICE is not reachable from this Mac, not installed"
fi
