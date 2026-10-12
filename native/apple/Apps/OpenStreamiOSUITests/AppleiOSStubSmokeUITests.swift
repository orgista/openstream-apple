import XCTest

/// Launch → Discover row → title page → back, with every control-plane
/// request answered from `Apps/TestPlans/Stubs` (`-OpenStreamStubNetwork`):
/// no network, no owner sources, the same screen every run.
@MainActor
final class AppleiOSStubSmokeUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = Self.stubbedLaunchArguments
    }

    override func tearDown() {
        app?.terminate()
    }

    func testDiscoverRowOpensATitleFromStubsAndComesBack() {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // Discover is lazy: the stub shelf sits under the hero, so it is not
        // in the hierarchy until it has scrolled into view.
        let poster = app.descendants(matching: .any).matching(identifier: "home.media.movie:tt0000001").firstMatch
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.' OR identifier BEGINSWITH 'discover.'")).firstMatch
            .waitForExistence(timeout: 60), "Discover never drew")
        for _ in 0 ..< 8 where !(poster.exists && poster.isHittable) {
            app.swipeUp()
            _ = poster.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(poster.exists && poster.isHittable, "the stub catalog row never drew")
        poster.tap()

        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(app.staticTexts["Stub Movie One"].firstMatch.waitForExistence(timeout: 10))

        let back = app.buttons["detail.back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertFalse(play.waitForExistence(timeout: 5), "the title page did not close")
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "Discover did not come back")
    }
}
