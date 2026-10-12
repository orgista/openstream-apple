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
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
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
