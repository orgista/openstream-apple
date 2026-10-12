import XCTest

/// Vision Pro: the player lives inside the app's one window, takes the
/// film's shape while it plays, and gives the window back as it was
/// (owner, 2026-10-07). Plays the loopback fixtures from
/// `Tests/Fixtures/serve.py` (`OPENSTREAM_FIXTURE_BASE`, default
/// http://127.0.0.1:8765), entered through Settings › Add Files › Direct URL
/// the way a viewer would.
///
/// `OPENSTREAM_VISION_CAPTURE_URL` (optional) is a loopback service that
/// answers with a `simctl io screenshot` PNG: `XCUIScreen` returns a 1×1
/// placeholder on this runtime.
@MainActor
final class AppleVisionPlayerUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")

    private var fixtureBase: String {
        ProcessInfo.processInfo.environment["OPENSTREAM_FIXTURE_BASE"] ?? "http://127.0.0.1:8765"
    }

    /// An endless live TS stream, so the player is still up while it is measured.
    private var endlessURL: String { fixtureBase + "/live/ts-h264-aac.ts" }
    /// A 15-second clip, for the end of playback.
    private var clipURL: String { fixtureBase + "/media/mp4-h264-aac.mp4" }

    private var teardownAdded = false

    /// Called by every test before its first launch: the arguments, and a
    /// teardown on the main actor (a failure capture, then the app quits).
    private func prepare() {
        continueAfterFailure = false
        if !teardownAdded {
            teardownAdded = true
            addTeardownBlock { @MainActor [self] in
                if let run = testRun, run.totalFailureCount > 0 { capture("failure-\(name)") }
                app.terminate()
            }
        }
        app.launchArguments = ["-OpenStreamResetOnLaunch", "YES", "-OpenStreamTrace", "YES",
                               "-OpenStreamMuteAudio", "YES", "-openstream.firstRunGuidanceSeen", "YES",
                               "-openstream.backup.icloud.enabled.v1", "NO",
                               "-OpenStreamVisionScreen", "add-files"]
    }

    // MARK: Tests

    /// One window before, during and after; the player is in it; the window
    /// keeps its width, turns 16:9 while playing and comes back exactly; the
    /// tab ornament leaves and returns; the page underneath is untouched.
    func testThePlayerLivesInTheWindowAndGivesItBack() throws {
        launch()
        let before = contentWindow.frame
        let tabsBefore = app.tabBars.firstMatch.exists
        XCTAssertEqual(windowCount, 1, "More than one window before playback")
        capture("vision-01-before-play")

        try play(endlessURL)
        XCTAssertTrue(waitForPlayer(), "The player never appeared")
        XCTAssertTrue(contentWindow.descendants(matching: .any)
            .matching(identifier: "player.close").firstMatch.exists || playerCloseExists,
                      "The player is not inside the app window")
        XCTAssertEqual(windowCount, 1, "Playback opened a second window")
        let playing = waitForFrame { frame in
            abs(frame.width - before.width) <= 2 && abs(frame.width / frame.height - 16.0 / 9.0) <= 16.0 / 9.0 * 0.02
        }
        XCTAssertEqual(playing.width, before.width, accuracy: 2, "The window changed width: \(before) -> \(playing)")
        XCTAssertEqual(playing.width / playing.height, 16.0 / 9.0, accuracy: 16.0 / 9.0 * 0.02,
                       "The playing window is not 16:9: \(playing)")
        if tabsBefore { XCTAssertTrue(waitForTabs(present: false), "The tab ornament stayed up over the player") }
        capture("vision-02-playing")

        try closePlayer()
        let after = waitForFrame { frame in
            abs(frame.width - before.width) <= 1 && abs(frame.height - before.height) <= 1
        }
        XCTAssertEqual(after.width, before.width, accuracy: 1, "Width not restored: \(before) -> \(after)")
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Height not restored: \(before) -> \(after)")
        XCTAssertEqual(windowCount, 1, "More than one window after playback")
        if tabsBefore { XCTAssertTrue(waitForTabs(present: true), "The tab ornament did not come back") }
        XCTAssertTrue(waitUntilHittable(directURLRow, timeout: 10),
                      "The Add Files page did not come back under the player")
        capture("vision-03-after-close")
    }

    /// A clip that plays to its end closes the player and restores the window.
    func testAClipThatEndsGivesTheWindowBack() throws {
        launch()
        let before = contentWindow.frame
        try play(clipURL)
        XCTAssertTrue(waitForPlayer(), "The player never appeared")
        XCTAssertEqual(windowCount, 1)
        // The close button also hides with the controls; the page coming back is the proof.
        XCTAssertTrue(waitUntilHittable(directURLRow, timeout: 60),
                      "The page did not come back after the 15 s clip ended")
        let after = waitForFrame { abs($0.width - before.width) <= 1 && abs($0.height - before.height) <= 1 }
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Height not restored: \(before) -> \(after)")
        XCTAssertEqual(windowCount, 1)
    }

    /// A stream that cannot play: the failure alert is in the app's window,
    /// Close returns to the page, and the window is as it was.
    func testAFailedStreamStaysInTheWindow() throws {
        launch()
        let before = contentWindow.frame
        try play("http://127.0.0.1:9/missing.mp4")
        let failed = app.alerts["Playback Failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: 60), "No Playback Failed alert")
        XCTAssertEqual(windowCount, 1, "The failure opened a second window")
        capture("vision-04-failure")
        failed.buttons["Close"].tap()
        XCTAssertTrue(waitUntilHittable(directURLRow, timeout: 15), "Close did not return to the page")
        let after = waitForFrame { abs($0.width - before.width) <= 1 && abs($0.height - before.height) <= 1 }
        XCTAssertEqual(after.height, before.height, accuracy: 1, "Height not restored: \(before) -> \(after)")
        XCTAssertEqual(windowCount, 1)
    }

    /// visionOS restores scenes on relaunch: there is no player scene left to
    /// come back as a black window.
    func testARelaunchAfterPlaybackOpensOneWindow() throws {
        launch()
        try play(endlessURL)
        XCTAssertTrue(waitForPlayer(), "The player never appeared")
        app.terminate()
        launch()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(windowCount, 1, "A relaunch after playback brought back more than one window")
        XCTAssertFalse(playerCloseExists, "A relaunch reopened the player")
    }

    /// Owner report: audio played on after the window was closed. Leaving
    /// the foreground stops and closes the player (`vision stage background
    /// → stop` in the trace); coming back shows the page, not a player.
    func testLeavingTheForegroundStopsThePlayer() throws {
        launch()
        try play(endlessURL)
        XCTAssertTrue(waitForPlayer(), "The player never appeared")
        XCUIDevice.shared.press(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 15)
            || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        guard backgrounded else {
            // Measured 2026-10-07 on the visionOS 27 simulator: the Home View
            // opens over the window and the app stays runningForeground, and
            // XCTest has no way to close a window. The policy test and a
            // device check cover it.
            capture("vision-05-home-view")
            throw XCTSkip("The simulator kept the app in the foreground after Home (state \(app.state.rawValue))")
        }
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(waitUntilHittable(directURLRow, timeout: 15), "The page is not back after the app returned")
        XCTAssertFalse(playerCloseExists, "The player was still up after the app left the foreground")
        XCTAssertEqual(windowCount, 1)
    }

    // MARK: Helpers

    private func launch() {
        prepare()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        XCTAssertTrue(directURLRow.waitForExistence(timeout: 45), "Add Files did not open")
        // Share discovery fills in above the row and moves it; wait until it rests.
        var last = CGRect.null
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 1)
            let frame = directURLRow.frame
            if frame == last, directURLRow.isHittable { break }
            last = frame
        }
    }

    /// The page under the player is in the accessibility tree all along
    /// (hidden), so coming back means hittable, not merely present.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),
                                                 object: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    /// The app's windows. The simulator also lists the tab ornament
    /// (176 x 241), an alert (328 x 275) and one or two system containers
    /// larger than any window (1692 x 1292 or 1500 x 1151, measured
    /// 2026-10-07) as window elements; none is a window the wearer sees.
    private var windows: [XCUIElement] {
        let all = app.windows.allElementsBoundByIndex.filter { $0.frame.width >= 480 && $0.frame.height >= 260 }
        let sizes = Set(all.map { "\($0.frame.size)" })
        guard sizes.count > 1 else { return all }
        let largest = all.map(\.frame.size).max { $0.width * $0.height < $1.width * $1.height }
        return all.filter { $0.frame.size != largest }
    }

    private var windowCount: Int {
        let all = app.windows.allElementsBoundByIndex
        print("[vision-e2e] windows: " + all.map { "\($0.identifier)|\($0.frame)" }.joined(separator: "; "))
        return windows.count
    }

    private var contentWindow: XCUIElement {
        windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app.windows.firstMatch
    }

    private var directURLRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Direct URL")).firstMatch
    }

    private var playerClose: XCUIElement { element("player.close") }

    private var playerCloseExists: Bool { playerClose.exists }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func play(_ url: String) throws {
        XCTAssertTrue(directURLRow.waitForExistence(timeout: 30))
        directURLRow.tap()
        let alert = app.alerts["Direct URL"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "The Direct URL prompt did not open")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(url)
        alert.buttons["Play"].tap()
    }

    /// The player's close button is there once the player is (controls show
    /// on arrival and after a tap).
    private func waitForPlayer() -> Bool {
        if playerClose.waitForExistence(timeout: 30) { return true }
        revealControls()
        return playerClose.waitForExistence(timeout: 15)
    }

    private func revealControls() {
        guard !playerClose.exists else { return }
        contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
    }

    private func closePlayer() throws {
        for _ in 0..<3 where !playerClose.isHittable {
            revealControls()
            _ = playerClose.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(playerClose.exists, "No close button on the player")
        playerClose.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: playerClose)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed, "The player did not close")
    }

    /// The window's frame once `matches` holds, or the last one seen after
    /// 15 s (the geometry request is asynchronous).
    private func waitForFrame(_ matches: (CGRect) -> Bool) -> CGRect {
        var frame = contentWindow.frame
        for _ in 0..<30 {
            frame = contentWindow.frame
            if matches(frame) { return frame }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return frame
    }

    private func waitForTabs(present: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == %@", NSNumber(value: present)),
                                                    object: app.tabBars.firstMatch)
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_VISION_CAPTURE_URL"],
              let url = URL(string: raw + "?name=" + name) else { return }
        let done = expectation(description: "capture \(name)")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 30)
    }
}
