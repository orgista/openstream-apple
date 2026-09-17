#!/bin/bash
# Test-fixture generator for the OpenStream apple-engine playback-engine tests.
#
# Produces a small matrix of sample media under Tests/Fixtures/out/ using the
# system ffmpeg / ffprobe / dovi_tool / mkvmerge, so the fixture test server
# (serve.py) and the engine route tests (T3) have real bytes to play back.
#
# Idempotent: a file that already exists is skipped unless --force is given.
# Runs from any working directory. Uses set -euo pipefail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out"
TMP="$OUT/tmp"
HLS="$OUT/hls"
SKIPPED="$OUT/SKIPPED.txt"
PRIVATE="$SCRIPT_DIR/private"

FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    *) echo "make-fixtures: unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT" "$TMP" "$HLS" "$PRIVATE"

# Common A/V sources: 15 s of testsrc2 video with a 440 Hz sine audio bed.
DUR=15
SIZE="320x180"
RATE=25
VIDEO="testsrc2=size=${SIZE}:rate=${RATE}:duration=${DUR}"
SINE="sine=frequency=440:duration=${DUR}"

# SKIPPED.txt records missing encoders; re-evaluate it on every run.
: > "$SKIPPED"

has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE " $1 "; }

# skip_missing <encoder> <label>
#   If <encoder> is absent, record a SKIPPED line and return 1, else return 0.
skip_missing() {
  if has_encoder "$1"; then return 0; fi
  echo "SKIPPED $1" >> "$SKIPPED"
  echo "  skip (no $1)"
  return 1
}

# make <out> <cmd...>
#   Skip if <out> already exists (unless --force); otherwise run <cmd>. On a
#   command failure the partial file is removed and make returns 1 (callers
#   that can tolerate a failure chain it with `|| true`).
make() {
  local out="$1"; shift
  if [[ $FORCE -eq 0 && -f "$out" ]]; then
    echo "  skip (exists): $(basename "$out")"
    return 0
  fi
  rm -f "$out"
  echo "  make: $(basename "$out")"
  if ! "$@"; then
    rm -f "$out"
    echo "  FAILED: $(basename "$out")" >&2
    return 1
  fi
}

echo "make-fixtures: generating into $OUT"

# --- mp4-h264-aac.mp4 -------------------------------------------------------
make "$OUT/mp4-h264-aac.mp4" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
  -c:v h264_videotoolbox -c:a aac -ac 2 -movflags +faststart \
  "$OUT/mp4-h264-aac.mp4"

# --- ts-h264-aac.ts ---------------------------------------------------------
make "$OUT/ts-h264-aac.ts" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
  -c:v h264_videotoolbox -c:a aac -ac 2 -f mpegts \
  "$OUT/ts-h264-aac.ts"

# --- ts-h264-interlaced-ac3.ts (libx264 interlaced + AC-3 5.1) --------------
if skip_missing libx264; then
  make "$OUT/ts-h264-interlaced-ac3.ts" ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
    -c:v libx264 -flags +ilme+ildct -x264-params interlaced=1 \
    -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a ac3 -ac 6 \
    -f mpegts "$OUT/ts-h264-interlaced-ac3.ts" || true
fi

# --- ts-mpeg2-interlaced-mp2.ts (mpeg2video interlaced + MP2) --------------
make "$OUT/ts-mpeg2-interlaced-mp2.ts" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
  -c:v mpeg2video -flags +ilme+ildct -b:v 6M -c:a mp2 -ac 2 \
  -f mpegts "$OUT/ts-mpeg2-interlaced-mp2.ts"

# --- subs.srt (SRT subtitle embedded in the MKV fixture) -------------------
SUBS="$TMP/subs.srt"
printf '1\n00:00:00,500 --> 00:00:03,000\nTest subtitle cue\n\n2\n00:00:04,000 --> 00:00:06,000\nOpenStream captions\n' > "$SUBS"

# --- mkv-h264-aac.mkv (H.264 + AAC + embedded SRT subtitle) -----------------
make "$OUT/mkv-h264-aac.mkv" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" -i "$SUBS" \
  -c:v h264_videotoolbox -c:a aac -ac 2 -c:s srt \
  "$OUT/mkv-h264-aac.mkv"

# --- mkv-hevc-eac3.mkv (HEVC + EAC3 5.1) ------------------------------------
make "$OUT/mkv-hevc-eac3.mkv" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
  -c:v hevc_videotoolbox \
  -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a eac3 -b:a 384k \
  "$OUT/mkv-hevc-eac3.mkv"

# --- mkv-hevc-truehd.mkv ----------------------------------------------------
if skip_missing truehd; then
  make "$OUT/mkv-hevc-truehd.mkv" ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
    -c:v hevc_videotoolbox -c:a truehd -strict -2 \
    "$OUT/mkv-hevc-truehd.mkv" || true
fi

# --- mkv-hevc-dts.mkv -------------------------------------------------------
if skip_missing dca; then
  make "$OUT/mkv-hevc-dts.mkv" ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
    -c:v hevc_videotoolbox -c:a dca -strict -2 \
    "$OUT/mkv-hevc-dts.mkv" || true
fi

# --- mkv-vp9-opus.mkv (libvpx-vp9 + libopus) --------------------------------
if skip_missing libvpx-vp9 && skip_missing libopus; then
  make "$OUT/mkv-vp9-opus.mkv" ffmpeg -y -hide_banner -loglevel error \
    -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
    -c:v libvpx-vp9 -c:a libopus \
    "$OUT/mkv-vp9-opus.mkv" || true
fi

# --- hls/index.m3u8 + hls/seg%03d.ts (remux the mp4 to VOD HLS) -------------
if [[ $FORCE -eq 0 && -f "$HLS/index.m3u8" ]]; then
  echo "  skip (exists): hls/index.m3u8"
else
  rm -f "$HLS"/*.ts "$HLS"/*.m3u8
  echo "  make: hls/index.m3u8"
  ffmpeg -y -hide_banner -loglevel error -i "$OUT/mp4-h264-aac.mp4" \
    -c copy -f hls -hls_time 4 -hls_playlist_type vod \
    -hls_segment_filename "$HLS/seg%03d.ts" "$HLS/index.m3u8"
fi

# --- hdr10-hevc.mp4 (HEVC 10-bit HDR10/PQ base for Dolby Vision) -----------
make "$OUT/hdr10-hevc.mp4" ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$VIDEO" -f lavfi -i "$SINE" \
  -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -tag:v hvc1 -c:a aac -ac 2 \
  "$OUT/hdr10-hevc.mp4"

# --- Dolby Vision 8.1 (dv81-hevc-eac3.mkv + dv81-hevc-eac3.mp4) ------------
if [[ $FORCE -eq 0 && -f "$OUT/dv81-hevc-eac3.mp4" && -f "$OUT/dv81-hevc-eac3.mkv" ]]; then
  echo "  skip (exists): dv81-hevc-eac3.{mkv,mp4}"
else
  echo "  make: dv81-hevc-eac3.{mkv,mp4}"
  # 1. Extract annex-B HEVC and set the PQ/bt2020 VUI explicitly (the
  #    VideoToolbox encoder omits transfer/primaries on this build); the muxers
  #    derive dv_bl_signal_compatibility_id=1 (HDR10) from transfer=smpte2084.
  ffmpeg -y -hide_banner -loglevel error -i "$OUT/hdr10-hevc.mp4" -c:v copy \
    -bsf:v "hevc_mp4toannexb,hevc_metadata=transfer_characteristics=16:colour_primaries=9:matrix_coefficients=9:video_full_range_flag=0" \
    -f hevc "$TMP/base.hevc"
  # 2. Frame count drives the RPU generator (one RPU per frame).
  FC=$(ffprobe -v error -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/hdr10-hevc.mp4")
  cat > "$TMP/dv81.json" <<EOF
{"cm_version":"V29","profile":"8.1","length":${FC},"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}
EOF
  # 3. Generate a profile 8.1 RPU and inject it on every frame.
  dovi_tool generate -j "$TMP/dv81.json" -o "$TMP/rpu.bin"
  dovi_tool inject-rpu -i "$TMP/base.hevc" --rpu-in "$TMP/rpu.bin" -o "$TMP/dv81.hevc"
  # 4. EAC3 5.1 audio bed for the DV variants.
  ffmpeg -y -hide_banner -loglevel error -f lavfi -i "$SINE" \
    -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a eac3 -b:a 384k \
    "$TMP/eac3-51.ec3"
  # 5. Matroska: mkvmerge writes the DOVI configuration record from the RPU.
  rm -f "$OUT/dv81-hevc-eac3.mkv"
  mkvmerge -o "$OUT/dv81-hevc-eac3.mkv" "$TMP/dv81.hevc" "$TMP/eac3-51.ec3" >/dev/null 2>&1
  # 6. MP4: this ffmpeg build needs -strict unofficial to emit the dvcC/dvvC
  #    box and the dovi_rpu bitstream filter to surface the config from the
  #    annex-B RPU. The VUI set in step 1 yields dv_bl_signal_compatibility_id=1.
  rm -f "$OUT/dv81-hevc-eac3.mp4"
  ffmpeg -y -hide_banner -loglevel error -i "$TMP/dv81.hevc" -i "$TMP/eac3-51.ec3" \
    -c copy -bsf:v dovi_rpu -strict unofficial -tag:v hvc1 \
    "$OUT/dv81-hevc-eac3.mp4"
fi

# --- owner-provided private samples ----------------------------------------
echo "private samples:"
for f in dv5-sample.mkv atmos-joc-sample.mp4; do
  if [[ -f "$PRIVATE/$f" ]]; then echo "  present: $f"; else echo "  absent: $f"; fi
done

# --- summary table ---------------------------------------------------------
echo
echo "summary: file | container | video | audio | dv profile | size"
python3 - "$OUT" <<'PY'
import json, os, subprocess, sys
out = sys.argv[1]
files = ["mp4-h264-aac.mp4", "ts-h264-aac.ts", "ts-h264-interlaced-ac3.ts",
         "ts-mpeg2-interlaced-mp2.ts", "mkv-h264-aac.mkv", "mkv-hevc-eac3.mkv",
         "mkv-hevc-truehd.mkv", "mkv-hevc-dts.mkv", "mkv-vp9-opus.mkv",
         "hdr10-hevc.mp4", "dv81-hevc-eac3.mkv", "dv81-hevc-eac3.mp4"]

def probe(path):
    cont = vcodec = acodec = dv = "-"
    size = os.path.getsize(path)
    try:
        j = json.loads(subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries",
             "stream=codec_name,codec_type,profile:stream_side_data_list",
             "-of", "json", path], text=True))
    except Exception:
        return cont, vcodec, acodec, dv, size
    streams = j.get("streams", [])
    for s in streams:
        if s.get("codec_type") == "video" and vcodec == "-":
            vcodec = s.get("codec_name", "-")
            for sd in (s.get("side_data_list") or []):
                if "DOVI configuration record" in str(sd.get("side_data_type", "")):
                    dv = str(sd.get("dv_profile", "-"))
        elif s.get("codec_type") == "audio" and acodec == "-":
            acodec = s.get("codec_name", "-")
    try:
        fj = json.loads(subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=format_name",
             "-of", "json", path], text=True))
        cont = fj.get("format", {}).get("format_name", "-")
    except Exception:
        pass
    return cont, vcodec, acodec, dv, size

def human(n):
    for unit in ("B", "KiB", "MiB"):
        if n < 1024:
            return f"{n:.0f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"

rows = []
for f in files:
    p = os.path.join(out, f)
    if os.path.exists(p):
        rows.append((f, *probe(p)))
    else:
        rows.append((f, "-", "-", "-", "-", "missing"))
cols = ["file", "container", "video", "audio", "dv", "size"]
widths = [max(len(str(r[i])) for r in ([cols] + rows)) for i in range(6)]
print("  " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cols)))
for r in rows:
    print("  " + " | ".join(str(x).ljust(widths[i]) for i, x in enumerate(r)))
PY

if [[ -s "$SKIPPED" ]]; then echo; echo "skipped encoders:"; sed 's/^/  /' "$SKIPPED"; fi
echo "make-fixtures: done"
