#!/bin/bash
# apple-license-check.sh — GPL guard for the embedded AetherEngine / FFmpeg stack.
#
# Exits 1 if any FFmpeg binary in the resolved engine artifacts reports a
# forbidden configure flag (--enable-gpl, --enable-nonfree) or a GPL/nonfree
# library (libx264, libx265, libxvid, libfdk), if no FFmpeg binary was
# inspected, or if the AetherEngine LICENSE lacks the App Store exception
# wording. Prints each inspected binary and its verdict.
set -uo pipefail

SCRATCH="${OPENSTREAM_SCRATCH:-$HOME/Library/Caches/openstream-lane/.build}"

# Forbidden FFmpeg configure flags / linked libraries that would make the
# build GPL or nonfree rather than plain LGPL.
FORBIDDEN='--enable-gpl|--enable-nonfree|libx264|libx265|libxvid|libfdk'

# Search roots: built artifacts and the resolved engine/FFmpegBuild checkouts.
roots=()
[ -d "$SCRATCH/artifacts" ] && roots+=("$SCRATCH/artifacts")
[ -d "$SCRATCH/checkouts/AetherEngine" ] && roots+=("$SCRATCH/checkouts/AetherEngine")
[ -d "$SCRATCH/checkouts/FFmpegBuild" ] && roots+=("$SCRATCH/checkouts/FFmpegBuild")

if [ ${#roots[@]} -eq 0 ]; then
    echo "FAIL  no scratch search roots found under $SCRATCH"
    exit 1
fi

# Collect Mach-O executables inside .framework bundles within .xcframework slices.
binaries=$(find "${roots[@]}" -type f -path '*.xcframework*' -path '*.framework/*' 2>/dev/null | sort -u || true)

inspected=0
failed=0

while IFS= read -r binary; do
    [ -z "$binary" ] && continue
    # Only Mach-O binaries carry the FFmpeg configuration string.
    if ! file "$binary" 2>/dev/null | grep -qi 'Mach-O'; then
        continue
    fi
    # The FFmpeg configuration flags string (embedded in avutil, starts with --prefix=).
    config=$(strings "$binary" 2>/dev/null | grep -m1 '^--prefix=\|--enable-cross-compile' || true)
    if [ -z "$config" ]; then
        continue
    fi
    inspected=$((inspected + 1))
    if echo "$config" | grep -qE -- "$FORBIDDEN"; then
        echo "FAIL  $binary"
        echo "        $config"
        failed=$((failed + 1))
    else
        echo "PASS  $binary"
    fi
done <<< "$binaries"

if [ "$inspected" -eq 0 ]; then
    echo "FAIL  no FFmpeg binary was inspected"
    exit 1
fi

if [ "$failed" -gt 0 ]; then
    echo "FAIL  $failed binary(ies) reported forbidden configure flags"
    exit 1
fi

# Check the engine LICENSE for the App Store exception wording.
license="$SCRATCH/checkouts/AetherEngine/LICENSE"
if [ ! -f "$license" ]; then
    echo "FAIL  AetherEngine LICENSE not found at $license"
    exit 1
fi
if ! grep -qi 'App Store\|application store' "$license"; then
    echo "FAIL  AetherEngine LICENSE lacks App Store / application store wording"
    exit 1
fi

echo "PASS  AetherEngine LICENSE contains App Store exception"
echo "PASS  $inspected FFmpeg binary(ies) inspected, no forbidden flags"
