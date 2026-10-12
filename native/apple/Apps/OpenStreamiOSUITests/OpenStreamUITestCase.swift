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

    /// The stub fixtures beside the test plans (`Apps/TestPlans/Stubs`): from
    /// the plan's `OPENSTREAM_STUB_DIR`, else resolved from this file's path.
    static var stubDirectory: String {
        if let path = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"], !path.isEmpty { return path }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestPlans/Stubs").path
    }

    /// Launch arguments for a stubbed, silent, traced run.
    static var stubbedLaunchArguments: [String] {
        ["-OpenStreamStubNetwork", stubDirectory, "-OpenStreamResetOnLaunch", "YES",
         "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
    }
}
