#!/usr/bin/env python3
"""Hold PlaybackInfo and media independently while the foreground UI tests run."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time
from urllib.parse import urlparse


RUN_DEADLINE = float("inf")
ROOT = Path(__file__).resolve().parents[2]
SIMS = {
    "iOS": "09147349-C038-4285-9C6D-79E3EC64F203",
    "tvOS": "1DEA02F7-6279-4892-AE3F-0653116284ED",
}
TARGETS = {"iOS": "OpenStreamiOSUITests", "tvOS": "OpenStreamTVUITests"}
CLASSES = {"iOS": "AppleiOSStubSmokeUITests", "tvOS": "AppleTVStubSmokeUITests"}


def run(args, *, log=None, **kwargs):
    if log:
        with log.open("w") as output:
            result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=min(900, max(1, RUN_DEADLINE - time.monotonic())), **kwargs)
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed ({result.returncode}); see {log}")
    else:
        subprocess.run(args, check=True, timeout=120, **kwargs)


def fixture_media(work):
    fixtures = ROOT / "Tests/Fixtures/out"
    paths = {"native": work / "bars.mp4", "surface": work / "bars-vp9.mkv"}
    for route, name in [("native", "mp4-h264-aac.mp4"), ("surface", "mkv-vp9-opus.mkv")]:
        shutil.copy2(fixtures / name, paths[route])
    shutil.copytree(fixtures / "hls", work / "hls")
    return paths


def fixture_server(media):
    spec = importlib.util.spec_from_file_location("startup_fixture", ROOT / "Tests/Fixtures/serve.py")
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    resolution = threading.Event()
    frames = threading.Event()
    resolution.set()
    frames.set()
    state = {"resolving": False, "engine": False, "failure": False}
    live = {"continuous": False, "started": None}
    selected = {"route": "native"}
    original_source = fixture._media_source

    def source(item_id, visionos=False):
        result = original_source(item_id, visionos=visionos)
        if selected["route"] == "surface":
            result["Container"] = "mkv"
            result["MediaStreams"][0]["Codec"] = "vp9"
            result["MediaStreams"] = result["MediaStreams"][:1]
        return result

    fixture._media_source = source

    class Handler(fixture.FixtureHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            path = urlparse(self.path).path
            base = "http://127.0.0.1:" + str(self.server.server_port)
            if path == "/startup/channels.m3u":
                stream = "/live/index.m3u8" if selected["route"] == "native" else "/live/surface.mkv"
                playlist = ("#EXTM3U\n#EXTINF:-1 tvg-id=\"startup\" tvg-logo=\""
                            + base + "/jf/Items/jf-movie-5/Images/Logo\",Startup Live\n"
                            + base + stream + "\n")
                return self._send_simple(200, playlist.encode(), "audio/x-mpegurl")
            if path == "/startup/guide.xml":
                return self._send_simple(200, b"<?xml version='1.0'?><tv></tv>", "application/xml")
            if path.startswith("/live/"):
                state["engine"] = True
                if live["continuous"] and path.endswith("index.m3u8"):
                    if live["started"] is None:
                        live["started"] = time.monotonic()
                    end = int((time.monotonic() - live["started"]) / 4.32) + 3
                    start = max(0, end - 3)
                    playlist = ("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:5\n"
                                + f"#EXT-X-MEDIA-SEQUENCE:{start}\n#EXT-X-DISCONTINUITY-SEQUENCE:{start}\n")
                    playlist += "#EXT-X-DISCONTINUITY\n".join(
                        f"#EXTINF:4.32,\n/live/loop-{index}.ts\n" for index in range(start, end))
                    return self._send_simple(200, playlist.encode(), "application/vnd.apple.mpegurl")
                if not frames.wait(60):
                    return self._send_simple(504)
                if path.rsplit("/", 1)[-1].startswith("loop-"):
                    return self._serve_file(str(media["native"].parent / "hls/seg000.ts"), allow_range=True)
                if path.endswith("surface.mkv"):
                    return self._serve_file(str(media["surface"]), allow_range=True)
                return self._serve_file(str(media["native"].parent / "hls" / path.rsplit("/", 1)[-1]),
                                        allow_range=True)
            return super().do_GET()

        def do_POST(self):
            path = urlparse(self.path).path
            if path.startswith("/startup/"):
                action = path.rsplit("/", 1)[-1]
                if action.startswith("reset-"):
                    selected["route"] = action.removeprefix("reset-")
                    resolution.clear()
                    frames.clear()
                    state.update(resolving=False, engine=False, failure=False)
                    live.update(continuous=False, started=None)
                elif action == "continuous-live":
                    live.update(continuous=True, started=None)
                    frames.set()
                elif action == "stall-media":
                    frames.clear()
                elif action == "fail-resolution":
                    state["failure"] = True
                    resolution.set()
                elif action == "release-resolution":
                    resolution.set()
                elif action == "release-media":
                    frames.set()
                elif action != "status":
                    return self._send_simple(404)
                return self._send_json(state)
            if path.endswith("/PlaybackInfo"):
                state["resolving"] = True
                if not resolution.wait(60):
                    return self._send_simple(504)
                if state["failure"]:
                    return self._send_simple(503)
            return super().do_POST()

        def _serve_clip(self, item_id, download=False):
            state["engine"] = True
            if not frames.wait(60):
                return self._send_simple(504)
            return self._serve_file(str(media[selected["route"]]), allow_range=True)

    server = fixture.FixtureServer("127.0.0.1", 0, str(media["native"].parent))
    server.RequestHandlerClass = Handler
    return server, resolution, frames


def configure_test_run(path, products, base, output):
    def expand(value):
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(products))
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    config = expand(plistlib.loads(path.read_bytes()))
    for configuration in config["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            environment = target.setdefault("EnvironmentVariables", {})
            if base is None:
                environment.pop("OPENSTREAM_STARTUP_FIXTURE_BASE", None)
            else:
                environment["OPENSTREAM_STARTUP_FIXTURE_BASE"] = base
    output.write_bytes(plistlib.dumps(config))


def prove(platform, dd, work, base, only_tests):
    sim = SIMS[platform]
    result = work / platform
    result.mkdir()
    apps = ROOT / "Apps"
    destination = "id=" + sim
    build = ["xcodebuild", "-project", "OpenStreamApps.xcodeproj", "-destination", destination,
             "-derivedDataPath", str(dd), "-configuration", "Debug", "-jobs", "4", "CODE_SIGN_IDENTITY=-"]
    run(build + ["-scheme", "OpenStream " + platform, "build"], cwd=apps,
        log=result / "app-build.log")
    run(build + ["-scheme", TARGETS[platform], "-testPlan", "E2E-" + platform,
                 "-parallel-testing-enabled", "NO", "build-for-testing"], cwd=apps,
        log=result / "test-build.log")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
    booted = [item["udid"] for group in devices["devices"].values() for item in group
              if item["state"] == "Booted"]
    if any(item not in SIMS.values() for item in booted):
        raise RuntimeError("A simulator outside this job's test allowlist is booted")
    for item in booted:
        run(["xcrun", "simctl", "shutdown", item])
    run(["xcrun", "simctl", "boot", sim])
    try:
        run(["xcrun", "simctl", "bootstatus", sim, "-b"], stdout=subprocess.DEVNULL)
        products = dd / "Build/Products"
        configuration = "Debug-iphonesimulator" if platform == "iOS" else "Debug-appletvsimulator"
        app = next(path for path in (products / configuration).glob("*.app")
                   if plistlib.loads((path / "Info.plist").read_bytes()).get("CFBundleIdentifier")
                   == "com.orgista.openstream")
        run(["xcrun", "simctl", "install", sim, str(app)])
        installed = Path(subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", sim, "com.orgista.openstream", "app"], text=True).strip())
        executable = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleExecutable"]
        built_hash = hashlib.sha256((app / executable).read_bytes()).hexdigest()
        installed_hash = hashlib.sha256((installed / executable).read_bytes()).hexdigest()
        if built_hash != installed_hash:
            raise RuntimeError("Installed app differs from the lane build")
        (result / "installed-binary.sha256").write_text(installed_hash + "\n")
        generated = max(products.glob("*E2E-" + platform + "*.xctestrun"), key=lambda p: p.stat().st_mtime)
        test_run = result / "startup.xctestrun"
        configure_test_run(generated, products, base, test_run)
        bundle = result / "startup.xcresult"
        prefix = TARGETS[platform] + "/" + CLASSES[platform] + "/"
        tests = [prefix + "testOneStartupIndicatorThroughResolutionAndBothEngines"]
        if platform == "tvOS":
            tests += [prefix + "testLiveKeepsOneStartupIndicatorUntilTheFrame",
                      prefix + "testLiveRebufferKeepsTheLastFrame"]
        else:
            tests += [prefix + "testStartupCanBeCancelledAndFailureAppearsAfterDismissal",
                      prefix + "testStartupCanBeCancelledAtEngineHandoff",
                      prefix + "testStartupTimeoutOffersRetryAndThenPlays"]
        if only_tests:
            tests = [prefix + name for name in only_tests]
        no_fixture_run = result / "no-fixture.xctestrun"
        configure_test_run(generated, products, None, no_fixture_run)
        run(["xcodebuild", "test-without-building", "-xctestrun", str(no_fixture_run),
             "-destination", destination, "-parallel-testing-enabled", "NO",
             "-resultBundlePath", str(result / "no-fixture.xcresult")]
            + ["-only-testing:" + test for test in tests], cwd=apps, log=result / "no-fixture.log")
        try:
            run(["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
                 "-destination", destination, "-parallel-testing-enabled", "NO",
                 "-maximum-concurrent-test-simulator-destinations", "1",
                 "-resultBundlePath", str(bundle)] + ["-only-testing:" + test for test in tests],
                cwd=apps, log=result / "ui-test.log")
        finally:
            if bundle.exists():
                run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                     "--output-path", str(result / "attachments")], stdout=subprocess.DEVNULL)
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", sim, "com.orgista.openstream"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(["xcrun", "simctl", "shutdown", sim])


def main():
    global RUN_DEADLINE
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", nargs="+", choices=SIMS, default=list(SIMS))
    parser.add_argument("--attempt", type=int, required=True)
    parser.add_argument("--budget-seconds", type=int, default=1800)
    parser.add_argument("--compile-all", action="store_true")
    parser.add_argument("--only-test", action="append")
    args = parser.parse_args()
    RUN_DEADLINE = time.monotonic() + args.budget_seconds
    dd = Path.home() / "Developer/sim-dd-spinner-1102"
    if dd.exists() or dd.is_symlink():
        raise RuntimeError("Lane DerivedData already exists; refusing to replace it")
    work = ROOT.parent.parent / "proof" / ("attempt-" + str(args.attempt))
    work.mkdir(parents=True)
    media = fixture_media(work)
    server, resolution, frames = fixture_server(media)
    thread = threading.Thread(target=server.serve_forever, name="startup-fixture")
    started = time.monotonic()
    thread.start()
    try:
        base = "http://127.0.0.1:" + str(server.server_port)
        if args.compile_all:
            compile_platforms = [("macOS", "platform=macOS,arch=arm64"),
                                 ("visionOS", "generic/platform=visionOS Simulator")]
            for platform in ("tvOS", "iOS"):
                if platform not in args.platform:
                    compile_platforms.append((platform, "generic/platform=" + platform + " Simulator"))
            for platform, destination in compile_platforms:
                print("Debug compile: " + platform, flush=True)
                run(["xcodebuild", "-project", "OpenStreamApps.xcodeproj", "-scheme", "OpenStream " + platform,
                     "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(dd),
                     "-jobs", "4", "CODE_SIGNING_ALLOWED=NO", "build"], cwd=ROOT / "Apps",
                    log=work / (platform + "-build.log"))
        for platform in args.platform:
            print("Startup proof: " + platform, flush=True)
            prove(platform, dd, work, base, args.only_test)
    finally:
        resolution.set()
        frames.set()
        server.shutdown()
        server.server_close()
        thread.join()
        if dd.exists():
            shutil.rmtree(dd)
        print(f"Foreground proof elapsed: {time.monotonic() - started:.1f}s", flush=True)


if __name__ == "__main__":
    main()
