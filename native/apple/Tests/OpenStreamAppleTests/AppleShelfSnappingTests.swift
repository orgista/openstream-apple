import Testing
@testable import OpenStreamApple

@Suite struct AppleShelfSnappingTests {
    @Test func onlyIOSShelvesSnapToWholeTiles() {
        #expect(AppleShelfSnapping.snapsToTiles(on: .iOS))
        #expect(!AppleShelfSnapping.snapsToTiles(on: .tvOS))
        #expect(!AppleShelfSnapping.snapsToTiles(on: .macOS))
        #expect(!AppleShelfSnapping.snapsToTiles(on: .visionOS))
    }

    @Test func exactlyOnePlatformOptsIn() {
        #expect(AppleShelfSnapping.Platform.allCases.filter(AppleShelfSnapping.snapsToTiles(on:)) == [.iOS])
    }

    @Test func theMacGateLeavesItsRailsUnsnapped() {
        // The package gate runs on macOS, whose rails page by button (N54).
        #expect(AppleShelfSnapping.current == .macOS)
        #expect(!AppleShelfSnapping.snapsToTiles(on: AppleShelfSnapping.current))
    }
}
