import importlib.util
import ast
import io
import json
import shutil
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import threading
import time
import os
import plistlib
import re
import struct
import sys
import zlib
from urllib.error import HTTPError
from urllib.request import Request, urlopen


spec = importlib.util.spec_from_file_location("run_e2e", Path(__file__).with_name("run-e2e.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CloudHoldRunnerTests(unittest.TestCase):
    def test_runner_hold_uses_arguments_on_first_launch_and_after_reassignment(self):
        for arguments in [[], ["-OpenStreamTrace", "YES"],
                          ["-openstream.reset.cloudRestoreHeld.v1", "NO", "-OpenStreamTrace", "YES"],
                          ["-openstream.reset.cloudRestoreHeld.v1", "YES"]]:
            with self.subTest(arguments=arguments):
                held = runner.cloud_held_arguments(arguments)
                self.assertEqual(held[-2:], ["-openstream.reset.cloudRestoreHeld.v1", "YES"])
                self.assertEqual(held.count("-openstream.reset.cloudRestoreHeld.v1"), 1)

    def test_seed_launch_holds_cloud_before_the_app_starts_with_and_without_reset(self):
        seed = Path(runner.ROOT) / "scripts/seed-sim.sh"
        for reset in [False, True]:
            with self.subTest(reset=reset), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                app = root / "app"
                app.mkdir()
                sources = root / "sources.json"
                sources.write_text('{"version":1,"sources":[]}')
                arguments = root / "launch.json"
                xcrun = root / "xcrun"
                xcrun.write_text("#!/usr/bin/env python3\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
app = pathlib.Path(os.environ["FIXTURE_APP"])
if args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {"fixture": [{"udid": "fixture-simulator", "name": "Fixture", "state": "Booted"}]}}))
elif args[:2] == ["simctl", "get_app_container"]:
    print(app)
elif args[:2] == ["simctl", "launch"]:
    pathlib.Path(os.environ["FIXTURE_ARGUMENTS"]).write_text(json.dumps(args))
    (app / "Library/Caches/openstream-trace.log").write_text("dev sources: done\\n")
    (app / "Library/Caches/dev-sources.json").unlink()
''')
                xcrun.chmod(0o755)
                result = subprocess.run(["bash", str(seed), "fixture-simulator"] + (["--reset"] if reset else []),
                                        capture_output=True, text=True, timeout=10,
                                        env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                                             "DEV_SOURCES": str(sources), "FIXTURE_APP": str(app),
                                             "FIXTURE_ARGUMENTS": str(arguments)})
                self.assertEqual(result.returncode, 0, result.stderr)
                launched = json.loads(arguments.read_text())
                hold = launched.index("-openstream.reset.cloudRestoreHeld.v1")
                self.assertEqual(launched[hold + 1], "YES")


class VisionRunnerTests(unittest.TestCase):
    def test_default_platforms_stay_ios_and_tvos(self):
        tree = ast.parse(Path(runner.__file__).read_text())
        platforms = next(node.value for node in ast.walk(tree) if isinstance(node, ast.Assign)
                         and any(isinstance(target, ast.Name) and target.id == "platforms" for target in node.targets))
        for requested in [None, ["visionOS"], ["iOS", "visionOS"]]:
            args = type("Arguments", (), {"platform": requested})()
            self.assertEqual(eval(compile(ast.Expression(platforms), "platforms", "eval"), {"args": args}),
                             requested or ["iOS", "tvOS"])

    def test_vision_plan_uses_vision_products_and_target(self):
        self.assertEqual(runner.SCHEMES["visionOS"], "OpenStreamVisionUITests")
        self.assertEqual(runner.TARGETS["visionOS"], "OpenStreamVisionUITests")
        self.assertEqual(runner.PRODUCTS["visionOS"], "Debug-xrsimulator")
        self.assertTrue(runner.SIMS["visionOS"].startswith("46B2DEDC-"))

    def test_capture_saves_png_and_rejects_path_traversal(self):
        png = b"\x89PNG\r\n\x1a\nfixture"
        def screenshot(args, **kwargs):
            Path(args[-1]).write_bytes(png)
            return type("Result", (), {"returncode": 0})()
        with tempfile.TemporaryDirectory() as work, patch.object(runner.subprocess, "run", screenshot):
            with runner.vision_capture("fixture-simulator", Path(work)) as endpoint:
                with urlopen(endpoint + "?name=discover-filled") as response:
                    self.assertEqual(response.read(), png)
                self.assertEqual((Path(work) / "screens/discover-filled.png").read_bytes(), png)
                with self.assertRaises(HTTPError) as error:
                    urlopen(endpoint + "?name=../escape")
                self.assertEqual(error.exception.code, 400)
                error.exception.close()
                self.assertFalse((Path(work).parent / "escape.png").exists())

    def test_snapshot_accepts_an_app_without_an_app_group(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            original = work / "app"
            original.mkdir()
            with patch.object(runner, "stop"), patch.object(runner, "command"), patch.object(
                runner, "container", side_effect=[original, None]
            ):
                rows, _ = runner.snapshot("uninstalled-group", work)
            self.assertIsNone(rows[1]["original"])
            self.assertEqual(runner.hashes(Path(rows[1]["snapshot"])), {})

    def test_keychain_hashes_ignore_only_sqlite_lock_tables(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "keychain.db").write_bytes(b"credential database")
            (root / "keychain.db-wal").write_bytes(b"transactions")
            lock = root / "keychain.db-shm"
            lock.write_bytes(b"lock state")
            baseline = runner.hashes(root, skip_sqlite_shared_memory=True)
            lock.write_bytes(b"released locks")
            self.assertEqual(runner.hashes(root, skip_sqlite_shared_memory=True), baseline)
            (root / "keychain.db").write_bytes(b"changed credentials")
            self.assertNotEqual(runner.hashes(root, skip_sqlite_shared_memory=True), baseline)

    def test_keychain_snapshot_is_private_and_inside_the_job_output(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            keychains = root / "home/Library/Developer/CoreSimulator/Devices/fixture/data/Library/Keychains"
            keychains.mkdir(parents=True)
            (keychains / "keychain.db").write_bytes(b"fixture credentials")
            work = root / "output"
            work.mkdir()
            def copy(arguments):
                shutil.copytree(arguments[1], arguments[2], dirs_exist_ok=True)
            with patch.object(runner.Path, "home", return_value=root / "home"), patch.object(runner, "stop"), patch.object(
                runner, "container", return_value=None
            ), patch.object(runner, "command", side_effect=copy):
                _, hosts = runner.snapshot("fixture", work)
            backup = Path(hosts[0]["snapshot"])
            self.assertTrue(backup.is_relative_to(work))
            self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
            self.assertEqual((backup / "keychain.db").read_bytes(), b"fixture credentials")

    def test_partial_keychain_snapshot_is_removed_when_copy_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            keychains = root / "home/Library/Developer/CoreSimulator/Devices/fixture/data/Library/Keychains"
            keychains.mkdir(parents=True)
            work = root / "output"
            work.mkdir()
            backups = []
            def interrupted_copy(arguments):
                backup = Path(arguments[2])
                backups.append(backup)
                (backup / "keychain.db").write_bytes(b"partial fixture copy")
                raise OSError("copy failed")
            with patch.object(runner.Path, "home", return_value=root / "home"), patch.object(runner, "stop"), patch.object(
                runner, "container", return_value=None
            ), patch.object(runner, "command", side_effect=interrupted_copy):
                with self.assertRaisesRegex(OSError, "copy failed"):
                    runner.snapshot("fixture", work)
            self.assertTrue(backups)
            self.assertTrue(all(not backup.exists() for backup in backups))

    def test_keychain_snapshot_is_deleted_only_after_verified_restoration(self):
        for failure in [None, "verification", "shutdown", "rsync", "hash", "later_host"]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as scratch:
                work = Path(scratch)
                original = work / "original"
                backup = work / "keychain"
                original.mkdir()
                backup.mkdir(mode=0o700)
                (backup / "keychain.db").write_bytes(b"fixture credentials")
                (original / "keychain.db").write_bytes(b"changed" if failure == "verification" else b"fixture credentials")
                host = {"original": str(original), "snapshot": str(backup), "privateSnapshot": True}
                hosts = [host]
                if failure == "later_host":
                    later_backup = work / "later"
                    later_backup.mkdir()
                    (later_backup / "state").write_bytes(b"host state")
                    hosts.append({"original": str(original), "snapshot": str(later_backup)})
                def restore_command(arguments):
                    if failure == "shutdown" and "shutdown" in arguments:
                        raise OSError("shutdown failed")
                    if failure == "rsync" and arguments[0] == "rsync":
                        raise OSError("rsync failed")
                output = io.StringIO()
                with patch.object(runner, "stop"), patch.object(runner, "command", side_effect=restore_command), patch.object(
                    runner, "hashes", side_effect=OSError("hash failed") if failure == "hash" else runner.hashes
                ), patch.object(runner.sys, "stderr", output):
                    if failure:
                        with self.assertRaises((RuntimeError, OSError)):
                            runner.restore("fixture", [], hosts)
                    else:
                        runner.restore("fixture", [], hosts)
                        self.assertTrue(host["verified"])
                if failure:
                    self.assertEqual((backup / "keychain.db").read_bytes(), b"fixture credentials")
                    self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
                    self.assertIn(str(backup), output.getvalue())
                else:
                    self.assertFalse(backup.exists())
                    self.assertEqual(output.getvalue(), "")

    def test_compositor_timeout_requests_the_app_window_canvas(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            app = work / "app"
            caches = app / "Library/Caches"
            caches.mkdir(parents=True)
            png = b"\x89PNG\r\n\x1a\nwindow canvas"
            def app_capture():
                request = caches / "vision-capture-request"
                deadline = time.monotonic() + 5
                while not request.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                capture_id = request.read_text()
                (caches / ("vision-capture-" + capture_id + ".png")).write_bytes(png)
            thread = threading.Thread(target=app_capture)
            thread.start()
            with patch.object(runner.subprocess, "run", side_effect=subprocess.TimeoutExpired("simctl", 3)), patch.object(
                runner, "container", return_value=app
            ), runner.vision_capture("simulator", work) as endpoint:
                with urlopen(endpoint + "?name=discover") as response:
                    self.assertEqual(response.read(), png)
            thread.join(timeout=5)
            self.assertTrue((work / "screens/discover.capture-method").exists())
            self.assertFalse((caches / "vision-capture-request").exists())

    def test_compositor_recovers_on_the_next_capture_after_a_timeout(self):
        with tempfile.TemporaryDirectory() as scratch:
            work = Path(scratch)
            app = work / "app"
            caches = app / "Library/Caches"
            caches.mkdir(parents=True)
            canvas_png = b"\x89PNG\r\n\x1a\nwindow canvas"
            compositor_png = b"\x89PNG\r\n\x1a\ncompositor"
            def app_capture():
                request = caches / "vision-capture-request"
                deadline = time.monotonic() + 5
                while not request.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if request.exists():
                    capture_id = request.read_text()
                    (caches / ("vision-capture-" + capture_id + ".png")).write_bytes(canvas_png)
            attempts = 0
            def recovered_capture(args, **kwargs):
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise subprocess.TimeoutExpired("simctl", 3)
                Path(args[-1]).write_bytes(compositor_png)
                return subprocess.CompletedProcess(args, 0)
            thread = threading.Thread(target=app_capture)
            thread.start()
            with patch.object(runner.subprocess, "run", side_effect=recovered_capture) as capture, patch.object(
                runner, "container", return_value=app
            ), runner.vision_capture("simulator", work) as endpoint:
                with urlopen(endpoint + "?name=first") as response:
                    self.assertEqual(response.read(), canvas_png)
                with urlopen(endpoint + "?name=second") as response:
                    self.assertEqual(response.read(), compositor_png)
                self.assertEqual(capture.call_count, 2)
            thread.join(timeout=5)
            self.assertEqual((work / "screens/second.capture-method").read_text(), "simctl compositor\n")

    def test_vision_fixture_options_preserve_the_shared_server_contract(self):
        spec = importlib.util.spec_from_file_location("fixture_server", Path(__file__).with_name("serve.py"))
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        with tempfile.TemporaryDirectory() as scratch:
            for visionos in [False, True]:
                with self.subTest(visionos=visionos):
                    server = fixture.FixtureServer("127.0.0.1", 0, scratch, visionos=visionos)
                    thread = threading.Thread(target=server.serve_forever)
                    thread.start()
                    try:
                        base = "http://127.0.0.1:" + str(server.server_port) + "/jf"
                        with urlopen(base + "/Users/fixture-user/Items/jf-movie-2") as response:
                            item = json.load(response)
                        self.assertEqual("Logo" in item["ImageTags"], not visionos)
                        for kind, width, height, rgba in [("Primary", 200, 300, (70, 90, 140, 255)),
                            ("Backdrop", 320, 180, (40, 60, 100, 255)), ("Thumb", 320, 180, (40, 60, 100, 255)),
                            ("Logo", 300, 100, (255, 255, 255, 64))]:
                            def chunk(tag, data):
                                body = tag + data
                                return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
                            rows = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))
                            original = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                                        + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
                            with urlopen(base + "/Items/jf-movie-2/Images/" + kind) as response:
                                image = response.read()
                            if visionos and kind != "Logo":
                                self.assertNotEqual(image, original)
                            else:
                                self.assertEqual(image, original, kind)
                        request = Request(base + "/Items/jf-movie-2/PlaybackInfo", data=b"{}")
                        with urlopen(request) as response:
                            sources = json.load(response)["MediaSources"]
                        self.assertEqual(len(sources), 2 if visionos else 1)
                        audio = [s for s in sources[0]["MediaStreams"] if s["Type"] == "Audio"]
                        subtitles = [s for s in sources[0]["MediaStreams"] if s["Type"] == "Subtitle"]
                        self.assertEqual([s["Language"] for s in audio], ["eng", "spa"] if visionos else ["eng"])
                        self.assertEqual(subtitles[0]["Index"], 3 if visionos else 2)
                    finally:
                        server.shutdown()
                        server.server_close()
                        thread.join()


class JellyfinDownloadFixtureTests(unittest.TestCase):
    def test_downloads_are_paced_while_playback_keeps_byte_ranges(self):
        spec = importlib.util.spec_from_file_location("download_fixture", Path(__file__).with_name("serve.py"))
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        payload = bytes(range(256)) * 512
        request_finished = threading.Event()

        class CompletedHandler(fixture.FixtureHandler):
            def finish(self):
                try:
                    super().finish()
                finally:
                    request_finished.set()

        with tempfile.TemporaryDirectory() as scratch:
            clip = Path(scratch) / "download.mp4"
            clip.write_bytes(payload)
            server = fixture.FixtureServer("127.0.0.1", 0, scratch)
            server.RequestHandlerClass = CompletedHandler
            server.e2e_media = str(clip)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                base = "http://127.0.0.1:" + str(server.server_port) + "/jf"
                for path, header, paced in [
                    ("/Videos/jf-movie-2/stream.mp4", None, False),
                    ("/Videos/jf-movie-2/stream.mp4", "bytes=8192-16383", False),
                    ("/Items/jf-movie-2/Download", None, True),
                    ("/Items/jf-movie-2/Download", "bytes=8192-16383", True),
                ]:
                    with self.subTest(path=path, range=header):
                        request_finished.clear()
                        pacing_reached = threading.Event()
                        allow_download = threading.Event()

                        def hold_download(_):
                            pacing_reached.set()
                            allow_download.wait(timeout=5)

                        request = Request(base + path, headers={"Range": header} if header else {})
                        try:
                            with patch.object(fixture.time, "sleep", side_effect=hold_download), urlopen(request) as response:
                                first = response.read(1)
                                if paced:
                                    self.assertTrue(pacing_reached.wait(1), "Download finished without cancellable pacing")
                                allow_download.set()
                                expected = payload[8192:16384] if header else payload
                                self.assertEqual(first + response.read(), expected)
                                # Content-Length can finish the read before the final chunk's sleep.
                                self.assertTrue(request_finished.wait(1), "Fixture response did not finish")
                                if not paced:
                                    self.assertFalse(pacing_reached.is_set(), "Playback was throttled like a download")
                                self.assertEqual(response.status, 206 if header else 200)
                        finally:
                            allow_download.set()
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


class DevicePassTests(unittest.TestCase):
    def helpers(self, work):
        script = Path(__file__).resolve().parents[2] / "scripts/vp-device-pass.sh"
        source = script.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        definitions = [node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef)
                       and node.name in {"wait_for_owner", "collect_trace"}]
        namespace = {"Path": Path, "work": work, "device": "fixture-device", "bundle": "fixture.bundle",
                     "tempfile": tempfile, "subprocess": subprocess, "time": time, "re": re, "os": os, "sys": sys}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), str(script), "exec"), namespace)
        return namespace

    def test_noninteractive_pass_does_not_require_a_tty(self):
        helpers = self.helpers(Path("/unused"))
        with patch.object(sys.stdout, "isatty", return_value=False), patch("builtins.open", side_effect=AssertionError):
            helpers["wait_for_owner"]()

    def test_missing_controlling_terminal_does_not_abort(self):
        helpers = self.helpers(Path("/unused"))
        with patch.object(sys.stdout, "isatty", return_value=True), patch("builtins.open", side_effect=OSError):
            helpers["wait_for_owner"]()

    def test_failed_trace_copy_preserves_the_primary_error(self):
        with tempfile.TemporaryDirectory() as work:
            helpers = self.helpers(Path(work))
            with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 9)):
                with self.assertRaisesRegex(RuntimeError, "original device failure"):
                    try:
                        raise RuntimeError("original device failure")
                    finally:
                        self.assertFalse(helpers["collect_trace"]())

    def test_trace_is_redacted_and_private(self):
        with tempfile.TemporaryDirectory() as work:
            helpers = self.helpers(Path(work))
            def copied(arguments, **kwargs):
                Path(arguments[-1]).write_text("https://fixture.example/movie?token=fixture-secret username=fixture-user\n")
                return subprocess.CompletedProcess(arguments, 0)
            with patch.object(subprocess, "run", side_effect=copied):
                self.assertTrue(helpers["collect_trace"]())
            trace = next(Path(work).glob("owner-trace-*.log"))
            self.assertNotIn("fixture-secret", trace.read_text())
            self.assertNotIn("fixture-user", trace.read_text())
            self.assertEqual(trace.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
