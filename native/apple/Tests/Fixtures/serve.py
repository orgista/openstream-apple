#!/usr/bin/env python3
"""Loopback fixture HTTP server for OpenStream playback-engine tests.

Routes mirror the contract required by T3's fixture tests:

  GET /media/<name>      static file from out/, Range requests supported
  GET /live/<name>.ts    looped TS stream, chunked transfer, ~1.5 MB/s
  GET /slow/<name>       sleeps 12 s, then behaves like /media/<name>
  GET /protected/<name>  requires Referer: https://fixtures.local/...
  GET /hls/<path>        static file from out/hls/
  *                      404

Run:

  python3 Tests/Fixtures/serve.py
  python3 Tests/Fixtures/serve.py --port 9999 --root /other/out

Tests pick the server up with PLAYBACK_ENGINE_TESTS=1 and an optional
FIXTURE_BASE_URL environment variable (default http://127.0.0.1:8765).
"""

import argparse
import json
import os
import re
import time
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FixtureHandler(BaseHTTPRequestHandler):
    """HTTP request handler that serves generated fixture media."""

    # Default to HTTP/1.0 so plain file responses look like the test expects.
    protocol_version = "HTTP/1.0"

    MIME = {
        ".ts": "video/mp2t",
        ".mkv": "video/x-matroska",
        ".mp4": "video/mp4",
        ".m3u8": "application/vnd.apple.mpegurl",
    }

    def log_message(self, fmt, *args):
        # Quiet by default; failures are still returned to the client.
        pass

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------
    def _ctype(self, path):
        ext = os.path.splitext(path)[1].lower()
        return self.MIME.get(ext, "application/octet-stream")

    def _safe_path(self, base, rel):
        """Return an absolute path under `base` or None if it escapes."""
        rel = rel.lstrip("/")
        target = os.path.realpath(os.path.join(base, rel))
        base_real = os.path.realpath(base)
        if target == base_real or target.startswith(base_real + os.sep):
            return target
        return None

    def _send_simple(self, status, body=b"", ctype="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _send_json(self, value):
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    # ------------------------------------------------------------------
    # routing
    # ------------------------------------------------------------------
    def do_GET(self):
        # /live/ needs HTTP/1.1 chunked transfer; everything else is HTTP/1.0.
        if self.path.startswith("/live/"):
            self.protocol_version = "HTTP/1.1"
        else:
            self.protocol_version = "HTTP/1.0"

        path = self.path
        root = self.server.root

        parsed = urlsplit(path)
        query = parse_qs(parsed.query)
        if parsed.path == "/iptv/stream.m3u8":
            base = f"http://127.0.0.1:{self.server.server_address[1]}"
            return self._send_simple(200, f"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000\n{base}/hls/index.m3u8\n".encode(), "application/vnd.apple.mpegurl")
        if parsed.path == "/iptv/control":
            self.server.iptv_count = min(max(int(query.get("count", ["12"])[0]), 1), 25000)
            self.server.iptv_delay_ms = min(max(int(query.get("delay_ms", ["0"])[0]), 0), 1000)
            return self._send_simple(200, b"synthetic lineup updated")
        if parsed.path in ("/iptv/playlist.m3u", "/iptv/guide.xml", "/iptv/broken.xml"):
            count = min(max(int(query.get("count", [str(getattr(self.server, "iptv_count", 12))])[0]), 1), 25000)
            base = f"http://127.0.0.1:{self.server.server_address[1]}"
            if parsed.path.endswith("playlist.m3u"):
                guide = f"{base}/iptv/guide.xml?count={count}"
                body = f'#EXTM3U x-tvg-url="{guide}"\n' + "".join(
                    f'#EXTINF:-1 tvg-id="fixture-{i}" group-title="{("Family" if i % 2 == 0 else "Restricted")}" tvg-logo="{base}/fixture-poster.svg" catchup="default" catchup-days="2" catchup-source="{base}/iptv/stream.m3u8?start={{utc}}",Fixture Channel {i + 1}\n{base}/iptv/stream.m3u8?channel={i}\n'
                    for i in range(count))
                data = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    for offset in range(0, len(data), 65536):
                        self.wfile.write(data[offset:offset + 65536])
                        self.wfile.flush()
                        time.sleep(getattr(self.server, "iptv_delay_ms", 0) / 1000)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if parsed.path.endswith("broken.xml"):
                return self._send_simple(200, b"<tv><programme", "application/xml")
            now = int(time.time())
            def stamp(value):
                return time.strftime("%Y%m%d%H%M%S +0000", time.gmtime(value))
            body = '<tv>' + ''.join(f'<channel id="fixture-{i}"><display-name>Fixture Channel {i + 1}</display-name></channel>' for i in range(count))
            body += ''.join(f'<programme channel="fixture-{i}" start="{stamp(now + j * 1800)}" stop="{stamp(now + (j + 1) * 1800)}"><title>Synthetic Programme {i + 1} / {j + 3}</title></programme>' for i in range(count) for j in range(-2, 6)) + '</tv>'
            return self._send_simple(200, body.encode(), "application/xml")
        if parsed.path == "/player_api.php":
            action = query.get("action", [""])[0]
            if query.get("username", [""])[0] == "fixture-failure" and action.startswith(("get_vod", "get_series")):
                return self._send_simple(503, b"fixture unavailable")
            base = f"http://127.0.0.1:{self.server.server_address[1]}"
            movie = {"stream_id": 101, "name": "Fixture Movie", "category_id": "1",
                     "stream_icon": f"{base}/fixture-poster.svg", "plot": "A synthetic provider movie.",
                     "year": "2024", "rating": "8.1", "container_extension": "mp4"}
            series = {"series_id": 201, "name": "Fixture Series", "category_id": "2",
                      "cover": f"{base}/fixture-poster.svg", "plot": "A synthetic provider series.",
                      "releaseDate": "2025-01-01", "rating": "7.5"}
            if action in ("get_vod_categories", "get_series_categories", "get_live_categories"):
                return self._send_json([{"category_id": "2" if action == "get_series_categories" else "1",
                                         "category_name": "Fixture Category"}])
            if action == "get_vod_streams":
                # Optional stress catalogue: /player_api.php?...&fixture_count=25000
                count = min(max(int(query.get("fixture_count", ["2"])[0]), 1), 50000)
                return self._send_json([dict(movie, stream_id=101+i,
                    name="Fixture Movie" if i == 0 else f"Fixture Movie {i+1}") for i in range(count)])
            if action == "get_series":
                return self._send_json([series])
            if action == "get_vod_info":
                return self._send_json({"info": movie, "movie_data": movie})
            if action == "get_series_info":
                episodes = {str(season): [{"id": str(300+season*10+number), "title": f"Episode {number}",
                    "season": season, "episode_num": number, "container_extension": "mp4"}
                    for number in (1, 2)] for season in (1, 2)}
                return self._send_json({"info": series, "seasons": [{"season_number": 1}, {"season_number": 2}],
                                        "episodes": episodes})
            if action == "get_live_streams":
                return self._send_json([{"stream_id": 1, "name": "Fixture Live", "category_id": "1",
                                         "container_extension": "m3u8", "stream_icon": ""}])
            if action == "get_short_epg":
                return self._send_json({"epg_listings": []})
            return self._send_json({"user_info": {"auth": 1, "status": "Active",
                "allowed_output_formats": ["m3u8"], "max_connections": "4"}, "server_info": {"timezone": "UTC"}})
        if re.match(r"^/(movie|series)/[^/]+/[^/]+/\d+\.mp4$", parsed.path):
            return self._serve_file(os.path.join(root, "mp4-h264-aac.mp4"), allow_range=True)
        if re.match(r"^/live/[^/]+/[^/]+/1\.m3u8$", parsed.path):
            return self._send_simple(200, f"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000\nhttp://127.0.0.1:{self.server.server_address[1]}/hls/index.m3u8\n".encode(), "application/vnd.apple.mpegurl")
        if parsed.path == "/fixture-poster.svg":
            return self._send_simple(200, b'<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450"><rect width="300" height="450" fill="gray"/><text x="30" y="200" fill="white" font-size="32">Fixture</text></svg>', "image/svg+xml")

        if path == "/addon/manifest.json":
            return self._send_json({
                "id": "org.openstream.fixture",
                "version": "1.0.0",
                "name": "Fixture Add-on",
                "description": "Local test streams",
                "resources": ["stream"],
                "types": ["movie", "series"],
                "idPrefixes": ["tt"],
                "catalogs": [],
            })

        if re.match(r"^/addon/stream/(movie|series)/[^/]+\.json$", path):
            stream_base_url = f"http://127.0.0.1:{self.server.server_address[1]}"
            return self._send_json({
                "streams": [
                    {
                        "name": "Fixture 1080p",
                        "title": "Sample MKV (H.264/AAC)",
                        "url": f"{stream_base_url}/media/mkv-h264-aac.mkv",
                    },
                    {
                        "name": "Fixture HDR",
                        "title": "Sample MP4 (HEVC HDR10)",
                        "url": f"{stream_base_url}/media/hdr10-hevc.mp4",
                    },
                ],
            })

        if path.startswith("/media/"):
            name = path[len("/media/"):]
            fpath = self._safe_path(root, name)
            if fpath is None:
                return self._send_simple(404, b"not found")
            return self._serve_file(fpath, allow_range=True)

        if path.startswith("/slow/"):
            name = path[len("/slow/"):]
            fpath = self._safe_path(root, name)
            if fpath is None:
                return self._send_simple(404, b"not found")
            time.sleep(12)
            return self._serve_file(fpath, allow_range=True)

        if path.startswith("/protected/"):
            name = path[len("/protected/"):]
            fpath = self._safe_path(root, name)
            if fpath is None:
                return self._send_simple(404, b"not found")
            referer = self.headers.get("Referer", "")
            if not referer.startswith("https://fixtures.local/"):
                return self._send_simple(403, b"referer required")
            return self._serve_file(fpath, allow_range=True)

        if path.startswith("/hls/"):
            sub = path[len("/hls/"):]
            fpath = self._safe_path(os.path.join(root, "hls"), sub)
            if fpath is None:
                return self._send_simple(404, b"not found")
            return self._serve_file(fpath, allow_range=True)

        if path.startswith("/live/"):
            name = path[len("/live/"):]
            if not name.endswith(".ts"):
                return self._send_simple(404, b"not found")
            fpath = self._safe_path(root, name)
            if fpath is None:
                return self._send_simple(404, b"not found")
            return self._serve_live(fpath)

        return self._send_simple(404, b"not found")

    # HEAD is implemented by doing GET without a body.
    def do_HEAD(self):
        self.do_GET()

    # ------------------------------------------------------------------
    # file serving (with optional byte-range)
    # ------------------------------------------------------------------
    def _serve_file(self, fpath, allow_range):
        if not os.path.isfile(fpath):
            return self._send_simple(404, b"not found")

        size = os.path.getsize(fpath)
        ctype = self._ctype(fpath)
        range_hdr = self.headers.get("Range") if allow_range else None

        start = 0
        end = size - 1
        status = 200

        if range_hdr:
            m = re.match(r"^bytes=(\d*)-(\d*)$", range_hdr)
            if m:
                rs, re_ = m.group(1), m.group(2)
                if rs:
                    start = int(rs)
                    end = int(re_) if re_ else size - 1
                    end = min(end, size - 1)
                elif re_:
                    suffix = int(re_)
                    start = max(0, size - suffix)
                    end = size - 1
                else:
                    start = 0
                    end = size - 1

                if 0 <= start <= end < size:
                    status = 206
                else:
                    status = 416

        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")

        if status == 416:
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        cl = end - start + 1
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(cl))
        self.end_headers()

        if self.command == "HEAD":
            return

        try:
            with open(fpath, "rb") as f:
                if start:
                    f.seek(start)
                remaining = cl
                while remaining > 0:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    # ------------------------------------------------------------------
    # live looped stream
    # ------------------------------------------------------------------
    def _serve_live(self, fpath):
        if not os.path.isfile(fpath):
            return self._send_simple(404, b"not found")

        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        if self.command == "HEAD":
            return

        chunk_size = 64 * 1024
        target_bps = 1.5 * 1024 * 1024
        sleep_per_chunk = chunk_size / target_bps

        try:
            while True:
                with open(fpath, "rb") as f:
                    while True:
                        chunk = f.read(chunk_size)
                        if not chunk:
                            break
                        self.wfile.write(f"{len(chunk):X}\r\n".encode())
                        self.wfile.write(chunk)
                        self.wfile.write(b"\r\n")
                        self.wfile.flush()
                        time.sleep(sleep_per_chunk)
        except (BrokenPipeError, ConnectionResetError):
            # Client disconnected; send the final chunk if possible.
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, host, port, root):
        self.root = os.path.abspath(root)
        super().__init__((host, port), FixtureHandler)


def _default_root():
    """Default to an `out/` directory next to this script."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def main():
    parser = argparse.ArgumentParser(description="OpenStream fixture server")
    parser.add_argument("--port", type=int, default=8765,
                        help="TCP port to listen on (default: 8765)")
    parser.add_argument("--root", default=_default_root(),
                        help="fixture root directory (default: Tests/Fixtures/out)")
    args = parser.parse_args()

    host = "127.0.0.1"
    server = FixtureServer(host, args.port, args.root)
    print(f"fixtures listening on {host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
