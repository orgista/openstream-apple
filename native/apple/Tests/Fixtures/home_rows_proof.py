#!/usr/bin/env python3
"""Run one simulator proof with six overlapping Jellyfin libraries in a scoped fixture server."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading

import serve


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=["ios", "tvos"])
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    serve.LIBRARIES = []
    children = {}
    for media, kind, collection in [("Movie", "Movie", "movies"), ("Show", "Series", "tvshows")]:
        titles = []
        for index in range(30):
            item_id = f"rill-{media.lower()}-{index:02}"
            item, parent = serve._fixture_item(item_id, f"Rill {media} {index:02}", kind, "rill",
                ProductionYear=2024, RunTimeTicks=serve.RUNTIME_TICKS, Genres=["Drama"],
                CommunityRating=7 + index / 100, BackdropImageTags=[serve.IMAGE_TAG])
            serve.ITEMS[item_id] = item
            serve.PARENTS[item_id] = parent
            titles.append(item)
        for index in range(3):
            library_id = f"rill-{media.lower()}-library-{index}"
            serve.LIBRARIES.append({"Id": library_id, "Name": f"Latest {index}", "CollectionType": collection})
            children[library_id] = titles[index * 5:index * 5 + 20]
    original_children = serve._children
    requested_libraries = set()

    def library_children(parent):
        if parent in children:
            requested_libraries.add(parent)
            return children[parent]
        return original_children(parent)

    serve._children = library_children
    server = serve.FixtureServer("127.0.0.1", 0, str(Path(__file__).parent / "out"), visionos=True)
    worker = threading.Thread(target=server.serve_forever)
    worker.start()
    env = dict(os.environ, OPENSTREAM_HOME_ROWS_BASE=f"http://127.0.0.1:{server.server_port}")
    platform = args.platform
    udid = "09147349-C038-4285-9C6D-79E3EC64F203" if platform == "ios" else "1DEA02F7-6279-4892-AE3F-0653116284ED"
    suite = "OpenStreamiOSUITests/AppleiOSStubSmokeUITests" if platform == "ios" else "OpenStreamTVUITests/AppleTVStubSmokeUITests"
    scheme = "OpenStreamiOSUITests" if platform == "ios" else "OpenStreamTVUITests"
    try:
        app_scheme = "AppStore-iOS" if platform == "ios" else "AppStore-tvOS"
        product = "Debug-iphonesimulator/OpenStream iOS.app" if platform == "ios" else "Debug-appletvsimulator/OpenStream tvOS.app"
        subprocess.run(["xcodebuild", "-project", "Apps/OpenStreamApps.xcodeproj", "-scheme", app_scheme,
            "-configuration", "Debug", "-destination", f"id={udid}", "-derivedDataPath", args.derived_data,
            "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "build"], check=True, timeout=1200)
        subprocess.run(["xcrun", "simctl", "boot", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=180)
        subprocess.run(["xcrun", "simctl", "install", udid, str(Path(args.derived_data) / "Build/Products" / product)], check=True)
        result = subprocess.run(["xcodebuild", "-project", "Apps/OpenStreamApps.xcodeproj", "-scheme", scheme,
            "-destination", f"id={udid}", "-derivedDataPath", args.derived_data,
            "-resultBundlePath", args.result, "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
            "-only-testing:" + suite + "/testHomeRowsWithSixOverlappingLibraries", "CODE_SIGNING_ALLOWED=NO", "OPENSTREAM_HOME_ROWS_BASE=" + env["OPENSTREAM_HOME_ROWS_BASE"], "test"], env=env, timeout=900)
        if result.returncode:
            return result.returncode
        summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", args.result, "--compact"],
            check=True, capture_output=True, text=True)
        counts = json.loads(summary.stdout)
        if counts["passedTests"] != 1 or counts["skippedTests"] != 0 or len(requested_libraries) != 6:
            raise RuntimeError("Proof must pass without skips and load all six libraries")
        print(f"HOME_ROWS_PROOF {platform}: passed; libraries={len(requested_libraries)}", flush=True)
        return 0
    finally:
        server.shutdown()
        worker.join()
        server.server_close()
        subprocess.run(["xcrun", "simctl", "terminate", udid, "com.orgista.openstream"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["xcrun", "simctl", "shutdown", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    raise SystemExit(main())
