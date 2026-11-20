<div align="center">

<img src="native/apple/Apps/Shared/Assets.xcassets/AppIcon.appiconset/ios-1024.png" alt="OpenStream for Apple icon" width="96">

# OpenStream for Apple

**A media player for the movies, shows and live TV you already have, on iPhone, iPad, Apple TV, Mac and Vision Pro.**

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/orgista/openstream-apple/badge)](https://scorecard.dev/viewer/?uri=github.com/orgista/openstream-apple)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache%202.0-2ea44f?style=flat-square)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%C2%B7%20tvOS%20%C2%B7%20macOS%20%C2%B7%20visionOS-000000?style=flat-square&logo=apple&logoColor=white)](#features)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](native/apple/Package.swift)

[orgista.com/openstream](https://orgista.com/openstream) · [Build from source](#build-from-source) · [Security](SECURITY.md)

</div>

---

OpenStream plays media you own: your Jellyfin, Emby or Plex server, network shares (SMB), files on your device, and the
live TV playlist and guide your TV provider gives you. It runs on iPhone, iPad, Apple TV, Mac and Apple Vision Pro.
OpenStream does not provide, host or recommend any content; it starts empty and plays only what you connect.

## Features

- Movies and shows from your own media servers, network shares and files, with artwork, details and next-episode handling
- Live TV from your provider's M3U playlist and XMLTV guide, with a channel guide
- Playback through Apple's AVPlayer, with an FFmpeg-based engine ([AetherEngine](https://github.com/superuser404notfound/AetherEngine)) for formats AVPlayer cannot decode
- Disc images from your own collection, with DVD menus
- Downloads for offline viewing, SharePlay, widgets and Apple TV Top Shelf
- Metadata from [TMDB](https://www.themoviedb.org) with your own API key (credited in the app)

## Build from source

You need a Mac with Xcode 27 or later. Swift packages resolve on first build.

```bash
git clone https://github.com/orgista/openstream-apple.git
cd openstream-apple/native/apple

# Run the unit tests
swift test

# Build an app for the simulator without signing
xcodebuild -project Apps/OpenStreamApps.xcodeproj -scheme "OpenStream iOS" \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
```

Shared schemes: `OpenStream iOS`, `OpenStream tvOS`, `OpenStream visionOS`, `OpenStream macOS`. To run on a device,
open `native/apple/Apps/OpenStreamApps.xcodeproj` in Xcode and choose your own signing team.

| Path | Contents |
| --- | --- |
| `native/apple/Sources/OpenStreamApple` | Shared Swift package used by every app target |
| `native/apple/Tests` | Unit tests and small media fixtures |
| `native/apple/Apps` | Xcode project, app shells, widgets, Top Shelf extension |
| `native/apple/scripts` | Verification and licence-check scripts |

## Security

Please report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/orgista/openstream-apple/security/advisories/new). See
[SECURITY.md](SECURITY.md).

## Releases

Downloads live on the [Releases page](https://github.com/orgista/openstream-apple/releases): release notes, plus any direct-download builds.
Every build is made and signed on our build Mac and published there. iPhone, iPad, Apple TV, Apple Vision Pro and Mac builds ship through the App Store and TestFlight; each App Store version gets a matching GitHub release.

- **Versions** follow [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH`. A version with a
  suffix (`v1.4.0-beta.1`) is a pre-release and is marked as one.
- **Cadence:** we ship when a change is ready, and at least one maintenance release a month while the project
  is in active development. Security fixes ship within 7 days of a confirmed report.
- **Every release** has a [CHANGELOG](CHANGELOG.md) entry (the release notes are taken from it), a `SHA256SUMS` checksum file and a GitHub attestation for every file.
- **Support:** only the latest release gets fixes. Please update before reporting a bug.

Check a download before installing it:

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify OpenStream.dmg --repo orgista/openstream-apple
```

**Maintainers:** add the version's section to `CHANGELOG.md`, build and sign the release, then publish with

```bash
scripts/release-github X.Y.Z path/to/build-artifact
```

The script tags `vX.Y.Z`, uses the CHANGELOG section as the notes, uploads the files with `SHA256SUMS`, and can be
re-run safely. Full policy: [orgista release process](https://github.com/orgista/.github/blob/main/RELEASING.md).

## Contributing

Issues and pull requests are welcome. Run `swift test` from `native/apple` before opening a pull request.
