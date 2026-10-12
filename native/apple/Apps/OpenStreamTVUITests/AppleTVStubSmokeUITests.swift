import XCTest

/// Launch → Discover row → title page → back on the Apple TV, with every
/// control-plane request answered from `Apps/TestPlans/Stubs`
/// (`-OpenStreamStubNetwork`): no network, no owner sources.
@MainActor
final class AppleTVStubSmokeUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { .shared }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = Self.stubbedLaunchArguments
    }

    override func tearDown() {
        app?.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    func testDiscoverRowOpensATitleFromStubsAndComesBack() {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60), "Discover never took focus")
        let poster = element("home.media.movie:tt0000001")

        // Walk focus down from the hero until the poster holds it (the shelf
        // is lazy and only enters the hierarchy as focus reaches it), then open.
        let focusedPoster = app.descendants(matching: .any).matching(NSPredicate(
            format: "hasFocus == true AND identifier == %@", "home.media.movie:tt0000001")).firstMatch
        for _ in 0 ..< 10 where !focusedPoster.exists {
            remote.press(.down)
            _ = focusedPoster.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(focusedPoster.exists, "focus never reached the stub poster; sits on '\(focusedElement.identifier)'")
        remote.press(.select)

        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(app.staticTexts["Stub Movie One"].firstMatch.waitForExistence(timeout: 10))

        remote.press(.menu)
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "Discover did not come back")
    }
}
