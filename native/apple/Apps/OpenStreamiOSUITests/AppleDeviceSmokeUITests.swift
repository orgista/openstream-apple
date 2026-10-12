import XCTest
import UIKit

/// Smoke checks that only a real iPhone answers: the trailer reveal path
/// that exists only on hardware (43feec0), Live zapping with a finger, the
/// pasteboard's Open Copied Link, and the system share sheet hand-off.
///
/// Skipped unless the runner has `OPENSTREAM_DEVICE_SMOKE=1` (pass it as
/// `TEST_RUNNER_OPENSTREAM_DEVICE_SMOKE=1`). Inputs come from the environment,
/// never from source: `OPENSTREAM_SMOKE_M3U` (a playlist URL of Apple's public
/// HLS samples) and `OPENSTREAM_DEMO_URL/USER/PASS` (the LAN demo Jellyfin).
/// The test runner cannot read the app's trace on a device; the run script
/// pulls `Library/Caches/openstream-trace.log` with `devicectl` afterwards.
/// Each test removes whatever it added.
@MainActor
final class AppleDeviceSmokeUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    private static let maydayURL = "https://tv.apple.com/us/movie/mayday/umc.cmc.shin43vzfoz3h4ggx41z8rf"
    private static let playlistName = "Device Smoke Playlist"

    override func setUpWithError() throws {
        guard environment["OPENSTREAM_DEVICE_SMOKE"] == "1" else {
            throw XCTSkip("Device smoke tests run only with OPENSTREAM_DEVICE_SMOKE=1 on DevPlus.")
        }
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    override func tearDown() {
        app?.terminate()
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").terminate()
        super.tearDown()
    }

    // MARK: a. Trailer

    /// Adds the demo server and watches the Discover billboard for 10 s, then
    /// opens a title that has a trailer (Mayday, through the app's own shared
    /// link URL) and waits 10 s on its page. The demo server's open movies
    /// carry no trailer, so the title page is the one that proves the device
    /// path. The run script asserts `trailer native reveal: live viewport
    /// (device, unmeasured)` and `trailer cover fading out` in the trace.
    func testATrailerRevealsTheLiveVideoOnDevice() throws {
        try addDemoServer()
        app.tabBars.buttons["Discover"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 10)
        attach("a-trailer-discover-hero")
        app.open(Self.sharedLinkURL(Self.maydayURL))
        let page = app.buttons["detail.play"].firstMatch
        check(page.waitForExistence(timeout: 30), "a-no-title-page", "Mayday's title page never opened")
        Thread.sleep(forTimeInterval: 10)
        attach("a-trailer-title-page-10s")
    }

    // MARK: b. Live

    /// Adds the sample playlist, plays a channel, swipes up for the next one
    /// and uses Last Channel to go back. The run script reads the channel
    /// names and `first frame` lines from the trace.
    func testBLiveSwipeAndLastChannel() throws {
        guard let playlist = environment["OPENSTREAM_SMOKE_M3U"], !playlist.isEmpty else {
            throw XCTSkip("OPENSTREAM_SMOKE_M3U not set")
        }
        addTeardownBlock { [self] in removeSource(matching: Self.playlistName) }
        addPlaylist(playlist)
        app.tabBars.buttons["Live"].firstMatch.tap()
        let channel = app.buttons["Play Smoke Apple fMP4"].firstMatch
        check(channel.waitForExistence(timeout: 30), "b-no-channel-row", "sample channel not listed on Live")
        channel.tap()
        let player = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Live player for")).firstMatch
        func playing(_ name: String) -> Bool {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Live player for \(name)"), object: player)
            return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
        }
        check(playing("Smoke Apple fMP4"), "b-not-playing", "the tapped channel is not the one playing")
        Thread.sleep(forTimeInterval: 6)
        attach("b-live-first-channel")
        check(!app.alerts.firstMatch.exists, "b-alert", "alert after starting the channel")

        // A vertical swipe over the video changes channel; up is next (16x9, fMP4, TS).
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
            .press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        check(playing("Smoke Apple TS"), "b-swipe-no-change", "swipe up did not move to the next channel: \(player.label)")
        Thread.sleep(forTimeInterval: 6)
        attach("b-live-after-swipe-next")

        // A swipe must change the channel and nothing else. The video area is
        // the transport's "show channels" Button, which used to fire on the
        // same touch and open the channel list (DevPlus, 2026-10-06); the
        // swipe now takes priority over that tap.
        let pickerClose = app.descendants(matching: .any).matching(identifier: "live.picker.close").firstMatch
        let last = app.descendants(matching: .any).matching(identifier: "live.player.lastChannel").firstMatch
        if pickerClose.waitForExistence(timeout: 1.5) {
            attach("b-list-opened-by-swipe")
            check(false, "b-swipe-opened-list", "the channel swipe also opened the Channels list")
            pickerClose.tap()
        }
        if !last.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if pickerClose.waitForExistence(timeout: 2) {
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Smoke Apple TS")).firstMatch.tap()
            }
        }
        check(last.waitForExistence(timeout: 5), "b-no-last-channel", "no Last Channel control")
        attach("b-live-last-channel-control")
        last.tap()
        check(playing("Smoke Apple fMP4"), "b-last-no-change", "Last Channel did not go back: \(player.label)")
        Thread.sleep(forTimeInterval: 6)
        attach("b-live-after-last-channel")
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if close.exists { close.tap() }
    }

    // MARK: c. Open Copied Link

    /// Copies the link the way a viewer does — Safari's share sheet, Copy —
    /// because a pasteboard write from the background test runner never
    /// reaches other apps on a device.
    func testCOpenCopiedLinkOpensTheTitle() throws {
        let safari = shareFromSafari()
        let copy = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        check(copy.waitForExistence(timeout: 5), "c-no-copy", "no Copy in Safari's share sheet")
        copy.tap()
        Thread.sleep(forTimeInterval: 1)
        safari.terminate()
        launch(["-OpenStreamVisionScreen", "search"])
        let button = app.descendants(matching: .any).matching(identifier: "search.openCopiedLink").firstMatch
        check(button.waitForExistence(timeout: 15), "c-no-button", "no Open Copied Link with a tv.apple.com URL copied")
        attach("c-copied-link-button")
        button.tap()
        let outcome = waitForSharedLinkOutcome()
        attach("c-copied-link-\(outcome)")
        XCTAssertNotEqual(outcome, "nothing", "Open Copied Link opened neither a title page nor Search")
    }

    // MARK: d. Share sheet

    /// Safari → Share → oStream. Records which path happened as an attachment
    /// name: `d-handoff-immediate` (oStream came forward by itself) or
    /// `d-handoff-fallback` (it had to be brought forward).
    func testDShareSheetHandsTheLinkToOStream() throws {
        launch([])
        let safari = shareFromSafari()
        let sheet = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func ourApp() -> XCUIElement {
            for host in [safari, sheet] {
                let match = host.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "oStream")).firstMatch
                if match.exists { return match }
            }
            return safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "oStream")).firstMatch
        }
        Thread.sleep(forTimeInterval: 2)
        attach("d-share-sheet")
        var target = ourApp()
        var swipes = 0
        let row = safari.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Messages", "Mail", "AirDrop"])).firstMatch
        while !target.exists, swipes < 5, row.exists {
            // The app row scrolls sideways; its last cell is "More".
            let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.withOffset(CGVector(dx: 200, dy: 0))
                .press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -100, dy: 0)))
            swipes += 1; Thread.sleep(forTimeInterval: 0.8); target = ourApp()
        }
        if !target.exists {
            let more = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "More")).firstMatch
            if more.exists { more.tap(); Thread.sleep(forTimeInterval: 1.5); target = ourApp() }
        }
        attach("d-share-sheet-app-row")
        check(target.exists, "d-no-app", "oStream is not in the share sheet")
        target.tap()

        let path: String
        if app.wait(for: .runningForeground, timeout: 10) {
            path = "immediate"
        } else {
            attach("d-after-share-tap")
            path = "fallback"
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "oStream did not come forward")
        }
        let outcome = waitForSharedLinkOutcome()
        attach("d-handoff-\(path)-\(outcome)")
        XCTAssertNotEqual(outcome, "nothing", "the shared link opened neither a title page nor Search (\(path) path)")
    }

    // MARK: Helpers

    /// The app's own hand-off URL, the one the share extension opens.
    private static func sharedLinkURL(_ link: String) -> URL {
        var components = URLComponents(string: "openstream://open")!
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        return components.url!
    }

    /// Fails with a screenshot of the moment, not of the torn-down app.
    private func check(_ condition: Bool, _ shot: String, _ message: String) {
        guard !condition else { return }
        attach(shot)
        XCTFail(message)
    }

    /// Safari on the Mayday page with its share sheet open.
    private func shareFromSafari() -> XCUIApplication {
        XCUIDevice.shared.press(.home)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        let address = safari.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
            ["TabBarItemTitle", "URL", "Address", "UnifiedTabBarItemView"])).firstMatch
        if address.waitForExistence(timeout: 10) { address.tap() }
        else { safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap() }
        safari.typeText(Self.maydayURL + "\n")
        Thread.sleep(forTimeInterval: 6)
        attach("safari-page")
        let share = safari.buttons["ShareButton"].exists ? safari.buttons["ShareButton"] : safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 5) {
            let more = safari.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                ["More", "Page Menu", "Show Page Menu"], ["PageMenuButton", "MoreButton"])).firstMatch
            check(more.waitForExistence(timeout: 5), "safari-no-menu", "no Share or page menu in Safari")
            more.tap()
            let menuShare = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Share")).firstMatch
            check(menuShare.waitForExistence(timeout: 5), "safari-no-share", "no Share in Safari's page menu")
            menuShare.tap()
        } else { share.tap() }
        Thread.sleep(forTimeInterval: 2)
        attach("safari-share-sheet")
        return safari
    }

    private func launch(_ extra: [String]) {
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamTraceConsole", "YES",
                               "-OpenStreamMuteAudio", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// "title" (a title page), "search" (Search prefilled with the title) or "nothing".
    private func waitForSharedLinkOutcome() -> String {
        let any = app.descendants(matching: .any)
        let title = any.matching(NSPredicate(format: "identifier IN %@", ["detail.play", "detail.about", "detail.watchOn"])).firstMatch
        let field = app.searchFields.firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if title.exists { Thread.sleep(forTimeInterval: 2); return "title" }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if field.exists, (field.value as? String)?.localizedCaseInsensitiveContains("Mayday") == true { return "search" }
        return "nothing"
    }

    /// Settings › Sources › Add Live TV › M3U Playlist › name + URL › Save.
    private func addPlaylist(_ playlist: String) {
        launch(["-OpenStreamVisionScreen", "add-live"])
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Xtream Account")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "no Type picker")
        picker.tap()
        let m3u = app.buttons["M3U Playlist"].firstMatch
        XCTAssertTrue(m3u.waitForExistence(timeout: 10)); m3u.tap()
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText(Self.playlistName)
        let url = app.textFields["Playlist URL"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10)); url.tap(); url.typeText(playlist)
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        attach("b-live-add-filled")
        var save = app.buttons["sources.live.save"].firstMatch
        if !save.waitForExistence(timeout: 5) { save = app.buttons["Save"].firstMatch }
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save on Add Live TV")
        save.tap()
        allowSystemAlert()
        let live = app.tabBars.buttons["Live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 60), "Live tab not reachable after saving")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.playlistName)).firstMatch
        if !row.waitForExistence(timeout: 30) { attach("b-live-add-not-listed") }
        XCTAssertTrue(row.exists, "the playlist was not saved: \(app.descendants(matching: .any).matching(identifier: "sources.live.result").firstMatch.label)")
    }

    /// Settings › Sources › Add Media Server › Jellyfin with the demo account.
    private func addDemoServer() throws {
        guard let user = environment["OPENSTREAM_DEMO_USER"], let password = environment["OPENSTREAM_DEMO_PASS"],
              let server = environment["OPENSTREAM_DEMO_URL"],
              !user.isEmpty, !password.isEmpty, !server.isEmpty else { throw XCTSkip("OPENSTREAM_DEMO_URL/USER/PASS not set") }
        launch(["-OpenStreamVisionScreen", "add-media-server"])
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(identifier: "sources.mediaServer.kind").firstMatch.waitForExistence(timeout: 30))
        let jellyfin = any.matching(identifier: "sources.mediaServer.kind.jellyfin").firstMatch
        if jellyfin.exists { jellyfin.tap() }
        let urlField = any.matching(identifier: "sources.mediaServer.url").firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "Server URL field missing")
        urlField.tap(); urlField.typeText(server)
        let usePassword = any.matching(identifier: "sources.mediaServer.usePassword").firstMatch
        if usePassword.waitForExistence(timeout: 3) { usePassword.tap() }
        let userField = any.matching(identifier: "sources.mediaServer.username").firstMatch
        XCTAssertTrue(userField.waitForExistence(timeout: 10), "Username field missing")
        userField.tap(); userField.typeText(user)
        // The reveal button carries the same identifier; type into the secure field only.
        let passwordField = app.secureTextFields["sources.mediaServer.password"].firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10), "Password field missing")
        passwordField.tap(); passwordField.typeText(password)
        let save = any.matching(identifier: "sources.mediaServer.save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save missing")
        addTeardownBlock { [self] in removeSource(matching: "Media Server ·") }
        save.tap()
        allowSystemAlert()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Media Server ·")).firstMatch
        let listed = row.waitForExistence(timeout: 45)
        attach("a-media-server-saved")
        XCTAssertTrue(listed, "demo server not listed: \(any.matching(identifier: "sources.mediaServer.status").firstMatch.label)")
    }

    /// Answers a system prompt (Local Network) the app raised; the
    /// interruption monitor only runs on the next interaction, and a stray
    /// tap on the app lands on whatever row is under it.
    private func allowSystemAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        guard alert.waitForExistence(timeout: 3) else { return }
        for label in ["Allow", "Allow While Using App", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    /// Relaunches on Settings › Sources and deletes every row whose label contains `fragment`.
    private func removeSource(matching fragment: String) {
        app.terminate()
        launch(["-OpenStreamVisionScreen", "settings"])
        let sources = app.buttons["Sources"].firstMatch
        guard sources.waitForExistence(timeout: 20) else { attach("cleanup-no-sources-row"); return }
        sources.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", fragment)).firstMatch
        for _ in 0..<3 {
            var swipes = 0
            while !row.waitForExistence(timeout: 3), swipes < 6 { app.swipeUp(); swipes += 1 }
            guard row.exists else { break }
            row.tap()
            let delete = app.buttons["Delete Source"].firstMatch
            var deleteSwipes = 0
            while !delete.exists, deleteSwipes < 4 { app.swipeUp(); deleteSwipes += 1 }
            guard delete.waitForExistence(timeout: 5) else { attach("cleanup-no-delete"); return }
            delete.tap()
            let confirm = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Delete")).firstMatch
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            Thread.sleep(forTimeInterval: 1.5)
        }
        let gone = !row.exists
        attach("cleanup-\(gone ? "removed" : "still-listed")")
        XCTAssertTrue(gone, "\(fragment) still listed after Delete")
    }
}
