# OpenStream Apple — build 12 source

This repository starts with the Apple source baseline for OpenStream 1.0 (12),
from source commit `bf6988ea0615a59f824cea20e15e16a5ed126178`. It includes the Watch icon packaging
fix accepted with the September 17, 2026 iOS TestFlight delivery.

## Layout

- Xcode project: `native/apple/Apps/OpenStreamApps.xcodeproj`
- Swift package and tests: `native/apple`
- Shared app schemes: `OpenStream iOS`, `OpenStream tvOS`, `OpenStream visionOS`, `OpenStream macOS`
- iOS, tvOS, visionOS and embedded targets: version 1.0, build 12.
- macOS: version 1.0, build 1; this is an unfinished baseline, not a Mac release.

## Publication adjustments

This is a build-12-based source snapshot, not a byte-for-byte recreation of its signed binary.
Personal catalog configuration is read from the optional `OpenStreamTestCatalogManifests`
Info.plist string array instead of being embedded in source. With no configuration,
no catalog is seeded. Tests inject synthetic catalog addresses; the long-URL test
uses a synthetic configuration of the same shape rather than personal settings.
Signing is automatic so cloud workers do not require named profiles from a developer's Mac.
Shared schemes and a small generated test video make the checkout self-contained.
Newer development features are not included.

Private media, local screenshots, build caches, credentials, operational notes and
historical Git objects are excluded. Do not add them to this repository.

## Verification

From `native/apple`, run `swift test --scratch-path /tmp/openstream-apple-tests`.
Verified September 17, 2026: 986 tests in 96 suites pass, and the unsigned iOS Release build passes.
The app, Widget and Watch products all report build 12. Optional device/media tests still require
their documented environment and fixtures. The included H.264/AAC test clip is generated
from an FFmpeg test pattern and sine wave; it contains no third-party media.

Xcode Cloud must use this repository's `main` branch and the project path above.
Use build checks first. TestFlight distribution requires explicit approval for the
next build number; do not attempt to replace the already accepted build 12 binary.
