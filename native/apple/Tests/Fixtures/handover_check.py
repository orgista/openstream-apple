#!/usr/bin/env python3
"""Frame-by-frame check of a hero art -> trailer handover in a screen recording.

Usage: handover_check.py REC.mp4 --hero x0,y0,x1,y1 [--overlay x0,y0,x1,y1 ...]
                         [--static x0,y0,x1,y1] [--reverse]
                         [--fps 60] [--start S] [--end S] [--out report.json]
Exit status 1 when the window has no handover, a near-black frame or bars
inside it, an overlay that moves, or a video that jumps after the reveal.
Run it once over the art -> video handover and once, with --reverse, over
the return to art (read backwards it is the same art -> video handover).
--static names a part of the video whose content does not move (the fixture
clip's colour-bar edges), so its own motion is not taken for a re-crop.
Rects are fractions of the frame. Stdlib only (the mini has no numpy).

Per frame (resampled to --fps, so every <= 1/fps s):
  * hero mean luma, dark fraction -> "near-black" when mean < 18 or > 92 % dark
  * letterbox rows: full-width near-black rows at the top/bottom of the hero
  * the handover window: hero frames that differ from the art (first frame)
    until the picture stops changing toward the video; the crossfade's
    duration and alpha curve (projection of F-A onto V-A)
  * geometry: shift of every overlay rect's edge map across the handover
    (must stay 0: scrims/titles/buttons stay put) and of the video's own edge
    map frame to frame after the reveal (no crop/zoom change once seen).
"""
import argparse, json, subprocess, sys

W = 240


def frames(path, fps, start, end):
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height", "-of", "csv=p=0", path], capture_output=True, text=True, check=True)
    sw, sh = (int(v) for v in probe.stdout.strip().split(",")[:2])
    h = max(2, round(W * sh / sw / 2) * 2)
    cmd = ["ffmpeg", "-v", "error"]
    if start: cmd += ["-ss", str(start)]
    cmd += ["-i", path]
    if end: cmd += ["-t", str(end - (start or 0))]
    cmd += ["-vf", f"fps={fps},scale={W}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = W * h
    return h, [raw[i:i + n] for i in range(0, len(raw) - n + 1, n)]


def rect(spec, h):
    x0, y0, x1, y1 = (float(v) for v in spec.split(","))
    return int(x0 * W), int(y0 * h), int(x1 * W), int(y1 * h)


def crop(frame, r):
    x0, y0, x1, y1 = r
    return [frame[y * W + x0:y * W + x1] for y in range(y0, y1)]


def stats(rows):
    total = dark = s = 0
    for row in rows:
        for v in row:
            s += v; total += 1; dark += v < 24
    return s / total, dark / total


def black_rows(rows):
    def black(row): return sum(v < 24 for v in row) / len(row) > 0.97
    top = 0
    while top < len(rows) and black(rows[top]): top += 1
    bottom = 0
    while bottom < len(rows) - top and black(rows[len(rows) - 1 - bottom]): bottom += 1
    return top, bottom


def edges(rows):
    return [[abs(r[x + 1] - r[x]) + (abs(rows[y + 1][x] - r[x]) if y + 1 < len(rows) else 0)
             for x in range(len(r) - 1)] for y, r in enumerate(rows)]


def shift(a, b, reach=6):
    """Best (dx, dy) aligning edge map b onto a, and its error vs no shift."""
    h, w = len(a), len(a[0])
    def err(dx, dy):
        s = n = 0
        for y in range(reach, h - reach):
            ra, rb = a[y], b[y + dy]
            for x in range(reach, w - reach, 2):
                s += abs(ra[x] - rb[x + dx]); n += 1
        return s / max(n, 1)
    energy = sum(sum(r) for r in a) / (h * w)
    base = err(0, 0)
    if energy < 4 or base < energy * 0.25:
        return 0, 0
    best = min(((err(dx, dy), dx, dy) for dx in range(-reach, reach + 1) for dy in range(-reach, reach + 1)))
    # A shift only counts when it explains the difference clearly better.
    if best[0] < base * 0.7 and (best[1], best[2]) != (0, 0):
        return best[1], best[2]
    return 0, 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("video")
    p.add_argument("--hero", required=True)
    p.add_argument("--overlay", action="append", default=[])
    p.add_argument("--static")
    p.add_argument("--reverse", action="store_true")
    p.add_argument("--fps", type=float, default=60)
    p.add_argument("--start", type=float, default=0)
    p.add_argument("--end", type=float, default=0)
    p.add_argument("--out")
    a = p.parse_args()
    h, fs = frames(a.video, a.fps, a.start, a.end)
    if a.reverse:
        fs.reverse()
    hero = rect(a.hero, h)
    still = rect(a.static, h) if a.static else hero
    overlays = [rect(o, h) for o in a.overlay]
    dt = 1 / a.fps

    def at(i):
        """Recording time of frame i, whichever way the frames are read."""
        return round(a.start + ((len(fs) - 1 - i) if a.reverse else i) * dt, 4)
    per = []
    for i, f in enumerate(fs):
        rows = crop(f, hero)
        mean, dark = stats(rows)
        top, bottom = black_rows(rows)
        per.append({"t": at(i), "mean": round(mean, 1), "dark": round(dark, 3),
                    "nearBlack": mean < 18 or dark > 0.92, "barTop": top, "barBottom": bottom})
    # Handover: art = first frame; find the first frame that leaves it, and
    # the frame where the change toward the video stops (alpha ~ 1).
    def diff(x, y):
        rx, ry = crop(x, hero), crop(y, hero)
        return sum(abs(p - q) for r1, r2 in zip(rx, ry) for p, q in zip(r1, r2)) / (len(rx) * len(rx[0]))
    art = fs[0]
    leave = next((i for i in range(1, len(fs)) if diff(art, fs[i]) > 2.0), None)
    report = {"frames": len(fs), "fps": a.fps, "frameStepMs": round(dt * 1000, 1), "reversed": a.reverse}
    if leave is not None:
        # How much of the art is left in each frame: its correlation with the
        # art, scaled between 1 (all art) and the floor it settles at once the
        # video alone is up (median over 0.8-1.5 s after the leave).
        A = [v for r in crop(art, hero) for v in r]
        ma = sum(A) / len(A)
        da = [v - ma for v in A]
        na = sum(d * d for d in da) ** 0.5 or 1
        def corr(i):
            F = [v for r in crop(fs[i], hero) for v in r]
            mf = sum(F) / len(F)
            df = [v - mf for v in F]
            nf = sum(d * d for d in df) ** 0.5 or 1
            return sum(x * y for x, y in zip(da, df)) / (na * nf)
        span = range(max(0, leave - 2), min(len(fs), leave + int(a.fps * 1.5)))
        cs = {i: corr(i) for i in span}
        tail = sorted(cs[i] for i in span if i >= leave + int(a.fps * 0.8)) or [0]
        floor = tail[len(tail) // 2]
        curve = [(at(i), round(max(0, min(1, (1 - cs[i]) / max(1e-6, 1 - floor))), 3)) for i in span]
        begin = next((t for t, al in curve if al >= 0.05), None)
        done = next((t for t, al in curve if al >= 0.95), None)
        report.update({"leaveAt": at(leave), "fadeBegin": begin, "fadeEnd": done,
                       "fadeMs": round(abs(done - begin) * 1000) if done is not None and begin is not None else None,
                       "artCorrelationFloor": round(floor, 3), "alphaCurve": curve})
        last = next((i for i, (t, _) in enumerate(curve) if t == done), None)
        stop = (span[last] if last is not None else leave + int(a.fps)) + int(a.fps * 0.1)
        window = list(range(max(0, leave - int(a.fps * 0.5)), min(len(fs), stop + 1)))
        report["blackInHandover"] = [per[i]["t"] for i in window if per[i]["nearBlack"]]
        report["barsInHandover"] = [per[i]["t"] for i in window if per[i]["barTop"] + per[i]["barBottom"] > 1]
        # Overlays must not move between the art and the video.
        moves = []
        for k, r in enumerate(overlays):
            e0 = edges(crop(fs[max(0, leave - 1)], r))
            for i in window:
                s = shift(e0, edges(crop(fs[i], r)))
                if s != (0, 0): moves.append({"overlay": k, "t": per[i]["t"], "shift": s})
        report["overlayMoves"] = moves
        # Once revealed, the video's framing must not change (no re-crop).
        jumps = []
        after = list(range(span[last], len(fs))) if last is not None else []
        for i, j in zip(after, after[1:]):
            s = shift(edges(crop(fs[i], still)), edges(crop(fs[j], still)))
            if s != (0, 0): jumps.append({"t": per[j]["t"], "shift": s})
        report["videoJumpsAfterReveal"] = jumps[:40]
    report["nearBlackFrames"] = [x["t"] for x in per if x["nearBlack"]]
    report["perFrame"] = per
    out = json.dumps(report, indent=1)
    if a.out:
        open(a.out, "w").write(out)
    summary = {k: v for k, v in report.items() if k not in ("perFrame", "alphaCurve")}
    summary["nearBlackFrames"] = summary["nearBlackFrames"][:20]
    print(json.dumps(summary, indent=1))
    failures = [k for k in ("blackInHandover", "barsInHandover", "overlayMoves", "videoJumpsAfterReveal") if report.get(k)]
    if "leaveAt" not in report:
        failures.append("noHandover")
    print("handover check:", "FAIL " + ", ".join(failures) if failures else "PASS")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
