import XCTest

/// Captures the macOS app's own window through XCUITest.
///
/// The `screencapture` CLI needs a Screen Recording grant on the calling process,
/// which cannot be given headlessly. `XCUIElement.screenshot()` goes through the
/// automation path instead and only ever sees the app's own window.
@MainActor
final class AppleMacScreenshotUITests: OpenStreamUITestCase {
    func testDiscoverWindowScreenshot() throws {
        let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60), "The macOS app never opened a window.")

        // Give the Discover shelves a chance to render before the shutter.
        let discover = app.descendants(matching: .any).matching(identifier: "tab.discover").firstMatch
        _ = discover.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 6)

        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "macOS Discover"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Text proof alongside the pixels, so a blank window cannot pass silently.
        let labels = app.descendants(matching: .any)
            .allElementsBoundByIndex
            .prefix(60)
            .map { "\($0.elementType.rawValue) \($0.identifier) \($0.label)" }
            .joined(separator: "\n")
        let tree = XCTAttachment(string: labels)
        tree.name = "macOS accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)

        app.terminate()
    }
}
