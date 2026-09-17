#!/bin/bash
# Build a frozen copy using the already resolved local dependency cache.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
cache_root="${OPENSTREAM_APPLE_CACHE:-$HOME/Library/Caches/openstream-main}"
review_root=$(mktemp -d /tmp/openstream-apple-review.XXXXXX)
chmod 700 "$review_root"
if [ ! -d "$cache_root/.build/checkouts/AetherEngine" ] || [ ! -d "$cache_root/DerivedData/SourcePackages/checkouts/AetherEngine" ]; then
  echo "The resolved Apple dependency cache is missing. Set OPENSTREAM_APPLE_CACHE to the existing cache."
  exit 1
fi
mkdir -p "$review_root/apple"
rsync -a --exclude '.smbdelete*' --exclude 'Fixtures/private' \
  "$repo_root/native/apple/Sources" "$repo_root/native/apple/Tests" \
  "$repo_root/native/apple/Apps" "$repo_root/native/apple/Package.swift" \
  "$repo_root/native/apple/Package.resolved" "$review_root/apple/"
echo "Local verification artifacts: $review_root"
PLAYBACK_ENGINE_TESTS=0 swift test --package-path "$review_root/apple" \
  --scratch-path "$cache_root/.build" --skip-update > "$review_root/tests.log" 2>&1
failed=0
for configuration in Debug Release; do
  for platform in iOS tvOS visionOS macOS; do
    case "$platform" in
      iOS) destination='generic/platform=iOS Simulator';;
      tvOS) destination='generic/platform=tvOS Simulator';;
      visionOS) destination='generic/platform=visionOS Simulator';;
      macOS) destination='generic/platform=macOS';;
    esac
    if xcodebuild -quiet -project "$review_root/apple/Apps/OpenStreamApps.xcodeproj" \
      -scheme "OpenStream $platform" -configuration "$configuration" -destination "$destination" \
      -derivedDataPath "$cache_root/DerivedData" -disableAutomaticPackageResolution -skipPackageUpdates \
      CODE_SIGNING_ALLOWED=NO build > "$review_root/$platform-$configuration.log" 2>&1; then
      printf '%s\t%s\tPASS\n' "$platform" "$configuration" >> "$review_root/builds.tsv"
    else
      printf '%s\t%s\tFAIL\n' "$platform" "$configuration" >> "$review_root/builds.tsv"
      failed=1
    fi
  done
done
OPENSTREAM_SCRATCH="$cache_root/.build" bash "$repo_root/native/apple/scripts/apple-license-check.sh" > "$review_root/licenses.log" 2>&1
if [ "${OPENSTREAM_RUN_MEDIA_FIXTURES:-0}" = 1 ]; then
  python3 - "$review_root/apple/Tests/OpenStreamAppleTests" > "$review_root/media-tests.txt" <<'PY'
import re, sys
from pathlib import Path
for filename in ['ApplePlaybackEngineFixtureTests.swift', 'AppleNativeExportFixtureTests.swift', 'AppleSMBLifecycleTests.swift', 'AppleProtectedHTTPPlaybackServerTests.swift']:
    for name in re.findall(r'^func ((?:aether|nativeEngine|nativeExport|smbPlayer|protectedBridge)\w+)\(', (Path(sys.argv[1]) / filename).read_text(), re.M):
        print(name)
PY
  while IFS= read -r media_test; do
    PLAYBACK_ENGINE_TESTS=1 swift test --package-path "$review_root/apple" --scratch-path "$cache_root/.build" \
      --skip-build --filter "$media_test" > "$review_root/$media_test.log" 2>&1 || failed=1
  done < "$review_root/media-tests.txt"
  OPENSTREAM_PAUSE_FIXTURE=1 swift test --package-path "$review_root/apple" --scratch-path "$cache_root/.build" \
    --skip-build --filter 'surfacePlaybackStaysPausedAfterReloadingAtItsSavedPosition|nativePlaybackLoadsPausedAtItsSavedPosition' \
    > "$review_root/paused-playback.log" 2>&1 || failed=1
fi
cat "$review_root/builds.tsv"
exit "$failed"
