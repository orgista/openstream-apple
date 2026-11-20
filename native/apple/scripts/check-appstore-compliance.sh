#!/bin/bash
# App Store compliance gate (audits of 2026-10-22). Fails when a built product carries anything Apple must not see:
# add-on, Stremio, torrent or debrid words; Netflix chart scraping; Radarr, Sonarr or the transcode gateway; Dolby
# logo art; Trakt or Letterboxd; the old origin domain; the IPTV-panel brand as a visible word; and, in Release,
# test fixtures. There are no exemptions: a retired service's settings key is a word like any other.
#
#   scripts/check-appstore-compliance.sh <product.app|product.xcarchive> [more…]
#       scans the given products (any platform, any configuration);
#   scripts/check-appstore-compliance.sh --build
#       builds the four App Store schemes (iOS, tvOS, visionOS, macOS) as device Release and the four app schemes as
#       simulator Debug (unsigned), and scans all eight.
#
# Runs on the build Mac. Prints the word and the file it was found in, never the surrounding text.
# The checkout's folder names reach Debug binaries and the package's bundle identifier, so build from a folder
# whose path carries none of the words.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dd_root="${OPENSTREAM_CHECK_DD:-$HOME/Developer/openstream-build}"
mkdir -p "$dd_root"

# Case-insensitive, in every file of every product. Keep in sync with the app-store-review-hardening skill.
words='stremio|strem\.io|torrent|magnet|debrid|premiumize|torbox|infohash|cinemeta|metahub|add-?on|manifest\.json|openstream_addons|netflix\.com/tudum|radarr|sonarr|trakt|letterboxd|gateway|dolby-[a-z-]*\.png|openstream\.app'
# Case-sensitive: the IPTV-panel brand as a word a viewer can read (type names such as AppleXtreamLibrary are not).
visible_words='\bXtream\b|IPTV panel'
# Release only: fixtures and test plumbing that Debug builds carry on purpose.
release_words='fixture\.example|network stub'
failed=0

# 1. Nothing in the sources or the project can turn the old compilation condition back on.
if grep -rIl --include='*.swift' --include='*.pbxproj' --include='*.xcconfig' --include='Package.swift' \
        OPENSTREAM_ADDONS "$repo_root/Sources" "$repo_root/Apps" "$repo_root/Tests" "$repo_root/Package.swift"; then
    echo 'FAIL: OPENSTREAM_ADDONS is still referenced (files above).'
    failed=1
fi

# Every readable string of one file: Mach-O and other binaries through strings(1), property lists in XML.
file_text() {
    case "$1" in
        *.plist|*.strings|*.stringsdict|*.loctable) plutil -convert xml1 -o - "$1" 2>/dev/null || LC_ALL=C strings -a -n 4 "$1" ;;
        *) LC_ALL=C strings -a -n 4 "$1" 2>/dev/null ;;
    esac
}

report() {
    local rel="$1" found="$2"
    while read -r count word; do echo "  $word ×$count in $rel"; done <<< "$found"
}

scan() {
    local product="$1" release=0 hits=0 file rel text found
    [[ -e "$product" ]] || { echo "FAIL: $product does not exist."; failed=1; return; }
    [[ "$product" == *.xcarchive || "$product" == *Release* ]] && release=1
    while IFS= read -r -d '' file; do
        rel="${file#"$product"/}"
        if printf '%s' "$rel" | LC_ALL=C grep -Eiq "$words"; then
            echo "  file name $rel"; hits=$((hits + 1))
        fi
        text="$(file_text "$file")"
        if [[ "$file" == *.json ]] && python3 - "$file" <<'PY'
import json
import sys
try:
    with open(sys.argv[1]) as source:
        value = json.load(source)
except (OSError, ValueError):
    sys.exit(1)
channels = value.get("channels") if isinstance(value, dict) else None
is_lineup = isinstance(value, dict) and value.get("format") == "ostream-lineup"
is_lineup |= isinstance(channels, list) and bool(channels) and all(
    isinstance(channel, dict) and {"number", "name", "category"} <= channel.keys()
    for channel in channels
)
sys.exit(0 if is_lineup else 1)
PY
        then
            echo "  bundled channel lineup in $rel"; hits=$((hits + 1))
        fi
        [[ -n "$text" ]] || continue
        found="$( { LC_ALL=C grep -Eio "$words" <<< "$text" | tr '[:upper:]' '[:lower:]'
                    LC_ALL=C grep -Eo "$visible_words" <<< "$text"
                    if (( release )); then LC_ALL=C grep -Eio "$release_words" <<< "$text"; fi
                  } | sort | uniq -c || true)"
        if [[ -n "$found" ]]; then report "$rel" "$found"; hits=$((hits + 1)); fi
    done < <(find "$product" -type d -name '*.dSYM' -prune -o -type f ! -name 'CodeResources' -print0)
    if (( hits > 0 )); then
        echo "FAIL: $(basename "$product") ships words App Store builds must not (listed above)."
        failed=1
    else
        echo "PASS: $(basename "$product")"
    fi
    if find "$product" -type d -name '*.dSYM' -prune -o \( -iname 'ChannelLineup' -o -iname '*.oslineup' -o -iname 'complete-us.json' \) -print -quit | grep -q .; then
        echo "FAIL: $(basename "$product") contains a bundled channel lineup."
        failed=1
    fi
    if (( release )); then
        bash "$repo_root/scripts/sdk-floor-check.sh" "$product" >/dev/null || { echo "FAIL: SDK floors for $(basename "$product")."; failed=1; }
    fi
}

build_and_scan() {
    local platform config scheme destination products log app
    for platform in iOS tvOS visionOS macOS; do
        for config in Release Debug; do
            if [[ $config == Release ]]; then
                scheme="AppStore-$platform"
                case "$platform" in
                    iOS) destination='generic/platform=iOS'; products=iphoneos ;;
                    tvOS) destination='generic/platform=tvOS'; products=appletvos ;;
                    visionOS) destination='generic/platform=visionOS'; products=xros ;;
                    macOS) destination='generic/platform=macOS'; products='' ;;
                esac
            else
                scheme="OpenStream $platform"
                case "$platform" in
                    iOS) destination='generic/platform=iOS Simulator'; products=iphonesimulator ;;
                    tvOS) destination='generic/platform=tvOS Simulator'; products=appletvsimulator ;;
                    visionOS) destination='generic/platform=visionOS Simulator'; products=xrsimulator ;;
                    macOS) destination='generic/platform=macOS'; products='' ;;
                esac
            fi
            log="$dd_root/compliance-$platform-$config.log"
            xcodebuild -project "$repo_root/Apps/OpenStreamApps.xcodeproj" -scheme "$scheme" -configuration "$config" \
                -destination "$destination" -derivedDataPath "$dd_root/DerivedData-compliance-$platform" \
                CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1 || { echo "FAIL: $scheme $config build; see $log"; failed=1; continue; }
            if grep -Eq -- '-D[[:space:]]*OPENSTREAM_ADDONS' "$log"; then
                echo "FAIL: $scheme $config compiled with OPENSTREAM_ADDONS."; failed=1
            fi
            app="$(find "$dd_root/DerivedData-compliance-$platform/Build/Products/$config${products:+-$products}" \
                -maxdepth 1 -name '*.app' ! -name '*-Runner.app' -type d | head -1)"
            [[ -n "$app" ]] || { echo "FAIL: no $platform $config app"; failed=1; continue; }
            echo "$scheme $config:"
            scan "$app"
        done
    done
}

if [[ "${1:-}" == --build ]]; then
    build_and_scan
else
    (( $# )) || { echo "usage: $0 --build | <product.app|product.xcarchive>…"; exit 2; }
    for product in "$@"; do scan "$product"; done
fi
exit "$failed"
