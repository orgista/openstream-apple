#!/usr/bin/env python3
"""Loopback fixture HTTP server for OpenStream playback-engine tests.

Routes mirror the contract required by T3's fixture tests:

  GET /media/<name>      static file from out/, Range requests supported
  GET /live/<name>.ts    looped TS stream, chunked transfer, ~1.5 MB/s
  GET /slow/<name>       sleeps 12 s, then behaves like /media/<name>
  GET /protected/<name>  requires Referer: https://fixtures.local/...
  GET /hls/<path>        static file from out/hls/
  /jf/...                a small Jellyfin library (movies, one series, resume, images, playback, trailers)
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
import struct
import time
import zlib
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


TICKS = 10_000_000
RUNTIME_TICKS = 1800 * TICKS
IMAGE_TAG = "fixture"
RESUME_ID = "jf-movie-6"
LIBRARIES = [
    {"Id": "jf-lib-movies", "Name": "Movies", "CollectionType": "movies"},
    {"Id": "jf-lib-shows", "Name": "Shows", "CollectionType": "tvshows"},
]


def _fixture_item(item_id, name, kind, parent, **fields):
    item = {"Id": item_id, "Name": name, "Type": kind, "ServerId": "fixture-server",
            "ImageTags": {"Primary": IMAGE_TAG}, "BackdropImageTags": [], "Genres": [], "ProviderIds": {}}
    item.update(fields)
    return item, parent


def _fixture_catalog():
    entries = []
    for n in range(2, 7):
        entries.append(_fixture_item(
            f"jf-movie-{n}", f"Stub Movie {['Two', 'Three', 'Four', 'Five', 'Six'][n - 2]}", "Movie", "jf-lib-movies",
            ProductionYear=2024, Overview=f"A fixture movie, number {n}.", RunTimeTicks=RUNTIME_TICKS,
            Genres=["Drama"] if n < 4 else ["Comedy"], CommunityRating=7.0 + n / 10,
            ProviderIds={"Imdb": f"tt000000{n}"},
            ImageTags={"Primary": IMAGE_TAG, "Backdrop": IMAGE_TAG, "Logo": IMAGE_TAG},
            BackdropImageTags=[IMAGE_TAG]))
    entries.append(_fixture_item(
        "jf-series-10", "Stub Series", "Series", "jf-lib-shows", ProductionYear=2025,
        Overview="A fixture series.", Genres=["Drama"], CommunityRating=8.0, ProviderIds={"Imdb": "tt0000010"},
        ImageTags={"Primary": IMAGE_TAG, "Backdrop": IMAGE_TAG, "Logo": IMAGE_TAG}, BackdropImageTags=[IMAGE_TAG]))
    for season in (1, 2):
        entries.append(_fixture_item(
            f"jf-season-{season}", f"Season {season}", "Season", "jf-series-10", IndexNumber=season,
            SeriesId="jf-series-10", SeriesName="Stub Series"))
        for episode in (1, 2, 3):
            entries.append(_fixture_item(
                f"jf-ep-{season}-{episode}", f"Chapter {season}.{episode}", "Episode", f"jf-season-{season}",
                IndexNumber=episode, ParentIndexNumber=season, SeriesId="jf-series-10", SeasonId=f"jf-season-{season}",
                SeriesName="Stub Series", Overview=f"Season {season}, episode {episode}.", RunTimeTicks=RUNTIME_TICKS))
    return {item["Id"]: item for item, _ in entries}, {item["Id"]: parent for item, parent in entries}


ITEMS, PARENTS = _fixture_catalog()


def _png(width, height, rgba, visionos=False):
    rows = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))
    if visionos:
        rows = bytearray()
        for y in range(height):
            rows.append(0)
            for x in range(width):
                colour = rgba
                if y > height * 0.65 - abs(x - width * 0.4) * 0.45:
                    colour = (15, 25, 45, 255)
                elif (x - width * 0.72)**2 + (y - height * 0.28)**2 < (min(width, height) * 0.14)**2:
                    colour = (255, 190, 90, 255)
                rows.extend(colour)
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


IMAGES = {"Primary": _png(200, 300, (70, 90, 140, 255)),
          "Backdrop": _png(320, 180, (40, 60, 100, 255)),
          "Thumb": _png(320, 180, (40, 60, 100, 255)),
          "Logo": _png(300, 100, (255, 255, 255, 64))}
VISION_IMAGES = {**IMAGES, "Primary": _png(200, 300, (70, 90, 140, 255), visionos=True),
                 "Backdrop": _png(320, 180, (40, 60, 100, 255), visionos=True),
                 "Thumb": _png(320, 180, (40, 60, 100, 255), visionos=True)}


def _present(item, visionos=False):
    shown = dict(item)
    if visionos:
        shown["ImageTags"] = {kind: tag for kind, tag in item["ImageTags"].items() if kind != "Logo"}
    data = {"PlaybackPositionTicks": 0, "PlayedPercentage": 0, "Played": False, "IsFavorite": False, "PlayCount": 0}
    if item["Id"] == RESUME_ID:
        stamp = datetime.now(timezone.utc) - timedelta(minutes=5)
        data.update(PlaybackPositionTicks=120 * TICKS, PlayedPercentage=6.7,
                    LastPlayedDate=stamp.strftime("%Y-%m-%dT%H:%M:%S.000Z"))
    shown["UserData"] = data
    return shown


def _children(parent_id):
    return [item for item_id, item in ITEMS.items() if PARENTS[item_id] == parent_id]


def _descendants(parent_id):
    found = []
    for child in _children(parent_id):
        found.append(child)
        found.extend(_descendants(child["Id"]))
    return found


def _media_source(item_id, visionos=False):
    audio = [{"Type": "Audio", "Codec": "aac", "Index": 1, "Channels": 2, "Language": "eng", "IsDefault": True}]
    if visionos:
        audio.append({"Type": "Audio", "Codec": "aac", "Index": 2, "Channels": 2, "Language": "spa", "IsDefault": False})
    return {"Id": item_id, "Name": item_id, "Container": "mp4", "Protocol": "File", "RunTimeTicks": RUNTIME_TICKS,
            "Bitrate": 1000000, "SupportsDirectPlay": True, "SupportsDirectStream": True, "SupportsTranscoding": False,
            "MediaStreams": [
                {"Type": "Video", "Codec": "h264", "Index": 0, "Width": 256, "Height": 144, "Profile": "High", "Level": 40}]
                + audio + [{"Type": "Subtitle", "Codec": "mov_text", "Index": 3 if visionos else 2,
                            "Language": "eng", "IsTextSubtitleStream": True}]}


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

        if parsed.path.startswith("/jf/"):
            return self._serve_jellyfin(parsed.path[len("/jf"):], query)

        # E2E playback keeps a long generated clip alive; downloads trickle so
        # the tests can observe and cancel the real downloading state.
        if path in ("/media/e2e-long.mp4", "/e2e-download/e2e-long.mp4"):
            clip = getattr(self.server, "e2e_media", None)
            if clip is None:
                return self._send_simple(404, b"no E2E clip configured")
            return self._serve_file(clip, allow_range=True, throttle=path.startswith("/e2e-download/"))

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
            if name in ("cbs.ts", "fixture-news.ts", "fixture-film.ts") and getattr(self.server, "e2e_live", None):
                fpath = self.server.e2e_live
            else:
                fpath = self._safe_path(root, name)
            if fpath is None:
                return self._send_simple(404, b"not found")
            return self._serve_live(fpath)

        return self._send_simple(404, b"not found")

    # HEAD is implemented by doing GET without a body.
    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self.protocol_version = "HTTP/1.0"
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        parsed = urlsplit(self.path)
        if parsed.path.split("/") == ["", "jf", "Users", "AuthenticateByName"]:
            if getattr(self.server, "require_auth", False):
                try:
                    credentials = json.loads(body)
                except (ValueError, TypeError):
                    return self._send_simple(400)
                if credentials.get("Username") != "fixture" or credentials.get("Pw") != "fixture-password":
                    print("fixture password authentication rejected", flush=True)
                    return self._send_simple(401)
                print("fixture password authentication accepted", flush=True)
            return self._send_json({"User": {"Id": "fixture-user", "Name": "fixture"},
                                    "AccessToken": "fixture-token", "ServerId": "fixture-server"})
        if parsed.path.startswith("/jf/"):
            match = re.match(r"^/jf/Items/([^/]+)/PlaybackInfo$", parsed.path)
            if match:
                item_id = match.group(1)
                sources = [_media_source(item_id, visionos=self.server.visionos)]
                if self.server.visionos and item_id == "jf-movie-2":
                    sources[0]["Name"] = "Original"
                    alternate = _media_source(item_id + "-alternate", visionos=True)
                    alternate["Name"] = "Alternate"
                    sources.append(alternate)
                return self._send_json({"MediaSources": sources, "PlaySessionId": "fixture-play"})
            if parsed.path.startswith("/jf/Sessions/Playing"):
                return self._send_simple(204)
        return self._send_simple(404, b"not found")

    # ------------------------------------------------------------------
    # a small Jellyfin library (/jf/...)
    # ------------------------------------------------------------------
    def _page(self, items, query):
        start = int(query.get("StartIndex", ["0"])[0])
        limit = int(query.get("Limit", ["100"])[0])
        return self._send_json({"Items": [_present(item, visionos=self.server.visionos) for item in items[start:start + limit]],
                                "TotalRecordCount": len(items), "StartIndex": start})

    def _query_items(self, query):
        parent = query.get("ParentId", [""])[0]
        types = [t for t in query.get("IncludeItemTypes", [""])[0].split(",") if t]
        if parent:
            items = _descendants(parent) if types else _children(parent)
        else:
            items = [item for item in ITEMS.values() if item["Type"] in (types or ("Movie", "Series"))]
        if types:
            items = [item for item in items if item["Type"] in types]
        genres = [g for g in query.get("Genres", [""])[0].split("|") if g]
        if genres:
            items = [item for item in items if set(genres) & set(item["Genres"])]
        term = query.get("SearchTerm", [""])[0].lower()
        if term:
            items = [item for item in items if term in item["Name"].lower()]
        return sorted(items, key=lambda item: item["Name"])

    def _serve_clip(self, item_id, download=False):
        if item_id.startswith("trailer-"):
            return self._serve_file(os.path.join(self.server.root, "trailer-letterbox-fade.mp4"),
                                    allow_range=True, throttle=download)
        clip = getattr(self.server, "e2e_media", None)
        return self._serve_file(clip or os.path.join(self.server.root, "mp4-h264-aac.mp4"),
                                allow_range=True, throttle=download)

    def _serve_jellyfin(self, path, query):
        user = "/".join(("", "Users", "fixture-user"))
        if getattr(self.server, "require_auth", False) and path not in ("/System/Info/Public", "/QuickConnect/Enabled"):
            if self.headers.get("X-Emby-Token") != "fixture-token":
                return self._send_simple(401)
            if path == user:
                print("fixture saved token accepted", flush=True)
        if path == "/System/Info/Public":
            return self._send_json({"ServerName": "Fixture", "Version": "10.10.7", "Id": "fixture-server",
                                    "ProductName": "Jellyfin Server"})
        if path == "/QuickConnect/Enabled":
            return self._send_simple(200, b"false", "application/json")
        if path == user:
            return self._send_json({"Id": "fixture-user", "Name": "fixture", "ServerId": "fixture-server",
                                    "Policy": {"EnableContentDownloading": True}})
        if path == user + "/Views":
            return self._send_json({"Items": LIBRARIES, "TotalRecordCount": len(LIBRARIES), "StartIndex": 0})
        if path == user + "/Items/Latest":
            parent = query.get("ParentId", [""])[0]
            items = _children(parent) if parent else [i for i in ITEMS.values() if i["Type"] in ("Movie", "Series")]
            limit = int(query.get("Limit", ["20"])[0])
            return self._send_json([_present(item, visionos=self.server.visionos) for item in reversed(items)][:limit])
        if path == user + "/Items/Resume":
            return self._page([ITEMS[RESUME_ID]], query)
        if path == user + "/Items":
            return self._page(self._query_items(query), query)
        if path == "/Shows/NextUp":
            first = ITEMS["jf-ep-1-1"]
            return self._page([first] if query.get("ParentId", [""])[0] == "jf-lib-shows" else [], query)
        match = re.match("^" + re.escape(user) + r"/Items/([^/]+)$", path)
        if match:
            item = ITEMS.get(match.group(1))
            return self._send_json(_present(item, visionos=self.server.visionos)) if item else self._send_simple(404, b"not found")
        match = re.match(r"^/Shows/([^/]+)/Seasons$", path)
        if match:
            return self._page(_children(match.group(1)), query)
        match = re.match(r"^/Shows/([^/]+)/Episodes$", path)
        if match:
            season = query.get("SeasonId", [""])[0]
            return self._page([i for i in _descendants(match.group(1)) if i["Type"] == "Episode"
                               and (not season or i["SeasonId"] == season)], query)
        match = re.match(r"^/Items/([^/]+)/LocalTrailers$", path)
        if match:
            trailer = "trailer-" + match.group(1)
            return self._send_json([{"Id": trailer, "Name": "Trailer", "Container": "mp4", "RunTimeTicks": 100000000,
                                     "MediaSources": [{"Id": trailer, "Container": "mp4"}]}])
        match = re.match(r"^/Items/[^/]+/Images/([A-Za-z]+)$", path)
        if match:
            images = VISION_IMAGES if self.server.visionos else IMAGES
            return self._send_simple(200, images.get(match.group(1), images["Primary"]), "image/png")
        match = re.match(r"^/(?:Videos/([^/]+)/stream(?:\.\w+)?|Items/([^/]+)/Download)$", path)
        if match:
            return self._serve_clip(match.group(1) or match.group(2), download=match.group(2) is not None)
        return self._send_json({"Items": [], "TotalRecordCount": 0})

    # ------------------------------------------------------------------
    # file serving (with optional byte-range)
    # ------------------------------------------------------------------
    def _serve_file(self, fpath, allow_range, throttle=False):
        # Serve only files under the fixture root, or the configured E2E clip.
        fpath = os.path.realpath(fpath)
        root = os.path.realpath(self.server.root)
        clip = getattr(self.server, "e2e_media", None)
        allowed_clip = os.path.realpath(clip) if clip else None
        if not fpath.startswith(root + os.sep) and fpath != allowed_clip:
            return self._send_simple(404, b"not found")
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
                    chunk = f.read(min(8192 if throttle else 65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    if throttle:
                        self.wfile.flush()
                        time.sleep(0.3)
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

        chunk_size = getattr(self.server, "live_chunk_size", 64 * 1024)
        target_bps = getattr(self.server, "live_target_bps", 1.5 * 1024 * 1024)
        sleep_per_chunk = chunk_size / target_bps
        bootstrap_remaining = getattr(self.server, "live_bootstrap_bytes", 0)

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
                        if bootstrap_remaining > 0:
                            bootstrap_remaining -= len(chunk)
                        else:
                            time.sleep(sleep_per_chunk)
        except (BrokenPipeError, ConnectionResetError):
            # Client disconnected; send the final chunk if possible.
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, host, port, root, visionos=False):
        self.root = os.path.abspath(root)
        self.visionos = visionos
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
    parser.add_argument("--visionos", action="store_true", help="Vision E2E audio, versions and artwork options")
    parser.add_argument("--require-auth", action="store_true", help="Require fixture Jellyfin credentials and token")
    args = parser.parse_args()

    host = "127.0.0.1"
    server = FixtureServer(host, args.port, args.root, visionos=args.visionos)
    server.require_auth = args.require_auth
    print(f"fixtures listening on {host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
