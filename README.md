<p align="center">
  <img alt="OpenStream icon" src="native/apple/Apps/Shared/Assets.xcassets/AppIcon.appiconset/ios-1024.png" width="96">
</p>

<h1 align="center">OpenStream for Apple</h1>

<h3 align="center">A native media player for iPhone, iPad, Apple TV, Apple Watch and Vision Pro</h3>

<p align="center">
  <a href="#build-from-source">Build</a> ·
  <a href="https://github.com/orgista/openstream">Android, Google TV, XR and web</a> ·
  <a href="https://orgista.com">orgista.com</a>
</p>

<p align="center">
  <a href="#compatibility"><img alt="Platforms" src="https://img.shields.io/badge/platform-iOS%20%7C%20tvOS%20%7C%20visionOS%20%7C%20watchOS%20%7C%20macOS-1c1e20?style=flat-square"></a>
  <a href="native/apple/Package.swift"><img alt="Swift 6.2" src="https://img.shields.io/badge/swift-6.2-F05138?style=flat-square"></a>
</p>

OpenStream plays media from your own sources: SMB network shares, local files, Stremio add-ons and IPTV playlists. This repository holds the Apple apps, written in Swift and SwiftUI. The Android, Google TV, XR and web apps live in the sibling project, [orgista/openstream](https://github.com/orgista/openstream).

## Features

- Library of movies and shows built from SMB shares and local files, with metadata, artwork and next-episode handling
- Stremio add-on sources, with stream ranking and subtitle selection
- Live TV from M3U playlists, Xtream sources and XMLTV guides, shown in a channel guide grid
- Playback through AVPlayer, with a bundled FFmpeg-based engine ([AetherEngine](https://github.com/superuser404notfound/AetherEngine)) for formats AVPlayer cannot decode, including Dolby Vision handling
- Offline downloads with quality settings and Live Activities for progress
- SharePlay, Spotlight indexing and App Intents for search
- Apple TV Top Shelf, home screen widgets, and an Apple Watch companion app
- Web Management: add sources from a browser on the same local network

## Download

There are no public releases yet. Build the app from source using the steps below.

## Compatibility

| Platform | Minimum | Notes |
| --- | --- | --- |
| iOS, iPadOS | 18.0 | One app for iPhone and iPad. Includes the widgets extension and embeds the Watch app. |
| tvOS | 18.0 | Includes a Top Shelf extension. |
| visionOS | 2.0 | Builds from the shared source. |
| watchOS | 11.0 | Companion to the iOS app. |
| macOS | 15.0 | Unfinished baseline, not a release target. |

## Build from source

You need a Mac with an Xcode version that ships the Swift 6.2 toolchain. Swift packages resolve on first build.

```bash
git clone https://github.com/orgista/openstream-apple.git
cd openstream-apple/native/apple

# Run the unit tests
swift test

# Build an app for the simulator without signing
xcodebuild -project Apps/OpenStreamApps.xcodeproj -scheme "OpenStream iOS" \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
```

Shared schemes: `OpenStream iOS`, `OpenStream tvOS`, `OpenStream visionOS`, `OpenStream macOS`. To run on a device, open `native/apple/Apps/OpenStreamApps.xcodeproj` in Xcode and choose your own signing team.

| Path | Contents |
| --- | --- |
| `native/apple/Sources/OpenStreamApple` | Shared Swift package used by every app target |
| `native/apple/Tests` | Unit tests and small media fixtures |
| `native/apple/Apps` | Xcode project, app shells, widgets, Watch app, Top Shelf extension |
| `native/apple/scripts` | Verification and license-check scripts |

No catalog is preconfigured. Add your own sources in the app's settings. See [DELIVERIES.md](DELIVERIES.md) for the build notes of the current source baseline.

## Contributing

Issues and pull requests are welcome. Run `swift test` from `native/apple` before opening a pull request.
