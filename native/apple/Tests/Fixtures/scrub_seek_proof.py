#!/usr/bin/env python3
"""Run the Apple TV scrub proof against generated loopback media in the foreground."""

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


ROOT = Path(__file__).resolve().parents[2]
SIM = "1DEA02F7-6279-4892-AE3F-0653116284ED"
TESTS = ["testRapidScrubbingStockPlayerThenDifferentTitlePlays",
         "testRapidScrubbingCustomPlayerThenDifferentTitlePlays"]


def run(args, *, deadline, log=None, **kwargs):
    timeout = min(1_200, max(1, deadline - time.monotonic()))
    if log:
        with log.open("w") as output:
            result = subprocess.run(args, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=timeout, **kwargs)
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed ({result.returncode}); see {log}")
    else:
        subprocess.run(args, check=True, timeout=timeout, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1_048_576), b""):
            digest.update(block)
    return digest.hexdigest()


def media_server(work, deadline, native_fixture, surface_fixture):
    spec = importlib.util.spec_from_file_location("scrub_fixture", ROOT / "Tests/Fixtures/serve.py")
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    media = {}
    for route, extension, source, supplied in [("native", "mp4", "mp4-h264-aac.mp4", native_fixture),
                                               ("surface", "mkv", "mkv-vp9-opus.mkv", surface_fixture)]:
        short = ROOT / "Tests/Fixtures/out" / source
        long = work / f"{route}-long.{extension}"
        if supplied:
            shutil.copyfile(supplied.resolve(), long)
        else:
            command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-stream_loop", "-1",
                       "-i", str(short), "-t", "1800", "-c", "copy"]
            if extension == "mp4":
                command += ["-movflags", "+faststart"]
            run(command + [str(long)], deadline=deadline, log=work / f"{route}-fixture.log")
            probe = json.loads(subprocess.check_output(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(long)],
                timeout=30))
            if float(probe["format"]["duration"]) < 1_800:
                raise RuntimeError(f"{route} fixture is shorter than 30 minutes")
        (work / f"{route}-fixture.sha256").write_text(sha256(long) + "\n")
        media[f"/{route}-first.{extension}"] = long
        media[f"/{route}-second.{extension}"] = short

    class Handler(fixture.FixtureHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            if path in media:
                return self._serve_file(str(media[path]), allow_range=True)
            return super().do_GET()

    server = fixture.FixtureServer("127.0.0.1", 0, str(ROOT / "Tests/Fixtures/out"))
    server.RequestHandlerClass = Handler
    return server


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
            environment["OPENSTREAM_SCRUB_FIXTURE_BASE"] = base
            environment["OPENSTREAM_ALLOW_MUTATING_UI_TESTS"] = "1"
    output.write_bytes(plistlib.dumps(config))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--attempt", required=True, type=int, choices=(1, 2, 3, 4))
    parser.add_argument("--round-2", action="store_true")
    parser.add_argument("--budget-seconds", type=int, default=1_200)
    parser.add_argument("--skip-app-build", action="store_true")
    parser.add_argument("--skip-test-build", action="store_true")
    parser.add_argument("--only-test", action="append", choices=TESTS)
    parser.add_argument("--native-fixture", type=Path)
    parser.add_argument("--surface-fixture", type=Path)
    args = parser.parse_args()
    deadline = time.monotonic() + args.budget_seconds
    dd = Path.home() / "Developer/sim-dd-scrub2-1103"
    name = "round2" if args.round_2 else f"attempt-{args.attempt}"
    work = ROOT / "verification-artifacts/scrub2-1103" / name
    work.mkdir(parents=True)
    try:
        exercise(args, deadline, dd, work)
    finally:
        if dd.exists():
            shutil.rmtree(dd)


def exercise(args, deadline, dd, work):
    apps = ROOT / "Apps"
    build = ["xcodebuild", "-project", "OpenStreamApps.xcodeproj", "-configuration", "Debug",
             "-destination", "id=" + SIM, "-derivedDataPath", str(dd), "-jobs", "4",
             "-clonedSourcePackagesDirPath", str(ROOT / ".build"), "-skipPackageUpdates",
             "CODE_SIGN_IDENTITY=-"]
    if not args.skip_app_build:
        print("Debug compile: tvOS app", flush=True)
        run(build + ["-scheme", "OpenStream tvOS", "build"], cwd=apps,
            deadline=deadline, log=work / "app-build.log")
    if not args.skip_test_build:
        print("Debug compile: tvOS UI tests", flush=True)
        run(build + ["-scheme", "OpenStreamTVUITests", "-testPlan", "E2E-tvOS",
                     "-parallel-testing-enabled", "NO", "build-for-testing"], cwd=apps,
            deadline=deadline, log=work / "test-build.log")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], timeout=30))
    booted = [device["udid"] for group in devices["devices"].values() for device in group
              if device["state"] == "Booted"]
    if any(device != SIM for device in booted):
        raise RuntimeError("A simulator outside this proof's allowlist is booted")
    server = media_server(work, deadline, args.native_fixture, args.surface_fixture)
    thread = threading.Thread(target=server.serve_forever, name="scrub-loopback-fixture")
    thread.start()
    bundle = work / "scrub.xcresult"
    sim_started = False
    started = time.monotonic()
    try:
        if SIM not in booted:
            run(["xcrun", "simctl", "boot", SIM], deadline=deadline)
        sim_started = True
        run(["xcrun", "simctl", "bootstatus", SIM, "-b"], deadline=deadline, stdout=subprocess.DEVNULL)
        products = dd / "Build/Products"
        built = next(path for path in (products / "Debug-appletvsimulator").glob("*.app")
                     if plistlib.loads((path / "Info.plist").read_bytes()).get("CFBundleIdentifier")
                     == "com.orgista.openstream")
        run(["xcrun", "simctl", "install", SIM, str(built)], deadline=deadline)
        installed = Path(subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", SIM, "com.orgista.openstream", "app"],
            text=True, timeout=30).strip())
        executable = plistlib.loads((built / "Info.plist").read_bytes())["CFBundleExecutable"]
        built_hash = sha256(built / executable)
        installed_hash = sha256(installed / executable)
        if built_hash != installed_hash:
            raise RuntimeError("Installed tvOS app differs from this lane build")
        (work / "installed-binary.sha256").write_text(installed_hash + "\n")
        generated = max(products.glob("*E2E-tvOS*.xctestrun"), key=lambda path: path.stat().st_mtime)
        test_run = work / "scrub.xctestrun"
        configure_test_run(generated, products, "http://127.0.0.1:" + str(server.server_port), test_run)
        tests = args.only_test or TESTS
        prefix = "OpenStreamTVUITests/AppleTVStubSmokeUITests/"
        print("Foreground scrub proof: " + ", ".join(tests), flush=True)
        run(["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
             "-destination", "id=" + SIM, "-parallel-testing-enabled", "NO",
             "-maximum-concurrent-test-simulator-destinations", "1", "-resultBundlePath", str(bundle)]
            + ["-only-testing:" + prefix + test for test in tests], cwd=apps,
            deadline=deadline, log=work / "ui-test.log")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        if sim_started:
            subprocess.run(["xcrun", "simctl", "terminate", SIM, "com.orgista.openstream"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            subprocess.run(["xcrun", "simctl", "shutdown", SIM], check=True, timeout=60)
        if bundle.exists():
            subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle),
                            "--output-path", str(work / "attachments")], check=True,
                           stdout=subprocess.DEVNULL, timeout=60)
        print(f"Scrub proof elapsed: {time.monotonic() - started:.1f}s; evidence: {work}", flush=True)


if __name__ == "__main__":
    main()
