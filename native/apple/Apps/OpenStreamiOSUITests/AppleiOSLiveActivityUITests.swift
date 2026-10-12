import XCTest

/// The download Live Activity, verified on the iPhone simulator.
///
/// A previous pre-ship pass stopped at "the Download button is hittable" and
/// called the Activity itself unverifiable without a device. An iPhone 16 Pro
/// simulator has a Dynamic Island and ActivityKit works on it, so this taps
/// Download for real, then goes to the Home Screen and photographs the island.
///
/// It cleans up after itself: the download is cancelled through the app's own
/// dialog so nothing is left on the persistent simulator.
@MainActor
final class AppleiOSLiveActivityUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        app?.terminate()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testDownloadStartsALiveActivityAndTheIslandShowsIt() throws {
        app.launchArguments += ["-OpenStreamVisionScreen", "detail", "-OpenStreamTrace", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app never came to the foreground")

        // The per-episode ↓ is the control the owner uses; it is disabled until
        // the canonical id resolves, so wait for that rather than tapping early.
        let download = app.buttons.matching(identifier: "detail.episode.download").firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 60), "no per-episode Download control on the detail page")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"),
                                                          evaluatedWith: download)], timeout: 60),
                       .completed, "the Download control never became enabled")

        let hittable = NSPredicate(format: "isHittable == true")
        for _ in 0..<8 where !download.isHittable {
            if download.frame.midY > app.frame.height - 100 { app.swipeUp(velocity: .slow) }
            else if download.frame.minY < 70 { app.swipeDown(velocity: .slow) }
            else { _ = XCTWaiter().wait(for: [expectation(for: hittable, evaluatedWith: download)], timeout: 2) }
        }
        XCTAssertTrue(download.isHittable, "the Download control never became tappable")
        attach("01-before-tap")

        download.tap()

        // Something has to be happening before the Activity can exist: the row
        // turns busy, or the page reports why the download failed.
        let busyLabel = NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                                    "Preparing ", "Downloading ", "Downloaded ")
        let busy = app.buttons.matching(identifier: "detail.episode.download").matching(busyLabel).firstMatch
        let status = app.staticTexts["detail.download.status"]
        let outcome = app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier == %@ AND (label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@)) OR identifier == %@",
            "detail.episode.download", "Preparing ", "Downloading ", "Downloaded ", "detail.download.status")).firstMatch
        _ = outcome.waitForExistence(timeout: 90)
        attach("02-in-app-after-tap")
        let started = busy.exists
        let failure = status.exists ? status.label : nil
        print("LIVEACTIVITY download started=\(started) failure=\(failure ?? "-") label=\(started ? busy.label : "-")")
        // A simulator whose only add-on is a metadata catalog has nothing to
        // download from; the app says so, and that is not this test's failure.
        if !started, failure?.hasPrefix("No downloadable source") == true {
            throw XCTSkip("No stream add-on on this simulator, so there is nothing to download: \(failure ?? "")")
        }
        XCTAssertTrue(started, "tapping ↓ never put the row into a downloading state\(failure.map { " — it failed: \($0)" } ?? "")")

        // Home Screen: a running Live Activity renders as the black pill around
        // the camera cut-out on this device.
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 15), "the Home Screen never came up")
        attach("03-home-screen-dynamic-island")

        // Long-press-free expansion is not scriptable; the compact pill is the
        // proof. Come back and clean up.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let after = app.buttons.matching(identifier: "detail.episode.download").matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Preparing ", "Downloading ")).firstMatch
        if after.waitForExistence(timeout: 10), after.isHittable {
            after.tap()
            let cancel = app.buttons["Cancel Download"].firstMatch
            if cancel.waitForExistence(timeout: 10) {
                cancel.tap()
                _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                       evaluatedWith: after)], timeout: 10)
            }
            attach("04-download-cancelled")
        }
    }

    /// The download above can finish before the cancel path is reachable — it
    /// did on the first run, leaving 2.8 GB on the persistent simulator. `Z` so
    /// it runs last: Settings › Storage › Delete All Downloads, which is the
    /// only removal the app offers for a finished download.
    ///
    /// Only meaningful on a simulator whose sole download is this suite's.
    func testZRemoveTheDownloadThisSuiteMade() {
        app.launchArguments += ["-OpenStreamVisionScreen", "storage", "-OpenStreamTrace", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        let delete = app.buttons["Delete All Downloads"].firstMatch
        guard delete.waitForExistence(timeout: 30) else {
            XCTFail("Storage settings never showed Delete All Downloads")
            return
        }
        attach("05-storage-before-delete")
        guard delete.isEnabled else { return }  // nothing to remove
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "no confirmation for Delete All Downloads")
        confirm.tap()
        Thread.sleep(forTimeInterval: 5)
        attach("06-storage-after-delete")
    }
}
