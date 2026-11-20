import XCTest
import UIKit

/// Screen captures for a UX review (owner's iOS 18 list, 2026-10-09): each
/// test drives one screen and writes full-size PNGs to `OPENSTREAM_UX_CAPTURE_DIR`
/// (a host path the simulator runner can write to). The host records video
/// around a run with `simctl io recordVideo` where motion matters.
///
/// Skipped unless the runner has `OPENSTREAM_UX_CAPTURE=1` (pass it as
/// `TEST_RUNNER_OPENSTREAM_UX_CAPTURE=1`). Extra launch arguments come from
/// `OPENSTREAM_UX_CAPTURE_ARGS` (space-separated). The app is launched with
/// `-OpenStreamMuteAudio YES` unless `OPENSTREAM_UX_CAPTURE_SOUND=1`, which the
/// trailer-sound check needs (the page would otherwise mute itself).
/// `testA0Import` imports a passphrase backup the way `AppleOwnerContentUITests`
/// does; the passphrase comes from `OPENSTREAM_BACKUP_PASS`, never from source.
@MainActor
final class AppleUXCaptureUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    private var outDir: URL?
    private var prefix = "capture"

    override func setUpWithError() throws {
        guard environment["OPENSTREAM_UX_CAPTURE"] == "1" else {
            throw XCTSkip("UX captures run only with OPENSTREAM_UX_CAPTURE=1.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1200
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        if let dir = environment["OPENSTREAM_UX_CAPTURE_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outDir = url
        }
        prefix = environment["OPENSTREAM_UX_CAPTURE_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "capture"
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Don’t Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testA0Import() throws {
        let file = environment["OPENSTREAM_BACKUP_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "OpenStream-owner-backup.json"
        guard let passphrase = environment["OPENSTREAM_BACKUP_PASS"], !passphrase.isEmpty else {
            throw XCTSkip("OPENSTREAM_BACKUP_PASS not set")
        }
        launch(["-OpenStreamVisionScreen", "backup"])
        let importButton = app.buttons["backup.import"].firstMatch
        guard importButton.waitForExistence(timeout: 30) else { return XCTFail("no Import on Backup & Sync") }
        importButton.tap()
        let stem = (file as NSString).deletingPathExtension
        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier BEGINSWITH %@", stem, stem)).firstMatch
        if !entry.waitForExistence(timeout: 8) {
            for step in ["Browse", "On My iPhone", "oStream"] {
                let button = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", step))
                    .allElementsBoundByIndex.first { $0.isHittable }
                if let button { button.tap(); Thread.sleep(forTimeInterval: 1.5) }
                if entry.exists { break }
            }
        }
        guard entry.waitForExistence(timeout: 15) else { return XCTFail("the backup is not in the app's folder") }
        entry.tap()
        let field = app.secureTextFields["backup.import.passphrase"].firstMatch
        guard field.waitForExistence(timeout: 20) else { return XCTFail("the import sheet asked for no passphrase") }
        field.tap()
        field.typeText(passphrase)
        app.buttons["Import"].firstMatch.tap()
        let imported = app.staticTexts["Configuration imported"].firstMatch.waitForExistence(timeout: 90)
        print("UXCAPTURE IMPORT \(imported ? "ok" : "FAILED")")
        XCTAssertTrue(imported, "no \"Configuration imported\" after Import")
        // Let the preferences reach disk before the runner kills the app.
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
    }

    /// Live: the top, three slow scrolls of the guide, then a channel inline
    /// and in the full-screen player with its controls up.
    func testB1Live() {
        launch(["-OpenStreamVisionScreen", "live"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Play ", "Play preview")).firstMatch
        let failure = app.descendants(matching: .any).matching(identifier: "live.sourceError").firstMatch
        _ = row.waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 4)
        shot("live-top")
        if failure.exists { print("UXCAPTURE LIVE source error: \(failure.label)") }
        let window = app.windows.firstMatch
        for index in 1...3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.6)
            shot("live-scrolled-\(index)")
        }
        for _ in 0..<3 { app.swipeDown(); Thread.sleep(forTimeInterval: 0.4) }
        Thread.sleep(forTimeInterval: 1)
        guard row.exists else { return print("UXCAPTURE LIVE no channel rows") }
        row.tap()
        Thread.sleep(forTimeInterval: 12)
        shot("live-playing-inline")
        revealControls()
        shot("live-inline-controls")
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        if fullScreen.exists, fullScreen.isHittable {
            fullScreen.tap()
            Thread.sleep(forTimeInterval: 4)
            shot("live-fullscreen")
            revealControls()
            shot("live-fullscreen-controls")
        } else {
            print("UXCAPTURE LIVE no hittable player.fullscreen")
        }
    }

    /// Live items from the owner's narrated recording (2026-10-15): the top, the playing row, the
    /// category tabs (their names are logged), then the guide sheet scrolled.
    func testC1LiveNarration() {
        launch(["-OpenStreamVisionScreen", "live"])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Play ", "Play preview")).firstMatch
        _ = row.waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 4)
        shot("live-top")
        let tabs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "live.category.")).allElementsBoundByIndex
        print("UXCAPTURE LIVE tabs: \(tabs.map(\.identifier).joined(separator: ", "))")
        // Tapping the row already playing opens the full-screen player instead.
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@ AND selected == false",
            "Play ", "Play preview")).firstMatch
        guard other.exists else { return print("UXCAPTURE LIVE no other channel row") }
        other.tap()
        Thread.sleep(forTimeInterval: 10)
        shot("live-watching")
        for tab in ["Sports", "Locals", "Premium", "Pay-Per-View"] where tapCategory(tab) {
            Thread.sleep(forTimeInterval: 4)
            shot("live-tab-\(tab)")
        }
        if tapCategory("All") { Thread.sleep(forTimeInterval: 2) }
        let guide = app.buttons["live.guide"].firstMatch
        guard guide.waitForExistence(timeout: 5) else { return print("UXCAPTURE LIVE no guide button") }
        guide.tap()
        Thread.sleep(forTimeInterval: 4)
        shot("guide-top")
        let window = app.windows.firstMatch
        for index in 1...3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)),
                       withVelocity: .slow, thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 0.6)
            shot("guide-scrolled-\(index)")
        }
    }

    /// Channel Health from Settings: progress logged every 5 s until the sweep ends or 4 minutes pass.
    func testC2ChannelHealthSweep() {
        launch(["-OpenStreamVisionScreen", "settings"])
        let health = app.descendants(matching: .any).matching(identifier: "settings.health").firstMatch
        for _ in 0..<4 where !health.isHittable { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        guard health.waitForExistence(timeout: 20) else { return XCTFail("no Channel Health row") }
        health.tap()
        let check = app.buttons["settings.health.check"].firstMatch
        for _ in 0..<4 where !check.isHittable { app.swipeUp(); Thread.sleep(forTimeInterval: 0.6) }
        guard check.waitForExistence(timeout: 20), check.isEnabled else { return XCTFail("no enabled Check Channels Now") }
        check.tap()
        let start = Date()
        let summary = app.descendants(matching: .any).matching(identifier: "settings.health.summary").firstMatch
        let stop = app.buttons["settings.health.stop"].firstMatch
        var shots = 0
        while Date().timeIntervalSince(start) < 240 {
            Thread.sleep(forTimeInterval: 5)
            print(String(format: "UXCAPTURE HEALTH t=%.0f %@", Date().timeIntervalSince(start), summary.label))
            if shots < 2 { shots += 1; shot("health-\(shots)") }
            if !stop.exists { break }
        }
        shot("health-end")
    }

    /// Settings: the root page top to bottom.
    func testB2Settings() {
        launch(["-OpenStreamVisionScreen", "settings"])
        Thread.sleep(forTimeInterval: 3)
        shot("settings-top")
        for index in 1...4 {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
            shot("settings-scrolled-\(index)")
        }
    }

    /// A title page scrolled to its cast row (`-OpenStreamDetailTitle` picks it).
    func testB3Cast() {
        launch([])
        let cast = app.descendants(matching: .any).matching(identifier: "detail.cast").firstMatch
        _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            .waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 4)
        for _ in 0..<8 where !(cast.exists && cast.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        Thread.sleep(forTimeInterval: 3)
        shot("cast")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        shot("cast-below")
    }

    /// The title page's trailer: waits for it on screen, photographs it
    /// playing, taps the sound control, then pauses it with a tap.
    func testB4TitleTrailer() {
        launch([])
        let mute = app.buttons["detail.trailer.mute"].firstMatch
        let shown = mute.waitForExistence(timeout: 60)
        print("UXCAPTURE TRAILER mute control shown=\(shown)")
        Thread.sleep(forTimeInterval: 2)
        shot("trailer-playing")
        if shown, mute.isHittable {
            print("UXCAPTURE TRAILER before tap value=\(mute.value as? String ?? "?") frame=\(mute.frame)")
            mute.tap()
            Thread.sleep(forTimeInterval: 3)
            print("UXCAPTURE TRAILER after tap value=\(mute.value as? String ?? "?")")
            shot("trailer-after-sound-tap")
        }
        let toggle = app.descendants(matching: .any).matching(identifier: "detail.trailer.toggle").firstMatch
        if toggle.exists {
            toggle.tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("trailer-paused")
        } else {
            print("UXCAPTURE TRAILER no toggle")
        }
    }

    func testB5HeroAutoplay() {
        launch([])
        let toggle = app.descendants(matching: .any).matching(identifier: "detail.trailer.toggle").firstMatch
        let native = app.descendants(matching: .any).matching(identifier: "hero.serverTrailer").firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (toggle.exists && toggle.value as? String == "Playing")
                || (native.exists && native.value as? String == "playing")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 60), .completed,
            "The hero must autoplay a trailer without pressing Play Trailer")
        shot("hero-autoplay")
    }

    /// Discover's hero trailer playing, then paused by a tap.
    func testB5HeroTrailer() {
        launch([])
        Thread.sleep(forTimeInterval: 18)
        shot("hero-playing")
        let mute = app.buttons["detail.trailer.mute"].firstMatch
        if mute.exists, mute.isHittable {
            print("UXCAPTURE HERO before tap value=\(mute.value as? String ?? "?") frame=\(mute.frame)")
            mute.tap()
            Thread.sleep(forTimeInterval: 3)
            print("UXCAPTURE HERO after tap value=\(mute.value as? String ?? "?")")
            shot("hero-after-sound-tap")
        } else {
            print("UXCAPTURE HERO no hittable sound control")
        }
        let toggle = app.descendants(matching: .any).matching(identifier: "detail.trailer.toggle").firstMatch
        if toggle.exists {
            toggle.tap()
            Thread.sleep(forTimeInterval: 1.5)
            shot("hero-paused")
        } else {
            print("UXCAPTURE HERO no trailer on screen")
        }
    }

    /// Presses the first card in the title page's Trailers row (Play
    /// Trailer): the trace shows whether it starts with sound.
    func testB6PressTrailer() {
        launch([])
        let row = app.descendants(matching: .any).matching(identifier: "detail.trailers").firstMatch
        _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            .waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<4 where !(row.exists && row.isHittable) { app.swipeUp(); Thread.sleep(forTimeInterval: 1) }
        let card = row.buttons.firstMatch
        guard card.waitForExistence(timeout: 10) else { return print("UXCAPTURE PRESS no trailer card") }
        card.tap()
        Thread.sleep(forTimeInterval: 10)
        let mute = app.buttons["detail.trailer.mute"].firstMatch
        print("UXCAPTURE PRESS sound control value=\(mute.exists ? (mute.value as? String ?? "?") : "absent")")
        shot("pressed-trailer")
    }

    /// The portrait hero (owner items 6 and 19): each page of Discover's or
    /// Library's carousel, swiped through one by one. The tab comes from
    /// `OPENSTREAM_UX_CAPTURE_TAB` (Discover by default), the number of pages
    /// from `OPENSTREAM_UX_CAPTURE_PAGES` (8 by default).
    func testB7HeroPages() {
        if environment["OPENSTREAM_UX_CAPTURE_STILLS"] == "1" {
            app.launchArguments = ["-OpenStreamVisionScreen", "playback-settings", "-OpenStreamMuteAudio", "YES"]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            let autoplay = app.switches["Auto Play Trailer"].firstMatch
            scrollToControl(autoplay, in: app)
            XCTAssertTrue(autoplay.exists)
            if autoplay.value as? String == "1" { autoplay.switches.firstMatch.tap() }
            XCTAssertEqual(autoplay.value as? String, "0")
        }
        let tab = environment["OPENSTREAM_UX_CAPTURE_TAB"].flatMap { $0.isEmpty ? nil : $0 } ?? "Discover"
        let pages = environment["OPENSTREAM_UX_CAPTURE_PAGES"].flatMap(Int.init) ?? 8
        launch([])
        if tab != "Discover" {
            let button = app.tabBars.buttons[tab].firstMatch
            if button.waitForExistence(timeout: 20) { button.tap() } else { print("UXCAPTURE HERO no \(tab) tab") }
        }
        let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
        print("UXCAPTURE HERO \(tab) shown=\(details.waitForExistence(timeout: 60))")
        Thread.sleep(forTimeInterval: 8)
        let slug = tab.lowercased()
        shot("\(slug)-hero-01")
        if environment["OPENSTREAM_UX_CAPTURE_DETAILS"] == "1" {
            details.tap()
            XCTAssertTrue(app.buttons["detail.back"].firstMatch.waitForExistence(timeout: 30))
            if let expectedID = environment["OPENSTREAM_UX_CAPTURE_ITEM_ID"] {
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "detail.screen.\(expectedID)")
                    .firstMatch.waitForExistence(timeout: 30))
            }
            Thread.sleep(forTimeInterval: 3)
            shot("\(slug)-title-page")
            app.buttons["detail.back"].firstMatch.tap()
            XCTAssertTrue(details.waitForExistence(timeout: 30))
            XCTAssertFalse(app.buttons["detail.back"].firstMatch.exists)
            return
        }
        let window = app.windows.firstMatch
        for page in 2...max(pages, 2) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 3)
            print("UXCAPTURE HERO \(tab) page \(page): \(details.exists ? details.label : "?")")
            shot(String(format: "%@-hero-%02d", slug, page))
        }
    }

    /// Discover's hero as the owner used it on iOS 18 (trace iphone-1017b):
    /// 30 s untouched (the cycle should move on by itself), small drags that
    /// collapse and expand the bar, then three swipes through the pages. The
    /// host records video around it and counts the trace's `hero drawn` and
    /// `hero cycle` lines.
    func testB8DiscoverJank() {
        launch([])
        let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
        print("UXCAPTURE JANK shown=\(details.waitForExistence(timeout: 60)) t=\(Date().timeIntervalSince1970)")
        shot("jank-00-rest")
        Thread.sleep(forTimeInterval: 30)
        shot("jank-01-after-30s")
        let window = app.windows.firstMatch
        for (step, dy) in [(2, 0.12), (3, -0.12), (4, 0.2), (5, -0.2)].map({ ($0.0, CGFloat($0.1)) }) {
            print("UXCAPTURE JANK drag \(step) t=\(Date().timeIntervalSince1970)")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 - dy)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1.5)
            shot(String(format: "jank-%02d-drag", step))
        }
        for step in 6...8 {
            print("UXCAPTURE JANK swipe \(step) t=\(Date().timeIntervalSince1970)")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.33)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 2)
            shot(String(format: "jank-%02d-swipe", step))
        }
        Thread.sleep(forTimeInterval: 15)
        shot("jank-09-end")
    }

    func testB8LandingChrome() throws {
        for page in ["discover", "library"] {
            launch(["-OpenStreamVisionScreen", page, "-OpenStreamDiscoverScrollY", "0"])
            let hero = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 60), "\(page) hero must be present")
            let compact = app.staticTexts["\(page).compact-title"].firstMatch
            XCTAssertFalse(compact.exists, "\(page) must have no compact title at rest")
            XCTAssertTrue(app.buttons["Search"].firstMatch.isHittable)
            XCTAssertTrue(app.buttons["Refresh"].firstMatch.isHittable)
            shot("chrome-\(page)-rest")
            for _ in 0..<4 where !compact.exists { app.swipeUp() }
            XCTAssertTrue(compact.waitForExistence(timeout: 5), "\(page) title must appear after the hero")
            XCTAssertTrue(app.buttons["Search"].firstMatch.isHittable)
            XCTAssertTrue(app.buttons["Refresh"].firstMatch.isHittable)
            shot("chrome-\(page)-scrolled")
            let windowHeight = app.windows.firstMatch.frame.height
            let row = app.scrollViews.allElementsBoundByIndex.first { row in
                let frame = row.frame
                return frame.height > 60 && frame.height < windowHeight / 2
                    && frame.width > app.windows.firstMatch.frame.width / 2
                    && frame.minY > compact.frame.maxY && frame.maxY < windowHeight - 90
            }
            let posterRow = try XCTUnwrap(row, "\(page) needs a visible horizontal shelf")
            for direction in [true, false, true] {
                if direction { posterRow.swipeLeft() } else { posterRow.swipeRight() }
                XCTAssertTrue(compact.exists, "\(page) title must remain while swiping a shelf")
                shot("chrome-\(page)-row-\(direction ? "left" : "right")")
            }
        }
        launch(["-OpenStreamVisionScreen", "discover", "-OpenStreamReviewDiscoverLoading", "YES"])
        XCTAssertTrue(app.staticTexts["discover.compact-title"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Search"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Refresh"].firstMatch.isHittable)
        shot("chrome-discover-without-hero")
    }

    func testB8LandingWithoutHero() throws {
        for page in ["discover", "library"] {
            app.terminate()
            app.launchArguments = ["-OpenStreamStubNetwork", Self.stubDirectory, "-OpenStreamTrace", "YES",
                "-OpenStreamMuteAudio", "YES", "-OpenStreamVisionScreen", page]
            app.launch()
            let compact = app.staticTexts["\(page).compact-title"].firstMatch
            XCTAssertTrue(compact.waitForExistence(timeout: 30))
            let title = page == "discover" ? "Recently Added" : "Movies"
            let heading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 60), "\(page) needs its populated shelf heading")
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch.exists)
            let headingFrame = try XCTUnwrap((try? heading.snapshot())?.frame)
            let controlsBottom = app.buttons["\(page).compact-title.search"].firstMatch.frame.maxY
            XCTAssertGreaterThanOrEqual(headingFrame.minY, controlsBottom,
                "\(page)'s first shelf heading must clear the compact bar")
            shot("chrome-\(page)-populated-without-hero")
        }
    }

    /// Spec S3 G12: the title page from the top to its last section, a frame
    /// per screen, with which section headings and lines are on it. Open a
    /// title with `OPENSTREAM_UX_CAPTURE_ARGS="-OpenStreamVisionScreen detail-movie"`.
    func testB9TitlePageSections() {
        launch([])
        _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen."))
            .firstMatch.waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 4)
        for screen in 0..<8 {
            shot(String(format: "title-%02d", screen))
            let texts = ["More Like This", "Related", "Accessibility", "Episodes aren’t available from the connected metadata sources."]
                .filter { app.staticTexts[$0].exists }
            print("UXCAPTURE TITLE screen \(screen): \(texts)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) {
        app.terminate()
        var arguments = ["-OpenStreamTrace", "YES"]
        if environment["OPENSTREAM_UX_CAPTURE_SOUND"] != "1" { arguments += ["-OpenStreamMuteAudio", "YES"] }
        let passed = environment["OPENSTREAM_UX_CAPTURE_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? []
        app.launchArguments = arguments + extra + passed
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    /// Scrolls the Live category bar until the chip is on screen, then taps it.
    private func tapCategory(_ name: String) -> Bool {
        let chip = app.descendants(matching: .any).matching(identifier: "live.category.\(name)").firstMatch
        let bar = app.descendants(matching: .any).matching(identifier: "live.categories").firstMatch
        guard chip.exists, bar.exists else { return false }
        let screen = app.windows.firstMatch.frame
        for attempt in 0..<8 where !screen.contains(chip.frame) {
            if attempt < 4, chip.frame.minX > screen.midX { bar.swipeLeft() } else { bar.swipeRight() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard screen.contains(chip.frame) else { print("UXCAPTURE LIVE \(name) stayed off screen"); return false }
        chip.tap()
        return true
    }

    private func revealControls() {
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if close.exists && close.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func shot(_ what: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let name = "\(prefix)-\(what)"
        print("UXCAPTURE SHOT \(name) t=\(Date().timeIntervalSince1970)")
        if let outDir, (try? screenshot.pngRepresentation.write(to: outDir.appendingPathComponent(name + ".png"))) != nil {
            return
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
