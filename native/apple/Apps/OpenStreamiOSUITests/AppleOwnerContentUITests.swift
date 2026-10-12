import XCTest
import UIKit

/// The owner's own content on DevPlus: imports their backup through Settings ›
/// Backup & Sync › Import, then checks Library (the SMB share), Live (the
/// IPTV account), Discover (the add-ons), a title page's trailer and Search.
///
/// Skipped unless the runner has `OPENSTREAM_OWNER_CONTENT=1` (pass it as
/// `TEST_RUNNER_OPENSTREAM_OWNER_CONTENT=1`). The backup file must already be
/// in the app's Documents (`devicectl device copy to --domain-type
/// appDataContainer`); its name comes from `OPENSTREAM_BACKUP_FILE` and its
/// passphrase from `OPENSTREAM_BACKUP_PASS`, never from source.
/// `OPENSTREAM_OWNER_SEARCH` is the title Search must find (default Inception).
/// Each check fails on its own and the run goes on; the imported sources stay
/// on the phone. The run script reads `first frame` lines from the device trace.
@MainActor
final class AppleOwnerContentUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        guard environment["OPENSTREAM_OWNER_CONTENT"] == "1" else {
            throw XCTSkip("Owner content checks run only with OPENSTREAM_OWNER_CONTENT=1 on DevPlus.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
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
        super.tearDown()
    }

    func testAImportTheOwnerBackup() throws {
        let file = environment["OPENSTREAM_BACKUP_FILE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "OpenStream-owner-backup.json"
        guard let passphrase = environment["OPENSTREAM_BACKUP_PASS"], !passphrase.isEmpty else {
            throw XCTSkip("OPENSTREAM_BACKUP_PASS not set")
        }
        launch(["-OpenStreamVisionScreen", "backup"])
        let importButton = app.buttons["backup.import"].firstMatch
        guard check(importButton.waitForExistence(timeout: 30), "a-no-import", "no Import Configuration… on Backup & Sync") else { return }
        attach("a-backup-page")
        importButton.tap()

        // The Files picker: Browse › On My iPhone › oStream › the file.
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
        attach("a-files-picker")
        guard check(entry.waitForExistence(timeout: 15), "a-no-file", "the backup is not in On My iPhone › oStream") else { return }
        entry.tap()

        let field = app.secureTextFields["backup.import.passphrase"].firstMatch
        guard check(field.waitForExistence(timeout: 20), "a-no-passphrase", "the import sheet asked for no passphrase") else { return }
        attach("a-import-sheet")
        field.tap()
        field.typeText(passphrase)
        app.buttons["Import"].firstMatch.tap()
        let done = app.staticTexts["Configuration imported"].firstMatch
        let imported = done.waitForExistence(timeout: 60)
        attach("a-imported")
        check(imported, "a-import-failed", "no \"Configuration imported\" after Import")
        check(!app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "backup.signIn.")).firstMatch.exists,
              "a-needs-sign-in", "some imported sources still need sign-in")
    }

    /// Library lists titles from the share and plays one to a first frame.
    func testBLibraryPlaysAShareTitle() {
        launch([])
        tab("Library")
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                     "library.title.", "home.media.")).firstMatch
        // The first scan of a large share takes a while.
        guard check(title.waitForExistence(timeout: 240), "b-no-library-titles", "Library shows no titles from the share") else { return }
        Thread.sleep(forTimeInterval: 3)
        attach("b-library")
        title.tap()
        let play = app.buttons["detail.play"].firstMatch
        guard check(play.waitForExistence(timeout: 30), "b-no-title-page", "the Library title page has no Play") else { return }
        attach("b-library-title")
        play.tap()
        chooseFirstSourceIfAsked()
        Thread.sleep(forTimeInterval: 15)
        attach("b-library-playing-15s")
        check(!playbackFailed(), "b-playback-failed", "Library playback failed: \(alertText())")
        closePlayer()
    }

    /// Live lists the provider's channels, plays one, then zaps to the next.
    func testCLivePlaysAndZaps() {
        launch([])
        tab("Live")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != %@", "Play ", "Play preview"))
        guard check(rows.firstMatch.waitForExistence(timeout: 120), "c-no-channels", "Live lists no channels") else { return }
        Thread.sleep(forTimeInterval: 3)
        attach("c-live-list")
        print("OWNER-CONTENT live rows visible=\(rows.count)")
        rows.firstMatch.tap()
        let player = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Live player for")).firstMatch
        guard check(player.waitForExistence(timeout: 30), "c-no-player", "no live player after tapping a channel") else { return }
        // Past the 10 s live deadline and its one extension for a channel
        // that is open but slow to its first segment (build 16: the owner's
        // channels started at ~11-16 s and were all cut at 10 s, which read as
        // a pass here until the player said whether it was playing).
        let first = player.label
        let playing = NSPredicate(format: "value == %@", "Playing")
        let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: player)], timeout: 30) == .completed
        attach("c-live-playing")
        check(started, "c-not-playing", "the live channel did not start within 30 s (\(player.value as? String ?? "-"))")
        check(!playbackFailed(), "c-playback-failed", "live playback failed: \(alertText())")

        player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92))
            .press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: player)
        let zapped = XCTWaiter.wait(for: [changed], timeout: 15) == .completed
        let zappedPlaying = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: player)], timeout: 30) == .completed
        attach("c-live-after-zap")
        check(zapped, "c-no-zap", "a swipe up did not change the channel")
        check(zappedPlaying, "c-zap-not-playing", "the next channel did not start within 30 s")
        check(!playbackFailed(), "c-zap-failed", "live playback failed after the zap: \(alertText())")
        closePlayer()
    }

    /// Discover's rows load from the add-ons; a title page shows its trailer.
    func testDDiscoverRowsAndTrailer() {
        launch([])
        tab("Discover")
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.media.")).firstMatch
        guard check(poster.waitForExistence(timeout: 90), "d-no-rows", "Discover shows no posters") else { return }
        Thread.sleep(forTimeInterval: 5)
        let shelves = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "discover.shelf.")).count
        print("OWNER-CONTENT discover shelves=\(shelves)")
        attach("d-discover")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        attach("d-discover-scrolled")
        app.swipeDown()

        let details = app.buttons["home.featured.details"].firstMatch
        if details.waitForExistence(timeout: 10), details.isHittable { details.tap() } else { poster.tap() }
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
        guard check(page.waitForExistence(timeout: 30), "d-no-title-page", "no title page from Discover") else { return }
        let trailer = app.buttons["detail.trailer.mute"].firstMatch.waitForExistence(timeout: 30)
        attach("d-title-trailer")
        check(trailer, "d-no-trailer", "the title page showed no trailer within 30 s")
    }

    /// The title page's trailer stays on screen once it has appeared, and a
    /// second Trailers card switches the hero to that trailer and keeps it
    /// playing (build 16 on the owner's iPhone: the trailer flashed for a
    /// split second and went back to the art; a card press often played
    /// nothing). `detail.trailer.toggle` is an element only while the video is
    /// on screen; its value says whether it is still playing.
    func testFTitleTrailerKeepsPlaying() {
        // `OPENSTREAM_TRAILER_LAUNCH_ARGS`: extra launch arguments, e.g. a Debug
        // build's `-OpenStreamDebugDetailsDelay 6` (slow-network metadata).
        launch(environment["OPENSTREAM_TRAILER_LAUNCH_ARGS"]?.split(separator: " ").map(String.init) ?? [])
        tab("Discover")
        let details = app.buttons["home.featured.details"].firstMatch
        guard check(details.waitForExistence(timeout: 90), "f-no-hero", "Discover shows no hero") else { return }
        Thread.sleep(forTimeInterval: 2)
        details.tap()
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
        guard check(page.waitForExistence(timeout: 30), "f-no-title-page", "no title page from Discover") else { return }
        let toggle = app.buttons["detail.trailer.toggle"].firstMatch
        guard check(trailerIsPlaying(toggle, within: 45), "f-no-trailer", "the title page's trailer never came on screen")
        else { return }
        attach("f-trailer-on")
        Thread.sleep(forTimeInterval: 10)
        attach("f-trailer-10s")
        check(toggle.exists && toggle.value as? String == "Playing", "f-trailer-gone",
              "the trailer did not stay on screen for 10 s (value \(toggle.exists ? String(describing: toggle.value) : "gone"))")

        // The Trailers shelf, below the fold.
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                     "detail.trailer.", "Play Trailer"))
        scrollIntoView(cards.element(boundBy: 0))
        let count = cards.count
        print("OWNER-CONTENT trailer cards=\(count)")
        guard count >= 2 else {
            print("OWNER-CONTENT this title has \(count) trailer card(s); the shelf switch was not checked")
            return
        }
        // The second card: the one next to the hero's own trailer. (A third
        // sits off the side of the shelf, where XCUITest reads a stale frame
        // for the lazily built card once the press has scrolled the page.)
        for index in 1..<2 {
            let card = cards.element(boundBy: index)
            scrollIntoView(card)
            let key = card.identifier
            let label = card.label
            print("OWNER-CONTENT pressing \(key)")
            card.tap()
            // The press scrolls back up to the hero; the old trailer goes and
            // the pressed one comes on.
            // (The swap itself takes ~1.5 s behind the art, too quick for
            // XCUITest to see reliably; the device trace records it.)
            guard check(trailerIsPlaying(toggle, within: 30), "f-card\(index)-no-trailer",
                        "pressing \(label) played nothing") else { return }
            attach("f-card\(index)-on")
            Thread.sleep(forTimeInterval: 10)
            attach("f-card\(index)-10s")
            check(toggle.exists && toggle.value as? String == "Playing", "f-card\(index)-gone",
                  "the trailer from \(label) did not keep playing for 10 s")
            check(app.buttons[key].firstMatch.exists, "f-card\(index)-dropped",
                  "\(label)'s card left the shelf, as a failed key does")
        }
    }

    /// Search finds a known title.
    func testESearchFindsAKnownTitle() {
        let query = environment["OPENSTREAM_OWNER_SEARCH"].flatMap { $0.isEmpty ? nil : $0 } ?? "Inception"
        launch([])
        tab("Discover")
        let search = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).allElementsBoundByIndex
            .first { $0.isHittable }
        guard check(search != nil, "e-no-search", "Discover has no Search") else { return }
        search?.tap()
        let field = app.searchFields.firstMatch
        guard check(field.waitForExistence(timeout: 10), "e-no-field", "no search field") else { return }
        field.tap()
        field.typeText(query)
        let hit = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (elementType == %d)", query, XCUIElement.ElementType.searchField.rawValue))
            .firstMatch
        let found = hit.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 2)
        attach("e-search-results")
        check(found, "e-not-found", "Search found nothing for \(query)")
    }

    /// devicectl cannot delete a file, so the backup copy leaves the phone
    /// through the Files app: On My iPhone › oStream, then Recently Deleted.
    func testZRemoveTheBackupFile() {
        let stem = ((environment["OPENSTREAM_BACKUP_FILE"] ?? "OpenStream-owner-backup.json") as NSString).deletingPathExtension
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        func tapLabel(_ label: String) {
            let element = files.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                .allElementsBoundByIndex.first { $0.isHittable }
            if let element { element.tap(); Thread.sleep(forTimeInterval: 1.5) }
        }
        let entry = files.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
        func deleteEntry(confirm labels: [String]) -> Bool {
            guard entry.waitForExistence(timeout: 8) else { return false }
            entry.press(forDuration: 1.2)
            let delete = files.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Delete", "Delete Now"])).firstMatch
            guard delete.waitForExistence(timeout: 5) else { return false }
            delete.tap()
            let confirm = files.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
            Thread.sleep(forTimeInterval: 2)
            return true
        }
        for step in ["Browse", "Browse", "On My iPhone", "oStream"] where !entry.exists { tapLabel(step) }
        attach("z-files-before")
        check(deleteEntry(confirm: ["Delete"]), "z-not-deleted", "could not delete the backup in On My iPhone › oStream")
        check(!entry.waitForExistence(timeout: 3), "z-still-listed", "the backup is still in oStream's folder")
        for step in ["Browse", "Browse", "Recently Deleted"] { tapLabel(step) }
        attach("z-recently-deleted")
        if entry.waitForExistence(timeout: 5) {
            check(deleteEntry(confirm: ["Delete", "Delete Now"]), "z-not-purged", "could not purge it from Recently Deleted")
        }
        attach("z-files-after")
        check(!entry.waitForExistence(timeout: 3), "z-still-in-trash", "the backup is still in Recently Deleted")
        files.terminate()
    }

    // MARK: Helpers

    private func launch(_ extra: [String]) {
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamTraceConsole", "YES",
                               "-OpenStreamMuteAudio", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 2) { notNow.tap() }
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name].firstMatch
        if button.waitForExistence(timeout: 20) { button.tap() } else { XCTFail("no \(name) tab") }
    }

    /// A title with several files or sources may ask which one to play.
    private func chooseFirstSourceIfAsked() {
        let quality = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.quality.")).firstMatch
        if quality.waitForExistence(timeout: 4), quality.isHittable { quality.tap() }
    }

    /// Swipes the page up until `element`'s row is on screen (at most 8
    /// swipes); a card off to the side of its shelf is the shelf's to scroll.
    private func scrollIntoView(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && onScreen(element, vertically: true)) { app.swipeUp() }
    }

    /// On screen by its frame: `isHittable` fails outright on a lazily built
    /// card that is off screen.
    private func onScreen(_ element: XCUIElement, vertically: Bool = false) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame, window = app.windows.firstMatch.frame
        guard !frame.isEmpty else { return false }
        return vertically ? (window.minY...window.maxY).contains(frame.midY)
            : window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Whether the hero's trailer is on screen and playing within `timeout`.
    private func trailerIsPlaying(_ toggle: XCUIElement, within timeout: TimeInterval) -> Bool {
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "Playing"),
                                                object: toggle)
        return XCTWaiter.wait(for: [playing], timeout: timeout) == .completed
    }

    private func playbackFailed() -> Bool {
        let alert = app.alerts.firstMatch
        if alert.exists && alert.label.localizedCaseInsensitiveContains("fail") { return true }
        // A live channel that will not play says so inside the picture.
        return app.descendants(matching: .any).matching(identifier: "live.failure").firstMatch.exists
    }

    private func alertText() -> String {
        let card = app.descendants(matching: .any).matching(identifier: "live.failure").firstMatch
        let source = card.exists ? card : app.alerts.firstMatch
        return source.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ")
    }

    private func closePlayer() {
        let close = app.descendants(matching: .any).matching(identifier: "player.close").firstMatch
        if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        if close.waitForExistence(timeout: 3) { close.tap() }
    }

    /// Fails with a screenshot of the moment; returns `condition`.
    @discardableResult
    private func check(_ condition: Bool, _ shot: String, _ message: String) -> Bool {
        guard !condition else { return true }
        attach(shot)
        XCTFail(message)
        return false
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
