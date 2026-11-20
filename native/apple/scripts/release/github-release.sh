#!/bin/bash
# Prepare every platform locally. Publication is deliberately a separate action.
set -euo pipefail
version="${1:?usage: github-release.sh <version> <build>}"
build="${2:?usage: github-release.sh <version> <build>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$build" =~ ^[0-9]+$ && $# -eq 2 ]] || { echo 'FAIL: expected version and numeric build only; publishing is disabled'; exit 1; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
build_root="$HOME/Developer/openstream-build"
checkout="${OPENSTREAM_PUBLIC_CHECKOUT:-$build_root/public/openstream-apple}"
release="$build_root/github-release/$build"
mkdir -p "$release"
[[ "$(git -C "$root" branch --show-current)" == main ]] || { echo 'FAIL: private source must be on main'; exit 1; }
command -v gitleaks >/dev/null || { echo 'FAIL: gitleaks is required'; exit 1; }
# Use the same advisory lock as the other local build lanes, without invoking
# buildlock's unrelated cleanup policy. Also wait for processes outside the lock.
lock="$build_root/.buildlock"
while ! mkdir "$lock" 2>/dev/null; do
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
        rm -f "$lock/pid" "$lock/cmd"
        rmdir "$lock" 2>/dev/null || true
    else
        sleep 10
    fi
done
printf '%s\n' "$$" > "$lock/pid"
cleanup() { rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT
wait_for_builds() {
    while pgrep -x xcodebuild >/dev/null || pgrep -x swift-build >/dev/null || pgrep -x swift-test >/dev/null; do sleep 10; done
    if [[ -x "$build_root/bin/disk-guard.sh" ]]; then "$build_root/bin/disk-guard.sh" 10; fi
}
# Build the exported local snapshot, avoiding stale SMB reads entirely.
"$root/scripts/release/public-export.sh" "$checkout"
python3 "$root/scripts/release/release-metadata.py" notes "$checkout" "$release" "$version" "$build"
python3 "$root/scripts/release/release-metadata.py" fingerprint "$checkout/native/apple" > "$release/source.sha256"
for platform in iOS tvOS visionOS macOS; do
    wait_for_builds
    case "$platform" in
        iOS) destination='generic/platform=iOS'; lane=ios ;;
        tvOS) destination='generic/platform=tvOS'; lane=tvos ;;
        visionOS) destination='generic/platform=visionOS'; lane=visionos ;;
        macOS) destination='generic/platform=macOS'; lane=macos ;;
    esac
    archive="$release/OpenStream-$platform.xcarchive"
    log="$release/archive-$platform.log"
    extra=()
    [[ "$platform" == macOS ]] && extra+=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
    echo "Archiving OpenStream $platform $version ($build)"
    xcodebuild -project "$checkout/native/apple/Apps/OpenStreamApps.xcodeproj" \
        -scheme "OpenStream $platform" -configuration Release \
        -destination "$destination" -archivePath "$archive" \
        -derivedDataPath "$build_root/DerivedData-deploy-$lane" \
        -clonedSourcePackagesDirPath "$build_root/DerivedData-deploy-ios/SourcePackages" \
        -disableAutomaticPackageResolution -skipPackageUpdates \
        MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
        ${extra[@]+"${extra[@]}"} archive > "$log" 2>&1 || {
            echo "FAIL: $platform archive; inspect the local archive log (withhold secrets)"; exit 1;
        }
    bash "$root/scripts/sdk-floor-check.sh" "$archive" > "$release/floors-$platform.log" 2>&1 || { echo "FAIL: $platform SDK floors"; exit 1; }
    app="$(find "$archive/Products/Applications" -mindepth 1 -maxdepth 1 -type d -name '*.app')"
    [[ -d "$app" ]] || { echo "FAIL: missing $platform app"; exit 1; }
    python3 "$root/scripts/release/release-metadata.py" verify-app "$app" "$version" "$build"
    bash "$root/scripts/check-appstore-compliance.sh" "$app" > "$release/compliance-$platform.log" 2>&1 || { echo "FAIL: $platform fails the App Store compliance check"; exit 1; }
    stage="$(mktemp -d /tmp/openstream-package.XXXXXX)"
    if [[ "$platform" == macOS ]]; then
        ditto "$app" "$stage/oStream.app"
        codesign --force --deep -s - "$stage/oStream.app" > "$release/sign-macOS.log" 2>&1
        codesign --verify --deep --strict "$stage/oStream.app"
        ditto -c -k --keepParent "$stage/oStream.app" "$release/oStream-macOS-$version-$build.zip"
    else
        mkdir "$stage/Payload"
        ditto "$app" "$stage/Payload/OpenStream $platform.app"
        # Remove signatures from all executable code, including extensions and frameworks.
        while IFS= read -r -d '' candidate; do
            if file -b "$candidate" | grep -q 'Mach-O'; then
                codesign --remove-signature "$candidate" 2>/dev/null || true
                codesign -d "$candidate" >/dev/null 2>&1 && { echo 'FAIL: embedded signature remains'; exit 1; }
            fi
        done < <(find "$stage/Payload" -type f -print0)
        find "$stage/Payload" -type d -name _CodeSignature -prune -exec rm -rf {} +
        find "$stage/Payload" -type f -name '*.mobileprovision' -delete
        (cd "$stage" && zip -qry "$stage/package.ipa" Payload)
        mv "$stage/package.ipa" "$release/OpenStream-$platform-$version-$build.ipa"
    fi
    rm -rf "$stage"
    echo "PASS: $platform archive, versions, SDK floors, no add-on words"
done
python3 "$root/scripts/release/release-metadata.py" finish "$checkout" "$release" "$version" "$build"
# Never silently commit source different from the source used to build the assets.
"$root/scripts/release/public-export.sh" "$checkout"
python3 "$root/scripts/release/release-metadata.py" fingerprint "$checkout/native/apple" > "$release/source-after.sha256"
cmp -s "$release/source.sha256" "$release/source-after.sha256" || { echo 'FAIL: private build inputs changed during archives; rebuild from a stable snapshot'; exit 1; }
find "$checkout/native/apple/Sources" "$checkout/native/apple/Tests" "$checkout/native/apple/Apps" -name '*.swift' -size 0 -print > "$release/zero-byte.txt"
[[ ! -s "$release/zero-byte.txt" ]] || { echo 'FAIL: zero-byte Swift source'; exit 1; }
python3 "$root/scripts/release/public-scrub.py" "$checkout"
gitleaks dir "$checkout" --redact --no-banner --log-level error > "$release/gitleaks.log" 2>&1 || { echo 'FAIL: public checkout gitleaks'; exit 1; }
git -C "$checkout" add --all
git -C "$checkout" -c user.name=Orgista -c user.email=support@orgista.com commit --quiet -m "Release $version ($build)"
# Exact reviewable commands only; this script accepts no --publish option.
python3 "$root/scripts/release/release-metadata.py" commands "$checkout" "$release" "$version" "$build"
