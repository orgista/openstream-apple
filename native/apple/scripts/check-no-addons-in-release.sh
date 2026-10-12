#!/bin/bash
# App Store/TestFlight gate: compile the app without add-on transports or UI.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$HOME/Developer/openstream-build"
log_file="/tmp/openstream-no-addons-release-build.log"
strings_file="/tmp/openstream-no-addons-release-strings.txt"
[[ -x "$build_root/bin/disk-guard.sh" ]] && "$build_root/bin/disk-guard.sh" 10
while pgrep -x xcodebuild >/dev/null || pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null; do
    sleep 10
done
# The share requires a timestamp refresh and a settling window before compiling.
for source_file in AppleSourceStore.swift AppleDiscoverView.swift AppleWebManagementPage.swift AppleStremioPlaybackClient.swift AppleMediaPlaybackView.swift; do
    touch "$repo_root/Sources/OpenStreamApple/$source_file"
done
touch "$repo_root/Package.swift" "$repo_root/Apps/OpenStreamApps.xcodeproj/project.pbxproj"
sleep 16
# Another serial build may have started during the share's settling window.
while pgrep -x xcodebuild >/dev/null || pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null; do
    sleep 10
done
xcodebuild -project "$repo_root/Apps/OpenStreamApps.xcodeproj" -scheme "OpenStream iOS" \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_root/DerivedData-deploy-ios" \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO build > "$log_file" 2>&1 || { echo "FAIL: Release simulator build; inspect $log_file locally."; exit 1; }
if grep -Eq -- '(-D[[:space:]]+OPENSTREAM_ADDONS|-DOPENSTREAM_ADDONS)' "$log_file"; then
    echo 'FAIL: OPENSTREAM_ADDONS was enabled in the distribution build.'
    exit 1
fi
for source_file in AppleSourceStore.swift AppleDiscoverView.swift AppleWebManagementPage.swift AppleStremioPlaybackClient.swift AppleMediaPlaybackView.swift; do
    grep -Eq "SwiftCompile normal arm64 Compiling.*$source_file" "$log_file" || {
        echo "FAIL: Release did not recompile $source_file."
        exit 1
    }
done
app="$build_root/DerivedData-deploy-ios/Build/Products/Release-iphonesimulator/OpenStream iOS.app"
[ -d "$app" ] || { echo 'FAIL: Release app missing.'; exit 1; }
# Check every shipped Mach-O, including embedded code, without exposing matching strings.
: > "$strings_file"
while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
        LC_ALL=C strings -a "$candidate" >> "$strings_file"
    fi
done < <(find "$app" -type f -print0)
if LC_ALL=C grep -Eiq 'manifest[.]json|addonCollection|stremio|YouTube links need the YouTube add-on|torrent|debrid|magnet:|infohash|premiumize|torbox' "$strings_file"; then
    echo 'FAIL: Add-on marker remains in Release binary; inspect the strings file locally.'
    exit 1
fi
bash "$repo_root/scripts/sdk-floor-check.sh" "$app"
echo 'PASS: Release iOS simulator app contains no add-on markers; SDK floors pass.'
