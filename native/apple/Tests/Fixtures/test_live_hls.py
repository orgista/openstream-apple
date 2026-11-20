from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import urlopen

from live_hls import playlist, sliding_origin
from serve import FixtureHandler, FixtureServer


class SlidingPlaylistTests(unittest.TestCase):
    def test_window_advances_and_expires_old_segments(self):
        first = playlist(0, 900).decode()
        later = playlist(8, 900).decode()
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:6\n", first)
        self.assertIn("segment-00006.ts", first)
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:10\n", later)
        self.assertNotIn("segment-00006.ts", later)
        self.assertIn("segment-00033.ts", later)
        self.assertEqual(later.count("#EXTINF:"), 24)
        self.assertNotIn("#EXT-X-ENDLIST", later)

    def test_playlist_never_advertises_missing_segments(self):
        exhausted = playlist(10000, 32).decode()
        self.assertIn("segment-00031.ts", exhausted)
        self.assertNotIn("segment-00032.ts", exhausted)

    def test_reconnect_playlist_keeps_only_six_seconds_buffered(self):
        initial = playlist(0, 900, window=3, lead=3).decode()
        self.assertEqual(initial.count("#EXTINF:"), 3)
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:0\n", initial)
        self.assertIn("segment-00002.ts", initial)
        self.assertNotIn("segment-00003.ts", initial)

    def test_a_stalled_request_leaves_playlists_segments_and_saved_routes_usable(self):
        with tempfile.TemporaryDirectory() as work:
            server = FixtureServer("127.0.0.1", 0, work)

            def generated_segments(*args, **kwargs):
                directory = Path(args[0][-1]).parent
                for index in range(32):
                    (directory / f"segment-{index:05d}.ts").write_bytes(b"fixture segment")

            with patch("live_hls.subprocess.run", side_effect=generated_segments), \
                    sliding_origin(server, FixtureHandler, work) as environment:
                base = environment["OPENSTREAM_LIVE_LAB_HLS"].removesuffix("/sliding/index.m3u8")
                entered = threading.Event()
                original_wait = server.live_fixture_stopped.wait

                def stalled(timeout):
                    entered.set()
                    return original_wait(timeout)

                def blocked_request(path="/stalled/index.m3u8"):
                    try:
                        urlopen(base + path, timeout=3).close()
                    except HTTPError as error:
                        return error.code

                serving = threading.Thread(target=server.serve_forever)
                serving.start()
                try:
                    with patch.object(server.live_fixture_stopped, "wait", side_effect=stalled), \
                            ThreadPoolExecutor(max_workers=1) as requests:
                        pending = requests.submit(blocked_request)
                        try:
                            self.assertTrue(entered.wait(1), "The stalled handler must be active")
                            for path in ["/sliding/index.m3u8", "/sliding/segment-00006.ts",
                                         "/reconnect-surface/stream", "/reconnect-surface/segment-00000.ts",
                                         "/saved/channels.m3u", "/saved/stall"]:
                                with self.subTest(path=path), urlopen(base + path, timeout=1) as response:
                                    self.assertEqual(response.status, 200)
                            self.assertFalse(pending.done())
                        finally:
                            server.live_fixture_stopped.set()
                        self.assertEqual(pending.result(timeout=2), 503)
                        entered.clear()
                        server.live_fixture_stopped.clear()
                        for path in ["/reconnect/reset", "/reconnect/index.m3u8", "/reconnect/stall"]:
                            with urlopen(base + path, timeout=1) as response:
                                self.assertEqual(response.status, 200)
                        pending = requests.submit(blocked_request, "/reconnect/index.m3u8")
                        try:
                            self.assertTrue(entered.wait(1), "The playing stream must now stall")
                            with urlopen(base + "/sliding/index.m3u8", timeout=1) as response:
                                self.assertEqual(response.status, 200)
                            self.assertFalse(pending.done())
                        finally:
                            server.live_fixture_stopped.set()
                        self.assertEqual(pending.result(timeout=2), 503)
                finally:
                    server.shutdown()
                    server.server_close()
                    serving.join()


if __name__ == "__main__":
    unittest.main()
