#!/usr/bin/env python3
"""Run the checked-in E2E plans on existing build-Mac simulators, restoring data.

From native/apple: scripts/mini.sh 'python3 Tests/Fixtures/run-e2e.py'
Optional --platform iOS|tvOS|visionOS and repeatable --only Class/test selectors.
No simulators are created. --output selects the job's results and snapshots.
"""
import argparse
from contextlib import contextmanager, nullcontext
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = "com.orgista.openstream"
GROUP = "group.com.orgista.openstream"
SIMS = {"iOS": os.environ.get("OPENSTREAM_E2E_IOS_SIM", "2E61439B-4B06-48BA-96F1-8CB92A54699D"),
        "tvOS": "F2107E8F-87F4-4685-9C91-84B56D78EC6F",
        "visionOS": "46B2DEDC-DDA8-4D7E-8202-C98E7D03148B"}
SCHEMES = {"iOS": "OpenStreamiOSUITests", "tvOS": "OpenStreamTVUITests", "visionOS": "OpenStreamVisionUITests"}
TARGETS = dict(SCHEMES)
PRODUCTS = {"iOS": "Debug-iphonesimulator", "tvOS": "Debug-appletvsimulator", "visionOS": "Debug-xrsimulator"}
DD = Path(os.environ.get("OPENSTREAM_E2E_DD", Path.home() / "Developer/sim-dd-internal"))
ACTIVE_TEST_PROCESS = None
CANCEL_REQUESTED = False


def request_cancel(signum, frame):
    # nohup/background shells can inherit ignored SIGINT. Install an explicit
    # handler and let the active child finish cancellation before restoration.
    global CANCEL_REQUESTED
    CANCEL_REQUESTED = True
    if ACTIVE_TEST_PROCESS is not None and ACTIVE_TEST_PROCESS.poll() is None:
        ACTIVE_TEST_PROCESS.send_signal(signal.SIGINT)


def command(args, **kw):
    return subprocess.run(args, check=True, **kw)


def read_json(args):
    return json.loads(subprocess.check_output(args, text=True))


def container(sim, kind, optional=False):
    # simctl can retain a deleted app-group path after a UI-test install.
    area = "Data/Application" if kind == "data" else "Shared/AppGroup"
    identifier = BUNDLE if kind == "data" else kind
    base = Path.home() / "Library/Developer/CoreSimulator/Devices" / sim / "data/Containers" / area
    candidates = []
    for metadata in base.glob("*/.com.apple.mobile_container_manager.metadata.plist"):
        try:
            if plistlib.loads(metadata.read_bytes()).get("MCMMetadataIdentifier") == identifier:
                candidates.append(metadata.parent)
        except (OSError, plistlib.InvalidFileException):
            pass
    if not candidates:
        if optional:
            return None
        raise RuntimeError("No live container for " + kind)
    def activity(path):
        return max((p.stat().st_mtime for p in path.rglob("*") if p.is_file()
                    and p.name != ".com.apple.mobile_container_manager.metadata.plist"), default=path.stat().st_mtime)
    return max(candidates, key=activity)


def hashes(path, skip_sqlite_shared_memory=False):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob("*") if p.is_file() and p.name != ".com.apple.mobile_container_manager.metadata.plist"
            and not (skip_sqlite_shared_memory and p.name.endswith("-shm"))}


def stop(sim):
    subprocess.run(["xcrun", "simctl", "terminate", sim, BUNDLE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cloud_held_arguments(arguments):
    arguments = list(arguments)
    hold = "-openstream.reset.cloudRestoreHeld.v1"
    while hold in arguments:
        index = arguments.index(hold)
        del arguments[index:index + 2]
    return arguments + [hold, "YES"]


def snapshot(sim, work):
    stop(sim)
    rows = []
    for kind in ["data", GROUP]:
        original = container(sim, kind, optional=kind == GROUP)
        backup = work / kind
        if original:
            command(["ditto", str(original), str(backup)])
        else:
            backup.mkdir()
        rows.append({"kind": kind, "original": str(original) if original else None, "snapshot": str(backup)})
    # Widget placement, TV icon placement, and staged Messages drafts are host state.
    device = Path.home() / "Library/Developer/CoreSimulator/Devices" / sim / "data"
    host_paths = [device / "Library/SpringBoard", device / "Library/HeadBoard", device / "Library/SMS",
                  device / "Library/Keychains"]
    hosts = []
    try:
        for index, path in enumerate(host_paths):
            if path.exists():
                backup = work / f"host-{index}"
                hosts.append({"original": str(path), "snapshot": str(backup)})
                if path.name == "Keychains":
                    backup.mkdir(mode=0o700)
                    hosts[-1]["privateSnapshot"] = True
                    # SQLite rewrites its lock table as securityd releases the mapping.
                    hosts[-1]["excludedVolatileFiles"] = [p.name for p in path.glob("*-shm")]
                command(["ditto", str(path), str(backup)])
                if path.name == "Keychains":
                    backup.chmod(0o700)
    except BaseException:
        for host in hosts:
            if host.get("privateSnapshot"):
                shutil.rmtree(host["snapshot"])
        raise
    return rows, hosts


def restore(sim, rows, hosts):
    restore_verified = False
    try:
        stop(sim)
        for row in rows:
            current = container(sim, row["kind"], optional=row["kind"] == GROUP)
            row["restored"] = str(current) if current else None
        command(["xcrun", "simctl", "shutdown", sim])
        for row in rows + hosts:
            destinations = {row["original"], row.get("restored", row["original"])}
            for destination in destinations:
                if destination is None:
                    continue
                command(["rsync", "-a", "--delete", "--exclude=.com.apple.mobile_container_manager.metadata.plist",
                         row["snapshot"] + "/", destination + "/"])
            current = row.get("restored", row["original"])
            volatile = bool(row.get("excludedVolatileFiles"))
            row["verified"] = hashes(Path(row["snapshot"]), volatile) == (hashes(Path(current), volatile) if current else {})
            if not row["verified"]:
                raise RuntimeError("Simulator restore verification failed: " + row.get("kind", "host"))
        restore_verified = True
    finally:
        for host in hosts:
            if host.get("privateSnapshot"):
                if restore_verified and host.get("verified"):
                    shutil.rmtree(host["snapshot"])
                else:
                    print("Keychains restore failed; retained private snapshot: " + host["snapshot"],
                          file=sys.stderr, flush=True)


def extract_results(bundle):
    tree = read_json(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)])
    tests = []
    def walk(node):
        if node.get("nodeType") == "Test Case":
            tests.append({"identifier": node.get("nodeIdentifier"), "name": node.get("name"),
                          "status": node.get("result"), "duration": node.get("duration"),
                          "details": node.get("details", [])})
        for child in node.get("children", []):
            walk(child)
    for node in tree.get("testNodes", []):
        walk(node)
    summary = read_json(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)])
    return {"summary": summary, "tests": tests}


@contextmanager
def vision_capture(simulator, work):
    screens = work / "screens"
    screens.mkdir()
    class Capture(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            request = urlsplit(self.path)
            name = parse_qs(request.query).get("name", [""])[0]
            if request.path != "/capture" or not re.fullmatch(r"[A-Za-z0-9_.-]{1,160}", name):
                self.send_error(400, "Invalid capture name")
                return
            path = screens / (name + ".png")
            try:
                result = subprocess.run(["xcrun", "simctl", "io", simulator, "screenshot", "--display=primary", str(path)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                native_available = result.returncode == 0
            except subprocess.TimeoutExpired:
                native_available = False
            method = "simctl compositor"
            if not native_available:
                caches = container(simulator, "data") / "Library/Caches"
                capture_id = str(uuid.uuid4()).upper()
                response = caches / ("vision-capture-" + capture_id + ".png")
                request_file = caches / "vision-capture-request"
                request_file.write_text(capture_id)
                deadline = time.monotonic() + 15
                while not response.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                request_file.unlink(missing_ok=True)
                if not response.exists():
                    self.send_error(504, "Neither compositor nor window capture responded")
                    return
                shutil.move(str(response), path)
                method = "UIKit window canvas; simctl compositor unavailable"
            if not path.exists():
                self.send_error(503, "Simulator capture failed")
                return
            data = path.read_bytes()
            (screens / (name + ".capture-method")).write_text(method + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Capture)
    thread = threading.Thread(target=server.serve_forever, name="vision-e2e-capture")
    thread.start()
    try:
        yield "http://127.0.0.1:" + str(server.server_port) + "/capture"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def run_platform(platform, work, only, media_environment=None, compile_files=(), media_metadata=None,
                 simulator=None, derived_data=None, fixture_clip=None):
    global ACTIVE_TEST_PROCESS
    sim = simulator or SIMS[platform]
    derived_data = derived_data or DD
    devices = read_json(["xcrun", "simctl", "list", "devices", "--json"])
    booted = [d["udid"] for group in devices["devices"].values() for d in group if d["state"] == "Booted"]
    if booted:
        raise RuntimeError("Another simulator is booted; stop before running E2E")
    command(["xcrun", "simctl", "boot", sim])
    command(["xcrun", "simctl", "bootstatus", sim, "-b"], stdout=subprocess.DEVNULL)
    try:
        rows, hosts = snapshot(sim, work)
    except Exception:
        command(["xcrun", "simctl", "shutdown", sim])
        raise
    result = {"platform": platform, "simulator": sim, "scratch": str(work), "muteAudio": True}
    if media_metadata:
        result["captionFixtureCopies"] = media_metadata
    try:
        buildlog = work / "build.log"
        with buildlog.open("w") as log:
            # Vision's UI target depends on its app. The older suites need an explicit app build.
            if platform != "visionOS":
                command(["xcodebuild", "-project", "OpenStreamApps.xcodeproj", "-scheme", "OpenStream " + platform,
                         "-destination", "id=" + sim, "-derivedDataPath", str(derived_data), "build"],
                        cwd=ROOT / "Apps", stdout=log, stderr=subprocess.STDOUT)
            command(["xcodebuild", "-project", "OpenStreamApps.xcodeproj", "-scheme", SCHEMES[platform],
                     "-testPlan", "E2E-" + platform, "-destination", "id=" + sim,
                     "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO", "build-for-testing"],
                    cwd=ROOT / "Apps", stdout=log, stderr=subprocess.STDOUT)
        if CANCEL_REQUESTED:
            raise RuntimeError("E2E cancelled before test execution")
        result["buildLog"] = str(buildlog)
        compiled = buildlog.read_text(errors="replace").splitlines()
        result["compileEvidence"] = {name: sum("SwiftCompile normal arm64 Compiling" in line and name in line
                                               for line in compiled) for name in compile_files}
        products = derived_data / "Build/Products"
        app_path = products / PRODUCTS[platform] / "OpenStream.app"
        if not app_path.exists():
            apps = list((products / PRODUCTS[platform]).glob("*.app"))
            app_path = next(p for p in apps if "Runner" not in p.name)
        command(["xcrun", "simctl", "install", sim, str(app_path)])
        stub_path = work / "stubs"
        shutil.copytree(ROOT / "Apps/TestPlans/Stubs", stub_path)
        source_file = stub_path / "e2e-sources.json"
        if platform == "visionOS":
            sources = json.loads(source_file.read_text())
            sources["settings"] = {"tmdbAPIKey": "fixture"}
            source_file.write_text(json.dumps(sources))
            # Vision's crawl needs a scanned file; shared suites retain their empty Library.
            if fixture_clip:
                shutil.copy2(fixture_clip, stub_path / "library/Stub Movie One (2024).mp4")
        fixture_spec = importlib.util.spec_from_file_location("fixture_artwork", ROOT / "Tests/Fixtures/serve.py")
        fixture_artwork = importlib.util.module_from_spec(fixture_spec)
        fixture_spec.loader.exec_module(fixture_artwork)
        artwork = fixture_artwork.VISION_IMAGES if platform == "visionOS" else fixture_artwork.IMAGES
        for item_id in fixture_artwork.ITEMS:
            images = stub_path / "127.0.0.1/jf/Items" / item_id / "Images"
            images.mkdir(parents=True, exist_ok=True)
            for kind, data in artwork.items():
                (images / (kind + ".json")).write_bytes(data)
        for width in ["w92", "w154", "w185", "w300", "w342", "w500", "w780", "w1280", "original"]:
            images = stub_path / "image.tmdb.org/t/p" / width
            images.mkdir(parents=True, exist_ok=True)
            for name, kind in [("fixture-poster.png", "Primary"), ("fixture-backdrop.png", "Backdrop")]:
                (images / (name + ".json")).write_bytes(artwork[kind])
        stub = str(stub_path)
        with (work / "seed.log").open("w") as log:
            command(["bash", str(ROOT / "scripts/seed-sim.sh"), sim, "--reset"], stdout=log, stderr=subprocess.STDOUT,
                    env={**os.environ, "DEV_SOURCES": str(source_file), "OPENSTREAM_STUB_DIR": stub,
                         "OPENSTREAM_STUB_MEDIA_BASE": "http://127.0.0.1:8767"})
        stop(sim)
        # Expand generated build placeholders only; the checked-in plan remains the source of settings.
        generated = max(products.glob("*E2E-" + platform + "*.xctestrun"), key=lambda p: p.stat().st_mtime)
        config = plistlib.loads(generated.read_bytes())
        def expand(value):
            if isinstance(value, str):
                return value.replace("__TESTROOT__", str(products))
            if isinstance(value, list):
                return [expand(x) for x in value]
            if isinstance(value, dict):
                return {k: expand(v) for k, v in value.items()}
            return value
        config = expand(config)
        for configuration in config["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                target["CommandLineArguments"] = cloud_held_arguments(target.get("CommandLineArguments", []))
                target.setdefault("EnvironmentVariables", {})["OPENSTREAM_STUB_DIR"] = stub
                target["EnvironmentVariables"].update(media_environment or {})
        test_run = work / "plan.xctestrun"
        test_run.write_bytes(plistlib.dumps(config))
        bundle = work / "tests.xcresult"
        args = ["xcodebuild", "-xctestrun", str(test_run), "-destination", "id=" + sim,
                "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle)]
        args += ["-only-testing:" + TARGETS[platform] + "/" + t for t in only]
        with (vision_capture(sim, work) if platform == "visionOS" else nullcontext()) as capture_url, (work / "tests.log").open("w") as log:
            if platform == "visionOS":
                for configuration in config["TestConfigurations"]:
                    for target in configuration["TestTargets"]:
                        target["EnvironmentVariables"].update({"OPENSTREAM_VISION_CAPTURE_URL": capture_url,
                                                               "OPENSTREAM_FIXTURE_BASE": "http://127.0.0.1:8767"})
                test_run.write_bytes(plistlib.dumps(config))
            with subprocess.Popen(args + ["test-without-building"], stdout=log, stderr=subprocess.STDOUT) as proc:
                ACTIVE_TEST_PROCESS = proc
                try:
                    trace_path = container(sim, "data") / "Library/Caches/openstream-trace.log"
                    prior_trace = None
                    trailer_trace = []
                    trailer_events = set()
                    diagnostic = work / "players-launch-health.txt"
                    while True:
                        finished = proc.poll() is not None
                        test_log = (work / "tests.log").read_text(errors="replace")
                        starts = re.findall(r"Test Case '-\[.*? (test\w+)\]' started", test_log)
                        if starts and starts[-1] in {"testMediaServerHeroTrailerReachesPlaying", "testServerHostedTrailerReachesPlaying"} and trace_path.exists():
                            for line in trace_path.read_text(errors="replace").splitlines():
                                if not any(mark in line for mark in ("discover recommendations", "trailer iframe state=", "trailer web load", "title trailer", "server trailer start", "server trailer failed")):
                                    continue
                                event = (starts[-1], line)
                                if event not in trailer_events:
                                    trailer_events.add(event)
                                    trailer_trace.append({"test": starts[-1], "event": line})
                        if starts and starts[-1] in {"testCrawlPlayers", "testIPadDirectPlaybackSurvivesRotation",
                                                    "testLiveReconnectShowsOneLoadingIndicator"} and trace_path.exists():
                            raw = trace_path.read_text(errors="replace")
                            if raw != prior_trace:
                                prior_trace = raw
                                # Keep lifecycle/timing evidence without source addresses or credentials.
                                lines = raw.splitlines()
                                cleaned = re.sub(r"[a-zA-Z][a-zA-Z0-9+.-]*://\S+", "<source URL>", "\n".join(lines))
                                cleaned = re.sub(r"(?i)(password|token|username|authorization)[=: ]+\S+", r"\1=<redacted>", cleaned)
                                with diagnostic.open("a") as capture:
                                    capture.write(f"\nSnapshot {time.time():.3f}\n{cleaned}\n")
                        if finished:
                            break
                        time.sleep(2)
                    result["exitCode"] = proc.returncode
                    result["heroTrailerTrace"] = trailer_trace
                    if diagnostic.exists():
                        result["playersLaunchHealth"] = str(diagnostic)
                finally:
                    ACTIVE_TEST_PROCESS = None
        result["resultBundle"] = str(bundle)
        result.update(extract_results(bundle))
        matrix_tokens = ("CaptionsOffAndOnStayInFrame", "DVDMenu", "HTTPDisc", "SMB")
        result["countsByScope"] = {}
        for scope in ["baseline", "newMatrix"]:
            rows_for_scope = [t for t in result.get("tests", []) if
                              any(token in t.get("identifier", "") for token in matrix_tokens) == (scope == "newMatrix")]
            result["countsByScope"][scope] = {status: sum(t.get("status") == status for t in rows_for_scope)
                                              for status in ["Passed", "Failed", "Skipped"]}
        if media_environment or platform == "visionOS":
            attachments = work / "attachments"
            command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                     "--output-path", str(attachments)], stdout=subprocess.DEVNULL)
            result["attachments"] = str(attachments)
            if platform == "visionOS":
                manifest = json.loads((attachments / "manifest.json").read_text())
                result["accessibilityAudits"] = [
                    {"name": item["suggestedHumanReadableName"], "findings": int(match.group(1))}
                    for test in manifest for item in test["attachments"]
                    if (match := re.search(r"-audit-(\d+)", item["suggestedHumanReadableName"]))]
                result["systemAccessibilityFindings"] = [
                    {"name": item["suggestedHumanReadableName"], "findings": int(match.group(1))}
                    for test in manifest for item in test["attachments"]
                    if (match := re.search(r"-system-finding-(\d+)", item["suggestedHumanReadableName"]))]
        trace = container(sim, "data") / "Library/Caches/openstream-trace.log"
        if trace.exists():
            lines = trace.read_text(errors="replace").splitlines()
            result["libraryFixtureTrace"] = [line for line in lines
                                             if "library scanned" in line or "library scans done" in line
                                             or "library grouped" in line]
            result["libraryMatchTrace"] = [line for line in lines
                                           if "network stub:" in line or "library cached metadata" in line
                                           or "library eager" in line or "Library match" in line][-40:]
            result["discFixtureTrace"] = [line for line in lines
                                           if "title page disc:" in line or "disc start=" in line
                                           or "dvd menu" in line.lower()]
            result["captionSelectionTrace"] = [line for line in lines
                                                if "subtitle select: track=" in line
                                                or "subtitle mirror:" in line]
            result["liveTuneTrace"] = [line for line in lines
                                       if any(mark in line for mark in ("live surf", "live zap", "live first picture",
                                                                        "live spinner shown", "live watched"))]
            result["serverTrailerTrace"] = [line for line in lines if "server trailer" in line][-200:]
            result["fixturePlaybackHealth"] = [line for line in lines
                                               if "first frame, route=" in line or "failure timed out after" in line]
    except Exception as error:
        result["error"] = str(error)
        result["exitCode"] = 1
    finally:
        restore_completed = False
        try:
            restore(sim, rows, hosts)
            restore_completed = True
        except Exception as error:
            result["cleanupError"] = str(error)
            result["exitCode"] = 1
            raise
        finally:
            result["cleanup"] = {"appAndGroup": rows, "hostData": hosts, "simulatorShutdown": restore_completed}
            (work / ("fixtures-" + platform.lower() + ".json")).write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"platform": platform, "exitCode": result["exitCode"], "results": str(work)}), flush=True)
    return result["exitCode"]


@contextmanager
def local_engine_override(fork):
    """Use the uncommitted engine only in the Mini's disposable build mirror."""
    if not fork:
        yield
        return
    if (Path.home() / "Developer/openstream-build").resolve() not in ROOT.resolve().parents:
        raise RuntimeError("Engine override is restricted to the build Mac's mirror")
    engine = Path(fork).resolve()
    if not (engine / "Package.swift").is_file():
        raise RuntimeError("Engine fork Package.swift is missing")
    manifest = ROOT / "Package.swift"
    paths = [manifest, ROOT / "Package.resolved",
             ROOT / "Apps/OpenStreamApps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    originals = {path: path.read_bytes() if path.exists() else None for path in paths}
    pattern = r'\.package\(url: "https://github.com/orgista/AetherEngine", revision: "[a-f0-9]+"\)'
    replacement = '.package(name: "AetherEngine", path: ' + json.dumps(str(engine)) + ')'
    updated, count = re.subn(pattern, lambda _: replacement, manifest.read_text())
    if count != 1:
        raise RuntimeError("Expected exactly one pinned AetherEngine dependency")
    try:
        manifest.write_text(updated)
        yield
    finally:
        for path, original in originals.items():
            if original is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(original)
        if any((path.read_bytes() if path.exists() else None) != original for path, original in originals.items()):
            raise RuntimeError("Engine override restoration verification failed")


def isolated_subtitle_copy(source, output, index):
    """Copy encoded streams, then prove subtitle bytes and cue timestamps match."""
    command(["ffmpeg", "-v", "error", "-copyts", "-i", str(source),
             "-map", "0:v", "-map", "0:a?", "-map", "0:" + str(index), "-map", "0:t?",
             "-c", "copy", "-avoid_negative_ts", "disabled", str(output)])
    streams = read_json(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(output)])["streams"]
    subtitles = [s for s in streams if s["codec_type"] == "subtitle"]
    if len(subtitles) != 1:
        raise RuntimeError("Isolated caption copy must contain exactly one subtitle track")
    output_index = subtitles[0]["index"]
    def packets(path, track):
        return read_json(["ffprobe", "-v", "error", "-select_streams", str(track), "-show_packets",
                          "-show_data_hash", "sha256", "-show_entries", "packet=pts_time,data_hash",
                          "-of", "json", str(path)]).get("packets", [])
    original_packets = packets(source, index)
    copied_packets = packets(output, output_index)
    if not original_packets or original_packets != copied_packets:
        raise RuntimeError("Subtitle stream-copy changed encoded payloads or cue timestamps")
    return output_index, {"source": str(source), "originalTrack": index, "copy": str(output),
                          "copiedTrack": output_index, "codec": subtitles[0]["codec_name"],
                          "subtitlePacketCount": len(original_packets), "payloadsAndTimestampsIdentical": True,
                          "encoding": "stream copy; video, all audio and attachments retained"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=SIMS, action="append")
    parser.add_argument("--simulator", help="Existing simulator UDID; requires exactly one --platform")
    parser.add_argument("--derived-data", type=Path, default=DD, help="Internal simulator DerivedData directory")
    parser.add_argument("--repeat", type=int, default=1, help="Independent runs, restoring simulator data after each")
    parser.add_argument("--engine-fork", help="Build-Mac-only temporary engine dependency override")
    parser.add_argument("--engine-corpus", type=Path,
                        default=Path(os.environ.get("OPENSTREAM_ENGINE_CORPUS", "corpus")),
                        help="Local engine corpus directory (or OPENSTREAM_ENGINE_CORPUS)")
    parser.add_argument("--live-fixtures", action="store_true", help="Sliding HLS and a silent loopback origin")
    parser.add_argument("--matrix", action="store_true", help="Run all ISO/caption cases and affected iOS baseline retries")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--only-ios", action="append", default=[])
    parser.add_argument("--only-tvos", action="append", default=[])
    parser.add_argument("--only-visionos", action="append", default=[])
    parser.add_argument("--output", type=Path, help="New job results directory")
    parser.add_argument("--compile-file", action="append", default=[], help="Record recompilation counts by Swift filename")
    parser.add_argument("--iso-fixtures", action="store_true", help="Include the local engine DVD corpus")
    parser.add_argument("--remote-http-fixtures", action="store_true", help="Read-only SSH byte-range proxy; does not verify SMB transport")
    parser.add_argument("--iso-repro", action="store_true", help="Capture pre-fix disc playback without requiring navigation")
    parser.add_argument("--caption-fixtures", action="store_true", help="Include the local bitmap caption corpus")
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")
    if args.simulator and (not args.platform or len(args.platform) != 1):
        parser.error("--simulator requires exactly one --platform")
    if args.matrix and args.platform and "visionOS" in args.platform:
        parser.error("--matrix requires --platform iOS and/or tvOS")
    if args.derived_data.resolve().is_relative_to(Path("/Volumes")):
        parser.error("Simulator DerivedData must be on the internal disk")
    disk = os.statvfs(Path.home())
    if disk.f_bavail * disk.f_frsize < 15 * 1024**3:
        parser.error("Internal disk must have at least 15 GB free")
    platforms = args.platform or ["iOS", "tvOS"]
    signal.signal(signal.SIGINT, request_cancel)
    with local_engine_override(args.engine_fork):
        # Keep a caller-chosen Xcode (the Duo needs the 27.2 SDK to get its real layout).
        os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        work_root = os.environ.get("OPENSTREAM_E2E_WORK_ROOT")
        if not args.output and not (work_root and Path(work_root).is_dir()):
            parser.error("Pass --output, or set OPENSTREAM_E2E_WORK_ROOT to an existing work folder")
        work = args.output or Path(tempfile.mkdtemp(prefix="e2e-fixtures-", dir=work_root))
        if args.output:
            work.mkdir(parents=True, mode=0o700)
        print("E2E scratch: " + str(work), flush=True)
        media_environment = {}
        caption_media = {}
        caption_metadata = []
        if os.environ.get("OPENSTREAM_REMOTE_ISO_FIXTURES"):
            media_environment["OPENSTREAM_REMOTE_ISO_FIXTURES"] = os.environ["OPENSTREAM_REMOTE_ISO_FIXTURES"]
        if args.remote_http_fixtures:
            names = ["matilda-published", "goonies-published", "matilda-staged", "goonies-staged",
                     "avatar-staged", "avatar2-staged", "john-wick-staged", "tron-staged",
                     "john-wick-published", "tron-published", "wild-robot-staged"]
            media_environment["OPENSTREAM_HTTP_ISO_FIXTURES"] = json.dumps({
                name: "http://127.0.0.1:8887/iso-" + name + ".iso" for name in names})
        if args.iso_fixtures:
            discs = {}
            for name in ["menu-test", "menu-features"]:
                source = args.engine_corpus / "dvd" / (name + ".iso")
                if not source.is_file():
                    raise RuntimeError("Missing ISO corpus: " + str(source))
                folder = work / "discs" / name
                folder.mkdir(parents=True)
                shutil.copy2(source, folder / source.name)
                discs[name] = str(folder)
            media_environment["OPENSTREAM_ISO_FIXTURES"] = json.dumps(discs)
            if args.iso_repro:
                media_environment["OPENSTREAM_ISO_REPRO"] = "1"
        if args.caption_fixtures:
            corpus = args.engine_corpus / "subs"
            cases = {}
            for name, track in [("g-subs-pgs.mkv", 12), ("ff-pgs-dts.m2ts", 5),
                                ("ff-vobsub-reddwarf.mkv", 3), ("ff-largeres-vobsub.mkv", 7),
                                ("ff-multisub.mkv", 3), ("g-subs-srt-ass.mkv", 2)]:
                source = corpus / name
                if not source.is_file():
                    raise RuntimeError("Missing caption corpus: " + str(source))
                if name == "g-subs-pgs.mkv":
                    output = work / name
                    track, metadata = isolated_subtitle_copy(source, output, track)
                    caption_metadata.append(metadata)
                    source = output
                route = "/caption-corpus/" + name
                caption_media[route] = str(source)
                cases[name] = {"url": "http://127.0.0.1:8767" + route, "track": track,
                               "kind": "text" if name in ["ff-multisub.mkv", "g-subs-srt-ass.mkv"] else "bitmap"}
            source = corpus / "g-subs-srt-ass.mkv"
            output = work / "g-subs-srt-ass-ass.mkv"
            track, metadata = isolated_subtitle_copy(source, output, 3)
            caption_metadata.append(metadata)
            route = "/caption-corpus/g-subs-srt-ass-ass.mkv"
            caption_media[route] = str(output)
            cases[output.name] = {"url": "http://127.0.0.1:8767" + route, "track": track, "kind": "text"}
            labels = {"g-subs-pgs.mkv": "English", "ff-vobsub-reddwarf.mkv": "Czech",
                      "ff-largeres-vobsub.mkv": "English", "ff-multisub.mkv": "English",
                      "g-subs-srt-ass.mkv": "English", "g-subs-srt-ass-ass.mkv": "French"}
            for name, case in cases.items():
                case["label"] = labels.get(name, "")
                if name == "ff-pgs-dts.m2ts":
                    case["label"] = "Subtitles 1"
                if case["kind"] == "text":
                    path = Path(caption_media[urlsplit(case["url"]).path])
                    subtitle = command(["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:" + str(case["track"]),
                                        "-f", "srt", "-"], capture_output=True).stdout
                    if isinstance(subtitle, bytes):
                        subtitle = subtitle.decode("utf-8", errors="replace")
                    blocks = subtitle.strip().split("\n\n")
                    case["expectedCue"] = re.sub(r"<[^>]+>", "", " ".join(blocks[0].splitlines()[2:]))
                    def cue_seconds(value):
                        hours, minutes, seconds = value.replace(",", ".").split(":")
                        return int(hours) * 3600 + int(minutes) * 60 + float(seconds)
                    first_times = blocks[0].splitlines()[1].split(" --> ")
                    case["cueStart"] = cue_seconds(first_times[0])
                    case["cueEnd"] = cue_seconds(first_times[1].split()[0])
                    probe = read_json(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                                       "-of", "json", str(path)])
                    case["duration"] = float(probe["format"]["duration"])
            if args.remote_http_fixtures:
                cases["Matilda"] = {"url": "http://127.0.0.1:8887/Matilda.mkv", "track": 4,
                                    "kind": "bitmap", "label": "English", "transport": "read-only SSH byte-range HTTP; SMB unverified"}
            # Private SMB URL and probed stream index come from the owner fixture environment.
            if os.environ.get("OPENSTREAM_MATILDA_URL") and os.environ.get("OPENSTREAM_MATILDA_SUBTITLE_TRACK"):
                cases["Matilda"] = {"url": os.environ["OPENSTREAM_MATILDA_URL"],
                                    "track": int(os.environ["OPENSTREAM_MATILDA_SUBTITLE_TRACK"])}
            if os.environ.get("OPENSTREAM_MATILDA_SMB"):
                cases["Matilda"] = {"librarySMB": os.environ["OPENSTREAM_MATILDA_SMB"], "kind": "bitmap", "label": "English"}
                if os.environ.get("OPENSTREAM_MATILDA_SUBTITLE_TRACK"):
                    cases["Matilda"]["track"] = int(os.environ["OPENSTREAM_MATILDA_SUBTITLE_TRACK"])
            media_environment["OPENSTREAM_BITMAP_CAPTION_FIXTURES"] = json.dumps(cases)
        crawl_subtitles = work / "crawl.srt"
        crawl_subtitles.write_text("1\n00:00:01,000 --> 00:29:59,000\nOpenStream fixture caption\n")
        clips = {}
        for visionos in sorted({platform == "visionOS" for platform in platforms}):
            clip = work / ("e2e-vision.mp4" if visionos else "e2e-long.mp4")
            generate = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=256x144:rate=1",
                        "-i", str(crawl_subtitles)]
            if visionos:
                generate += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                             "-map", "0:v", "-map", "2:a", "-map", "2:a", "-map", "1:s",
                             "-c:a", "aac", "-b:a", "32k", "-metadata:s:a:0", "language=eng",
                             "-metadata:s:a:1", "language=spa"]
            else:
                generate += ["-map", "0:v", "-map", "1:s"]
            command(generate + ["-t", "1800", "-c:v", "libx264", "-c:s", "mov_text",
                                "-metadata:s:s:0", "language=eng", "-disposition:s:0", "0",
                                "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(clip)])
            clips[visionos] = clip
        live_clip = work / "e2e-live.ts"
        command(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=256x144:rate=25",
                 "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
                 "-t", "1800", "-c:v", "libx264", "-preset", "ultrafast", "-g", "50",
                 "-b:v", "1500k", "-minrate", "1500k", "-maxrate", "1500k", "-bufsize", "3000k",
                 "-x264-params", "nal-hrd=cbr:force-cfr=1", "-c:a", "aac",
                 "-f", "mpegts", str(live_clip)])
        spec = importlib.util.spec_from_file_location("fixture_server", ROOT / "Tests/Fixtures/serve.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        server = module.FixtureServer("127.0.0.1", 8767, str(ROOT / "Tests/Fixtures/out"))
        class CaptionHandler(module.FixtureHandler):
            def do_GET(self):
                path = caption_media.get(urlsplit(self.path).path)
                if path:
                    self._serve_file(path, allow_range=True)
                elif urlsplit(self.path).path == "/media/e2e-long.mp4" and not self.headers.get("Range"):
                    # Download clients issue a full GET; keep it cancellable.
                    # Ranged playback reads retain their ordinary throughput.
                    self._serve_file(self.server.e2e_media, allow_range=True, throttle=True)
                else:
                    super().do_GET()
        server.RequestHandlerClass = CaptionHandler
        server.e2e_live = str(live_clip)
        # Keep a continuous timeline at real-time pacing: the short engine fixture
        # loops its timestamps and its default stress throughput outruns live playback.
        server.live_target_bps = live_clip.stat().st_size / 1800
        server.live_chunk_size = 64 * 1024
        # A short initial burst supplies the decoder probe before the app's
        # startup deadline; afterwards the continuous TS keeps real-time pacing.
        server.live_bootstrap_bytes = 3 * 1024 * 1024
        live_context = nullcontext({})
        if args.live_fixtures:
            from live_hls import sliding_origin
            live_context = sliding_origin(server, CaptionHandler, work)
        with live_context as live_environment:
            media_environment.update(live_environment)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            codes = []
            try:
                for platform in platforms:
                    clip = clips[platform == "visionOS"]
                    server.visionos = platform == "visionOS"
                    server.e2e_media = str(clip)
                    selectors = args.only + {"iOS": args.only_ios, "tvOS": args.only_tvos,
                                            "visionOS": args.only_visionos}[platform]
                    if args.matrix:
                        class_name = "AppleiOSUITests" if platform == "iOS" else "AppleTVFocusUITests"
                        test_source = ROOT / "Apps" / ("OpenStreamiOSUITests" if platform == "iOS" else "OpenStreamTVUITests") / (class_name + ".swift")
                        methods = re.findall(r"func (test\w+)\(", test_source.read_text())
                        selectors = [class_name + "/" + method for method in methods if
                                     method.startswith(("testDVDMenu", "testHTTPDisc")) or "CaptionsOffAndOnStayInFrame" in method]
                        if platform == "iOS":
                            selectors += [class_name + "/testCrawlDetailAndEpisodes", class_name + "/testCrawlPlayers"]
                    for iteration in range(1, args.repeat + 1):
                        platform_work = work / platform
                        if args.repeat > 1:
                            platform_work /= str(iteration)
                        platform_work.mkdir(parents=True, mode=0o700)
                        codes.append(run_platform(platform, platform_work, selectors, media_environment,
                                                  args.compile_file, caption_metadata, args.simulator, args.derived_data, clip))
                        if CANCEL_REQUESTED:
                            break
                    if CANCEL_REQUESTED:
                        break
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
        raise SystemExit(1 if CANCEL_REQUESTED or any(codes) else 0)


if __name__ == "__main__":
    main()
