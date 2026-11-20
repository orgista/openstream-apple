#!/usr/bin/env python3
"""Export named screenshot attachments without exporting private test activity logs.

Usage: python3 -I scripts/export-appstore-screenshots.py RESULT.xcresult OUTPUT
Inspect every exported image before treating it as a submission screenshot.
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
from PIL import Image, ImageOps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="openstream-shots-", dir="/tmp") as scratch:
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path",
                        str(args.result), "--output-path", scratch], check=True,
                       stdout=subprocess.DEVNULL)
        manifest = json.loads((pathlib.Path(scratch) / "manifest.json").read_text())
        for test in manifest:
            for attachment in test.get("attachments", []):
                name = attachment.get("suggestedHumanReadableName", "")
                match = re.match(r"^(\d\d-[a-z-]+)(?:_|\.png)", name)
                source = pathlib.Path(scratch) / attachment["exportedFileName"]
                if match and source.suffix.lower() == ".png":
                    destination = args.output / (match[1] + ".png")
                    shutil.copyfile(source, destination)
                    # XCUIScreen encodes landscape pixels with an EXIF rotation.
                    # Bake that orientation into the export so upload dimensions
                    # are the displayed dimensions, without resizing the image.
                    with Image.open(destination) as screenshot:
                        oriented = ImageOps.exif_transpose(screenshot)
                        # simctl's native Vision PNG has an opaque alpha channel.
                        # Drop that channel without changing any RGB pixel.
                        if oriented.mode == "RGBA":
                            if oriented.getchannel("A").getextrema() != (255, 255):
                                raise ValueError("Screenshot contains transparent pixels: " + destination.name)
                            oriented = oriented.convert("RGB")
                        oriented.save(destination)
                    size = subprocess.check_output(
                        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(destination)],
                        text=True)
                    dimensions = re.findall(r"pixel(?:Width|Height): (\d+)", size)
                    print(destination.name + " " + "x".join(dimensions))


if __name__ == "__main__":
    main()
