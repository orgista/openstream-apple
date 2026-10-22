<p align="center">
  <img alt="OpenStream icon" src="native/apple/Apps/Shared/Assets.xcassets/AppIcon.appiconset/ios-1024.png" width="96">
</p>

<h1 align="center">OpenStream for Apple</h1>

<h3 align="center">A media player for the movies, shows and live TV you already have</h3>

<p align="center">
  <a href="https://orgista.com/openstream">orgista.com/openstream</a> ·
  <a href="#build-from-source">Build</a> ·
  <a href="SECURITY.md">Security</a>
</p>

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

## Contributing

Issues and pull requests are welcome. Run `swift test` from `native/apple` before opening a pull request.
