#!/usr/bin/env bash
# Seed a simulator's Debug OpenStream with the owner's dev sources.
#
#   scripts/seed-sim.sh <sim-udid> [--reset]
#
# Copies ~/Developer/openstream-build/signing/dev-sources.json (written by
# scripts/dev-sources.py) into the app's data container, relaunches the app with
# `-OpenStreamDevSources <path>` (Debug builds only; the app deletes its copy),
# and prints the per-source trace lines. `--reset` also passes
# `-OpenStreamResetOnLaunch YES`, so the app starts from an empty install first.
# DEV_SOURCES=<file> points it at another file (a fixture). Works for iOS and
# tvOS simulators alike. Never prints a password, token or provider URL: the
# app's trace lines carry kind, name and outcome only.
set -euo pipefail

BUNDLE_ID="com.orgista.openstream"
SOURCES_FILE="${DEV_SOURCES:-$HOME/Developer/openstream-build/signing/dev-sources.json}"
WAIT_SECONDS=60

usage() { echo "usage: $0 <sim-udid> [--reset]" >&2; exit 2; }

[[ $# -ge 1 && $# -le 2 ]] || usage
UDID="$1"
RESET=0
if [[ $# -eq 2 ]]; then
  [[ "$2" == "--reset" ]] || usage
  RESET=1
fi

if [[ ! -f "$SOURCES_FILE" ]]; then
  echo "No dev sources file at $SOURCES_FILE — run scripts/dev-sources.py first." >&2
  exit 1
fi

# "<state>" for this sim, then one "<udid> <name>" line per OTHER booted sim.
sim_states() {
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
mine = [d for d in devices if d["udid"] == udid]
print(mine[0]["state"] if mine else "Missing")
for d in devices:
    if d["udid"] != udid and d["state"] == "Booted":
        print(d["udid"], d["name"])
' "$UDID"
}

STATES="$(sim_states)"
STATE="$(head -n 1 <<<"$STATES")"
OTHERS="$(tail -n +2 <<<"$STATES")"

if [[ "$STATE" == "Missing" ]]; then
  echo "No simulator with id $UDID." >&2
  exit 1
fi
if [[ "$STATE" != "Booted" ]]; then
  if [[ -n "$OTHERS" ]]; then
    echo "Another simulator is booted; one at a time. Shut it down first, or seed that one:" >&2
    echo "$OTHERS" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "Booting ${UDID}…"
  xcrun simctl boot "$UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null
fi

if ! CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)"; then
  echo "OpenStream ($BUNDLE_ID) is not installed on $UDID." >&2
  echo "Build and install a Debug build first: scheme \"OpenStream iOS\" for an iPhone/iPad sim," >&2
  echo "\"OpenStream tvOS\" for an Apple TV sim (AGENTS.md §1). Release builds ignore dev sources." >&2
  exit 1
fi

CACHES="$CONTAINER/Library/Caches"
DEST="$CACHES/dev-sources.json"
TRACE="$CACHES/openstream-trace.log"
mkdir -p "$CACHES"
cp "$SOURCES_FILE" "$DEST"
chmod 600 "$DEST"

# Only trace lines written after this launch count. A reset deletes and
# recreates the file, which the inode change shows.
trace_inode() { stat -f %i "$TRACE" 2>/dev/null || echo none; }
trace_size() { stat -f %z "$TRACE" 2>/dev/null || echo 0; }
START_INODE="$(trace_inode)"
START_SIZE="$(trace_size)"

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
ARGS=(-OpenStreamTrace YES -OpenStreamMuteAudio YES -OpenStreamDevSources "$DEST")
if [[ $RESET -eq 1 ]]; then ARGS+=(-OpenStreamResetOnLaunch YES); fi
xcrun simctl launch "$UDID" "$BUNDLE_ID" "${ARGS[@]}" >/dev/null
echo "Launched OpenStream on $UDID$([[ $RESET -eq 1 ]] && echo " (reset first)"); importing…"

new_trace() {
  [[ -f "$TRACE" ]] || return 0
  if [[ "$(trace_inode)" != "$START_INODE" || "$(trace_size)" -lt "$START_SIZE" ]]; then
    cat "$TRACE"
  else
    tail -c +"$((START_SIZE + 1))" "$TRACE"
  fi
}

for ((second = 0; second < WAIT_SECONDS; second++)); do
  LINES="$(new_trace | grep -o "dev sources: .*" || true)"
  if grep -q "dev sources: done" <<<"$LINES"; then
    echo "$LINES"
    [[ -f "$DEST" ]] && echo "warning: the app did not delete its copy at $DEST" >&2
    exit 0
  fi
  sleep 1
done

echo "No \"dev sources: done\" line in the trace after ${WAIT_SECONDS}s. Lines so far:" >&2
LINES="$(new_trace | grep -o "dev sources: .*" || true)"
echo "${LINES:-  (none — is this a Debug build?)}" >&2
exit 1
