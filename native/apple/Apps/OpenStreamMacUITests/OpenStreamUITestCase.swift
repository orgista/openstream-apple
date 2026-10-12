import XCTest

/// Base for every UI test class: a failed test leaves a full-screen
/// screenshot in the result bundle, taken before the subclass tears the app
/// down, so a red run can be read without re-running it.
@MainActor
class OpenStreamUITestCase: XCTestCase {
    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        try super.tearDownWithError()
    }
}
