#!/bin/bash
# Fails when anything in a built product, or in the project's settings,
# requires a newer OS than OpenStream supports. Run after building with a
# new Xcode, before trusting that older devices still work.
#
#   scripts/sdk-floor-check.sh <path/to/App.app | App.xcarchive>
#
# Every Mach-O inside is checked (app, extensions, frameworks, watch app):
# its LC_BUILD_VERSION minos must not exceed the floor for its platform.
# macOS executables under Contents/MacOS must also be arm64-only; embedded
# frameworks may retain their prebuilt Intel slices.
# FLOOR_OVERRIDE=99.0 forces every floor to 99.0 (to check the script itself
# still passes); FLOOR_OVERRIDE=1.0 must make it fail.
set -uo pipefail

target="${1:?usage: sdk-floor-check.sh <App.app | App.xcarchive>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
pbxproj="$root/Apps/OpenStreamApps.xcodeproj/project.pbxproj"
failures=0

floor_for() {
    [[ -n "${FLOOR_OVERRIDE:-}" ]] && { echo "$FLOOR_OVERRIDE"; return; }
    case "$1" in
        IOS|IOSSIMULATOR|MACCATALYST) echo 18.0 ;;
        TVOS|TVOSSIMULATOR) echo 18.0 ;;
        MACOS) echo 15.0 ;;
        WATCHOS|WATCHOSSIMULATOR) echo 11.0 ;;
        XROS|XROSSIMULATOR|VISIONOS|VISIONOSSIMULATOR) echo 2.0 ;;
        *) echo "" ;;
    esac
}

# True when version $1 is greater than version $2.
version_gt() {
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# --- Binaries -------------------------------------------------------------
checked=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q "Mach-O" || continue
    rel="${file#"$target"/}"
    archs="$(lipo -archs "$file" 2>/dev/null)"
    # One file can carry several slices; check every LC_BUILD_VERSION, per arch.
    for arch in ${archs:-unknown}; do
        arch_args=(); [[ "$arch" != unknown ]] && arch_args=(-arch "$arch")
        while read -r platform minos; do
            [[ -z "$platform" ]] && continue
            if [[ "$platform" == MACOS && "$arch" == x86_64 \
                  && "$file" == */Contents/MacOS/* && "$rel" != *.framework/* \
                  && "$rel" != */Frameworks/* ]] \
                  && otool -arch "$arch" -hv "$file" 2>/dev/null | grep -qw EXECUTE; then
                fail "$rel [$arch]: macOS executable contains x86_64 (arm64-only)"
            fi
            floor="$(floor_for "$platform")"
            # Xcode 27 adds an arm64 slice to watch binaries for the watches that run
            # watchOS 26+; Apple gives that slice minos 26.0. Older watches load the
            # arm64_32 slice, which is checked against the real floor, so the arm64
            # slice is only allowed 26.0 when an arm64_32 slice sits beside it.
            if [[ -z "${FLOOR_OVERRIDE:-}" && "$platform" == WATCHOS && "$arch" == arm64 \
                  && " $archs " == *" arm64_32 "* ]]; then
                floor=26.0
            fi
            checked=$((checked + 1))
            if [[ -z "$floor" ]]; then
                fail "$rel [$arch]: unknown platform $platform"
            elif version_gt "$minos" "$floor"; then
                fail "$rel [$arch]: $platform minos $minos > floor $floor"
            else
                pass "$rel [$arch]: $platform minos $minos"
            fi
        done < <(vtool ${arch_args[@]+"${arch_args[@]}"} -show-build "$file" 2>/dev/null | awk '/platform /{p=$2} /minos /{print p, $2}')
    done
done < <(find "$target" -type f -print0)
[[ $checked -eq 0 ]] && fail "no Mach-O build versions found under $target"

# --- iOS app Info.plist ---------------------------------------------------
while IFS= read -r -d '' plist; do
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$plist" 2>/dev/null)" == iphone* ]] || continue
    rel="${plist#"$target"/}"
    for key in UIApplicationSceneManifest UILaunchScreen; do
        if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
            pass "$rel: has $key"
        else
            fail "$rel: missing $key"
        fi
    done
done < <(find "$target" -path "*.app/Info.plist" -not -path "*.appex/*" -not -path "*/Frameworks/*" -print0)

# --- Project settings -----------------------------------------------------
object_version="$(grep -m1 -E '^\s*objectVersion = ' "$pbxproj" | tr -dc '0-9')"
[[ "$object_version" == 71 ]] && pass "pbxproj objectVersion 71" \
    || fail "pbxproj objectVersion $object_version (must stay 71)"

check_setting() {
    local setting="$1" platform="$2" floor
    floor="$(floor_for "$platform")"
    local values
    values="$(grep -E "^\s*$setting = " "$pbxproj" | sed -E 's/.*= ([^;]+);/\1/' | sort -u | tr '\n' ' ')"
    for value in $values; do
        [[ "$value" == "$floor" ]] && pass "$setting $value" || fail "$setting $value (floor $floor)"
    done
}
if [[ -z "${FLOOR_OVERRIDE:-}" ]]; then
    check_setting IPHONEOS_DEPLOYMENT_TARGET IOS
    check_setting TVOS_DEPLOYMENT_TARGET TVOS
    check_setting MACOSX_DEPLOYMENT_TARGET MACOS
    check_setting WATCHOS_DEPLOYMENT_TARGET WATCHOS
    check_setting XROS_DEPLOYMENT_TARGET XROS

    # The package's own platforms list only: the first `platforms: [` up to
    # the line that closes it.
    platforms="$(awk '/platforms: \[/ && !done {on=1} on {print} on && /^[[:space:]]*\],?[[:space:]]*$/ {on=0; done=1}' \
        "$root/Package.swift" | tr -d ' \n')"
    expected="platforms:[.iOS(.v18),.macOS(.v15),.tvOS(.v18),.visionOS(.v2),],"
    expected_no_comma="platforms:[.iOS(.v18),.macOS(.v15),.tvOS(.v18),.visionOS(.v2)],"
    [[ "$platforms" == "$expected" || "$platforms" == "$expected_no_comma" ]] \
        && pass "Package.swift platforms" || fail "Package.swift platforms changed: $platforms"
fi

echo
if [[ $failures -gt 0 ]]; then
    echo "sdk-floor-check: $failures failure(s)"
    exit 1
fi
echo "sdk-floor-check: all $checked build versions within the floor"
