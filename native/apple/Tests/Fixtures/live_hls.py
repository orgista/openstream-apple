"""Sliding HLS and a stalled origin, confined to the test process's loopback server."""
from contextlib import contextmanager
import math
from pathlib import Path
import subprocess
import threading
import time


def playlist(elapsed, count, window=24, lead=30):
    end = min(count, lead + max(0, math.floor(elapsed / 2)))
    start = max(0, end - window)
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2",
             f"#EXT-X-MEDIA-SEQUENCE:{start}", "#EXT-X-INDEPENDENT-SEGMENTS"]
    for index in range(start, end):
        lines += ["#EXTINF:2.000,", f"segment-{index:05d}.ts"]
    return ("\n".join(lines) + "\n").encode()


@contextmanager
def sliding_origin(server, handler, work):
    root = Path(work) / "sliding-hls"
    root.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=128x72:rate=10", "-f", "lavfi", "-i",
                    "anullsrc=channel_layout=stereo:sample_rate=48000", "-t", "1800",
                    "-c:v", "libx264", "-preset", "ultrafast", "-g", "20", "-sc_threshold", "0",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "hls", "-hls_time", "2",
                    "-hls_list_size", "0", "-hls_segment_filename", str(root / "segment-%05d.ts"),
                    str(root / "generated.m3u8")], check=True)
    count = len(list(root.glob("segment-*.ts")))
    surface_root = root / "surface"
    surface_root.mkdir()
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                    "testsrc2=size=128x72:rate=10", "-f", "lavfi", "-i",
                    "anullsrc=channel_layout=stereo:sample_rate=48000", "-t", "1800",
                    "-c:v", "mpeg2video", "-g", "20", "-c:a", "mp2", "-f", "hls",
                    "-hls_time", "2", "-hls_list_size", "0", "-hls_segment_filename",
                    str(surface_root / "segment-%05d.ts"), str(surface_root / "surface.m3u8")], check=True)
    surface_count = len(list(surface_root.glob("segment-*.ts")))
    started = time.monotonic()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    saved_stalled = threading.Event()
    reconnect_stalled = threading.Event()
    reconnect_started = time.monotonic()

    def channels(stalled=False):
        lines = ["#EXTM3U"]
        for index in range(60):
            name = "A&E Fixture" if stalled and index == 0 else f"Fixture Live {index + 1}"
            stream = "/stalled/index.m3u8" if stalled and index == 0 else "/sliding/index.m3u8"
            lines += [f'#EXTINF:-1 tvg-id="fixture-{index}" tvg-logo="{base}/jf/Items/fixture/Images/Primary" group-title="Group {index % 12 + 1}",{name}',
                      base + stream]
        return ("\n".join(lines) + "\n").encode()

    class LiveHandler(handler):
        def stalled_response(self, delay=65):
            server.live_fixture_stopped.wait(delay)
            try:
                return self._send_simple(503)
            except (BrokenPipeError, ConnectionResetError):
                return None

        def do_GET(self):
            nonlocal reconnect_started
            path = self.path.split("?", 1)[0]
            if path == "/reconnect/reset":
                reconnect_started = time.monotonic()
                reconnect_stalled.clear()
                return self._send_simple(200)
            if path == "/reconnect/stall":
                reconnect_stalled.set()
                return self._send_simple(200)
            if path in ("/reconnect/index.m3u8", "/reconnect-surface/stream"):
                if reconnect_stalled.is_set():
                    return self.stalled_response(delay=3)
                segments = surface_count if path.startswith("/reconnect-surface/") else count
                return self._send_simple(200, playlist(time.monotonic() - reconnect_started, segments, window=3, lead=3),
                                         "application/vnd.apple.mpegurl")
            if path in ("/sliding/channels.m3u", "/failure/channels.m3u"):
                return self._send_simple(200, channels(path.startswith("/failure/")), "audio/x-mpegurl")
            if path == "/saved/channels.m3u":
                if not saved_stalled.is_set():
                    return self._send_simple(200, channels(), "audio/x-mpegurl")
                return self.stalled_response()
            if path == "/saved/stall":
                saved_stalled.set()
                return self._send_simple(200)
            if path == "/sliding/index.m3u8":
                return self._send_simple(200, playlist(time.monotonic() - started, count),
                                         "application/vnd.apple.mpegurl")
            if path.startswith(("/sliding/segment-", "/reconnect/segment-", "/reconnect-surface/segment-")) and path.endswith(".ts"):
                folder = surface_root if path.startswith("/reconnect-surface/") else root
                file = folder / Path(path).name
                if file.is_file():
                    return self._serve_file(str(file), allow_range=True)
                return self._send_simple(404)
            if path == "/stalled/index.m3u8":
                # A silent origin reproduces the startup watchdog, rather than a fast HTTP error.
                return self.stalled_response()
            return super().do_GET()

    server.live_fixture_stopped = threading.Event()
    server.RequestHandlerClass = LiveHandler
    try:
        yield {"OPENSTREAM_LIVE_LAB_HLS": base + "/sliding/index.m3u8",
               "OPENSTREAM_LIVE_LAB_STALLED": base + "/stalled/index.m3u8"}
    finally:
        server.live_fixture_stopped.set()
        server.RequestHandlerClass = handler
