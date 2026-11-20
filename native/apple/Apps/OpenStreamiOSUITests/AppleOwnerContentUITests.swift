import XCTest
import UIKit
import Vision

/// The owner's own content on a test iPhone: imports their backup through Settings ›
/// Backup & Sync › Import, then checks Library (the SMB share), Live (the
/// IPTV account), Discover (the media servers), a title page's trailer and Search.
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
            throw XCTSkip("Owner content checks run only with OPENSTREAM_OWNER_CONTENT=1 on a test iPhone.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
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

    /// Library plays a share title, saves its stop point, and resumes it.
    func testBLibraryPlaysAShareTitle() throws {
        continueAfterFailure = false
        launch([], muteAudio: false)
        tab("Library")
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                     "library.title.", "home.ms.")).firstMatch
        // The first scan of a large share takes a while.
        guard check(title.waitForExistence(timeout: 240), "b-no-library-titles", "Library shows no titles from the share") else { return }
        Thread.sleep(forTimeInterval: 3)
        attach("b-library")
        title.tap()
        let play = app.buttons["detail.play"].firstMatch
        guard check(play.waitForExistence(timeout: 30), "b-no-title-page", "the Library title page has no Play") else { return }
        attach("b-library-title")
        play.tap()
        let pause = app.buttons["player.play-pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 60), "Library player has no transport")
        XCTAssertTrue(waitForPlaying(pause), "Library title did not start")
        Thread.sleep(forTimeInterval: 20)
        revealTransport()
        XCTAssertEqual(pause.label, "Pause")
        pause.tap()
        let stopped = try XCTUnwrap(playbackSeconds(), "Library player has no elapsed time")
        attach("b-library-playing-20s")
        check(!playbackFailed(), "b-playback-failed", "Library playback failed: \(alertText())")
        closePlayer()
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 60))
        XCTAssertTrue(waitForPlaying(pause), "Library title did not resume")
        pause.tap()
        let resumed = try XCTUnwrap(playbackSeconds(), "Resumed player has no elapsed time")
        print("OWNER-CONTENT resume stopped=\(stopped)s resumed=\(resumed)s delta=\(abs(resumed - stopped))s")
        XCTAssertLessThanOrEqual(abs(resumed - stopped), 5, "Resume missed the saved stop point")
        attach("b-library-resumed")
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

    func testCLivePlaysWithAudio() {
        continueAfterFailure = false
        launch([], muteAudio: false)
        tab("Live")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "Live lists no channels")
        row.tap()
        let player = app.descendants(matching: .any)["live.stage.player"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 30))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed, "Live channel did not start")
        Thread.sleep(forTimeInterval: 20)
        XCTAssertEqual(player.value as? String, "Playing", "Live channel did not keep playing")
        XCTAssertFalse(playbackFailed())
        attach("c-live-audio-unmuted")
    }

    /// The app trace measures presentation; XCTest also waits for snapshots and idle.
    func testDLiveFirstOpenTimeToRows() {
        measureLiveRows(after: 15)
    }

    func testDLiveImmediateOpenTimeToRows() {
        measureLiveRows(after: 0)
    }

    private func measureLiveRows(after delay: TimeInterval) {
        launch([], dismissFirstRun: false)
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
        let started = Date()
        tab("Live")
        let shown = rows.firstMatch.waitForExistence(timeout: 120)
        print("OWNER-CONTENT live automation ms=\(Int(Date().timeIntervalSince(started) * 1000)) delay=\(delay)s shown=\(shown); presentation timing is in the app trace")
        attach("d-live-first-rows")
        check(shown, "d-no-rows", "Live showed no channel rows")
    }

    /// Discover shows the configured library's rows and a title page's trailer.
    func testDDiscoverRowsAndTrailer() {
        launch([])
        tab("Discover")
        let details = app.buttons["home.featured.details"].firstMatch
        guard check(details.waitForExistence(timeout: 90), "d-no-hero", "Discover shows no hero") else { return }
        attach("d-discover")
        // Shelves below the billboard are built only after scrolling.
        app.swipeUp()
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                     "library.title.", "home.ms.")).firstMatch
        scrollIntoView(poster)
        guard check(poster.exists && poster.isHittable, "d-no-rows", "Discover shows no library posters after scrolling") else { return }
        attach("d-discover-scrolled")
        for _ in 0..<8 where !details.exists || !details.isHittable { app.swipeDown() }
        guard check(details.exists && details.isHittable, "d-no-hero-return", "Discover did not return to its hero") else { return }
        details.tap()
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

    func testAbbottTrailerPlayerStaysHiddenUntilReveal() throws {
        continueAfterFailure = false
        launch(["-OpenStreamVisionScreen", "library", "-openstream.reset.cloudRestoreHeld.v1", "YES",
                "-openstream.settings.trailer.autoplay.v1", "YES"])
        let title = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'library.title.' AND label CONTAINS[c] 'Abbott Elementary'")).firstMatch
        // Scroll from the gutter so a poster cannot turn the gesture into a title tap.
        for _ in 0..<8 where !(title.exists && onScreen(title, vertically: true)) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        guard check(title.exists && onScreen(title, vertically: true), "abbott-missing",
                    "Abbott Elementary is unavailable in the local library") else { return }
        title.tap()
        let toggle = app.buttons["detail.trailer.toggle"].firstMatch
        let webPlayer = app.webViews.firstMatch
        let deadline = Date.now.addingTimeInterval(35)
        var revealed = false
        repeat {
            let sampledAt = Date.now
            var snapshots = [try app.snapshot()]
            var index = 0
            while index < snapshots.count {
                snapshots.append(contentsOf: snapshots[index].children)
                index += 1
            }
            let trailerControl = snapshots.first { $0.identifier == "detail.trailer.toggle" }
            if trailerControl?.value as? String == "Playing" {
                revealed = true
                break
            }
            let webPlayerPresent = snapshots.contains { $0.elementType == .webView }
            XCTAssertFalse(webPlayerPresent, "YouTube is exposed while the art is up")
            XCTAssertFalse(webPlayerPresent && webPlayer.isHittable, "YouTube receives taps while the art is up")
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertNil(trailerControl, "The trailer's player surface is visible before reveal")
            }
            let remaining = 0.25 - Date.now.timeIntervalSince(sampledAt)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        } while Date.now < deadline
        guard check(revealed, "abbott-trailer-missing",
                    "Abbott's trailer never came on screen") else { return }
        XCTAssertTrue(toggle.isHittable, "The revealed trailer has no visible player surface")
        attach("abbott-first-open-playing")
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format:
            "exists == false OR value != %@", "Playing"), object: toggle)
        stopped.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 12), .completed,
                       "Abbott's trailer stopped during its first twelve seconds on screen")
        attach("abbott-first-open-twelve-seconds")
    }

    func testPolishLocalSeasonUsesEpisodeTitles() throws {
        continueAfterFailure = false
        launch([])
        tab("Library")
        let title = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'library.title.' AND label CONTAINS[c] 'Abbott Elementary'")).firstMatch
        guard check(title.waitForExistence(timeout: 180), "polish-abbott-missing",
            "Abbott Elementary is unavailable in the local library") else { return }
        title.tap()
        let season = app.descendants(matching: .any).matching(identifier: "detail.season").firstMatch
        scrollToControl(season, in: app)
        XCTAssertTrue(season.waitForExistence(timeout: 30))
        if season.elementType == .button {
            season.tap()
            let sixth = app.buttons["detail.season.6"].firstMatch
            XCTAssertTrue(sixth.waitForExistence(timeout: 10))
            sixth.tap()
        } else {
            XCTAssertEqual(season.label, "Season 6")
        }
        let episodes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Play S6 E'"))
        let enriched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let labels = episodes.allElementsBoundByIndex.map(\.label)
            return !labels.isEmpty && labels.allSatisfy {
                $0.range(of: #" · Episode \d+$"#, options: .regularExpression) == nil
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enriched], timeout: 90), .completed,
            "Season 6 still has generic episode titles")
        scrollToControl(episodes.firstMatch, in: app)
        attach("polish-abbott-season6-episodes")
    }

    /// Settings › Title Page (owner 2026-10-28): with Trailers, Cast & Crew,
    /// Information and About off, a series page keeps only its hero, its
    /// buttons and Episodes. The switches go back on at the end.
    func testTitlePageSectionSwitchesLeaveHeroButtonsAndEpisodes() {
        continueAfterFailure = false
        let sections = ["detail.trailers", "detail.cast", "detail.about", "detail.information", "detail.languages"]
        guard openAbbott() else { return }
        let shownBefore = sections.filter { revealed($0) }
        attach("title-sections-all-on")
        print("OWNER-CONTENT title sections with every switch on: \(shownBefore)")
        XCTAssertFalse(shownBefore.isEmpty, "Abbott Elementary showed none of the switchable sections to begin with")

        // Registered first: a failure while switching off still switches back on.
        addTeardownBlock { [self] in setTitlePageSections(on: true) }
        setTitlePageSections(on: false)
        guard openAbbott() else { return }
        let episodes = app.descendants(matching: .any).matching(identifier: "detail.episodes").firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 30), "the series page lost Episodes")
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.exists, "the series page lost Play")
        for _ in 0..<8 { app.swipeUp() }
        attach("title-sections-all-off")
        for section in sections {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: section).firstMatch.exists,
                           "\(section) still shows with its switch off")
        }
    }

    private func openAbbott() -> Bool {
        app.terminate()
        launch(["-openstream.reset.cloudRestoreHeld.v1", "YES"])
        tab("Library")
        let title = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'library.title.' AND label CONTAINS[c] 'Abbott Elementary'")).firstMatch
        guard check(title.waitForExistence(timeout: 180), "title-sections-abbott-missing",
                    "Abbott Elementary is unavailable in the local library") else { return false }
        title.tap()
        return check(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30),
                     "title-sections-no-page", "Abbott Elementary's title page never opened")
    }

    private func revealed(_ identifier: String) -> Bool {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        scrollIntoView(element)
        return element.exists
    }

    private func setTitlePageSections(on: Bool) {
        app.terminate()
        launch(["-openstream.reset.cloudRestoreHeld.v1", "YES", "-OpenStreamVisionScreen", "general-settings"])
        for name in ["trailers", "cast", "information", "about"] {
            let toggle = app.switches["settings.titlePage.\(name)"].firstMatch
            scrollToControl(toggle, in: app, limit: 20)
            guard check(toggle.waitForExistence(timeout: 30), "title-sections-no-\(name)",
                        "Settings has no Title Page › \(name) switch") else { return }
            let wanted = on ? "1" : "0"
            if toggle.value as? String != wanted { toggle.switches.firstMatch.tap() }
            let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
            XCTAssertEqual(XCTWaiter().wait(for: [switched], timeout: 5), .completed,
                           "Title Page › \(name) did not switch")
        }
        attach(on ? "settings-title-page-on" : "settings-title-page-off")
    }

    func testPolishLiveUsesCleanChannelNames() {
        continueAfterFailure = false
        launch([])
        tab("Live")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
        guard check(rows.firstMatch.waitForExistence(timeout: 120), "polish-live-missing",
            "Live channels are unavailable") else { return }
        for row in rows.allElementsBoundByIndex {
            XCTAssertNil(row.label.range(of: #"^Play\s+(?:CA|US|UK)\s*[:|]"#, options: [.regularExpression, .caseInsensitive]))
        }
        attach("polish-live-logos-and-monograms")
    }

    /// Live search takes the keyboard on every open, and Back leaves it closed.
    func testPolishLiveSearchFocusesOnOpen() {
        continueAfterFailure = false
        launch([])
        tab("Live")
        let searchButton = app.descendants(matching: .any)["live.search"].firstMatch
        guard check(searchButton.waitForExistence(timeout: 120), "polish-live-search-missing",
            "Live search is unavailable") else { return }
        let field = app.searchFields.firstMatch
        for pass in 1...2 {
            searchButton.tap()
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 10), .completed, "Live search opened unfocused (open \(pass))")
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            attach("polish-live-search-focused-\(pass)")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
            app.navigationBars.buttons.firstMatch.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, "Back left Live search open")
            let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: field)
            reopened.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed, "Live search came back after Back")
            XCTAssertTrue(searchButton.isHittable)
        }
        attach("polish-live-search-closed")
    }

    func testPolishSearchHasNoRefreshAndOpensResults() throws {
        continueAfterFailure = false
        launch([])
        tab("Discover")
        let searches = app.buttons.matching(NSPredicate(format: "label == %@", "Search"))
        XCTAssertTrue(searches.firstMatch.waitForExistence(timeout: 30))
        let search = try XCTUnwrap(searches.allElementsBoundByIndex.first { $0.isHittable })
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Refresh"].exists)
        attach("polish-search-idle")
        field.tap()
        field.typeText("Abbott")
        let result = app.links.matching(NSPredicate(format: "label CONTAINS[c] 'Abbott'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40))
        XCTAssertFalse(app.buttons["Refresh"].exists)
        attach("polish-search-results")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.episodes"].firstMatch.waitForExistence(timeout: 30))
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

    func testISOPlayShowsTimelineAndSeeks() throws {
        guard let query = environment["OPENSTREAM_ISO_OWNER_TITLE"], !query.isEmpty else {
            throw XCTSkip("Requires OPENSTREAM_ISO_OWNER_TITLE")
        }
        continueAfterFailure = false
        launch([])
        tab("Library")
        let libraryTitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title.")).firstMatch
        if !libraryTitle.exists {
            let refresh = app.buttons["Refresh"].firstMatch
            if refresh.waitForExistence(timeout: 5), refresh.isEnabled { refresh.tap() }
        }
        XCTAssertTrue(libraryTitle.waitForExistence(timeout: 240), "Local library is unavailable")
        tab("Discover")
        let search = try XCTUnwrap(app.buttons.matching(NSPredicate(format: "label == %@", "Search"))
            .allElementsBoundByIndex.first { $0.isHittable })
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(query)
        let predicates = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.map { NSPredicate(format: "label CONTAINS[c] %@", $0) }
        let hit = app.buttons.matching(NSCompoundPredicate(andPredicateWithSubpredicates: predicates)).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 40))
        hit.tap()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        attach("iso-title")
        play.tap()
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        let menu = app.descendants(matching: .any)["player.disc.menu.active"].firstMatch
        let title = app.descendants(matching: .any)["player.disc.title.active"].firstMatch
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            menu.exists || title.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 60), .completed)
        if menu.exists {
            attach("iso-disc-menu")
            let button = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "player.disc.menu.button.")).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
        }
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "ISO did not start playing")
        XCTAssertTrue(app.descendants(matching: .any)["player.disc.title.active"].firstMatch.exists,
                      "The selected source is not a disc title")
        let slider = app.sliders.matching(NSPredicate(format: "identifier == %@", "Current position")).firstMatch
        if !slider.exists || !slider.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "ISO has no timeline")
        XCTAssertTrue(slider.isEnabled)
        let pause = try XCTUnwrap(app.buttons.matching(NSPredicate(
            format: "label == %@", "Pause")).allElementsBoundByIndex.first { $0.isHittable })
        pause.tap()
        attach("iso-timeline")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "iso-timeline-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let expression = try NSRegularExpression(pattern: #"\d+:\d{2}(?::\d{2})?"#)
        let units = try NSRegularExpression(pattern: #"(\d+)\s*(hours?|minutes?|seconds?)"#)
        func seconds(_ identifier: String) -> Double? {
            let text = app.staticTexts[identifier].firstMatch
            guard text.exists else { return nil }
            for value in [text.label, text.value as? String].compactMap({ $0 }) {
                if let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                   let range = Range(match.range, in: value) {
                    return value[range].split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
                }
            }
            guard let spoken = slider.value as? String else { return nil }
            let parts = spoken.components(separatedBy: "elapsed")
            guard parts.count == 2 else { return nil }
            let value = identifier == "Elapsed Time" ? parts[0] : parts[1]
            let matches = units.matches(in: value, range: NSRange(value.startIndex..., in: value))
            if matches.isEmpty { return value.contains("zero seconds") ? 0 : nil }
            return matches.reduce(0) { total, match in
                guard let number = Range(match.range(at: 1), in: value),
                      let unit = Range(match.range(at: 2), in: value),
                      let count = Double(value[number]) else { return total }
                let multiplier: Double = value[unit].hasPrefix("hour") ? 3600 : value[unit].hasPrefix("minute") ? 60 : 1
                return total + count * multiplier
            }
        }
        let elapsed = try XCTUnwrap(seconds("Elapsed Time"))
        let remaining = try XCTUnwrap(seconds("Remaining Time"))
        let duration = elapsed + remaining
        XCTAssertGreaterThan(duration, 600, "ISO duration is missing")
        func waitForSeek(from previous: Double) throws -> Double {
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                ready.exists && (seconds("Elapsed Time").map { abs($0 - previous) >= 5 } ?? false)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 15), .completed, "ISO seek did not move the playhead")
            return try XCTUnwrap(seconds("Elapsed Time"))
        }
        // A short drag near the current thumb may stay below AVKit's pan threshold.
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let middle = try waitForSeek(from: elapsed)
        XCTAssertGreaterThan(middle, duration / 4)
        slider.adjust(toNormalizedSliderPosition: CGFloat(600 / duration))
        var observed = try waitForSeek(from: middle)
        // The native track rounds long-film gestures; its ten-second buttons finish the seek precisely.
        for _ in 0..<64 where abs(observed - 600) > 5 {
            let skip = app.buttons[observed < 600 ? "Skip Forward" : "Skip Backward"].firstMatch
            XCTAssertTrue(skip.exists)
            skip.tap()
            observed = try waitForSeek(from: observed)
        }
        XCTAssertLessThanOrEqual(abs(observed - 600), 5, "ISO seek expected 600s, observed \(observed)s")
        let toggle = app.buttons["Play/Pause"].firstMatch
        if toggle.label == "Play" { toggle.tap() }
        let nextSecond = observed + 1
        if !app.staticTexts["Elapsed Time"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            seconds("Elapsed Time").map { $0 >= nextSecond } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed, "ISO did not play after the seek")
        if toggle.label == "Pause" { toggle.tap() }
        attach("iso-seek-ten-minutes")
        XCTAssertFalse(playbackFailed())
        closePlayer()
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

    private func launch(_ extra: [String], muteAudio: Bool = true, dismissFirstRun: Bool = true) {
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamTraceConsole", "YES",
                               "-OpenStreamMuteAudio", muteAudio ? "YES" : "NO"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        if dismissFirstRun {
            let notNow = app.buttons["Not Now"].firstMatch
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
    }

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name].firstMatch
        if button.exists || button.waitForExistence(timeout: 20) { button.tap() } else { XCTFail("no \(name) tab") }
    }

    private func revealTransport() {
        if !app.buttons["player.play-pause"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
    }

    private func waitForPlaying(_ pause: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"),
                                                     object: pause)], timeout: 60) == .completed
    }

    private func playbackSeconds() -> Double? {
        let slider = app.sliders["Playback position"].firstMatch
        guard slider.exists, let value = slider.value as? String,
              value.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
        return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
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


@MainActor
final class AppleLineupImportUITests: OpenStreamUITestCase {
    private let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
    private var lineupFile: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENSTREAM_LINEUP_FILE"], !path.isEmpty else {
            throw XCTSkip("Requires the protected lineup import run.")
        }
        lineupFile = URL(fileURLWithPath: path)
        continueAfterFailure = false
    }

    override func tearDown() { app.terminate() }

    private func launch(_ screen: String, extra: [String] = []) {
        app.terminate()
        app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamTrace", "YES",
            "-OpenStreamMuteAudio", "YES", "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.firstRunGuidanceSeen", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    private func lineupSourceFile() throws -> URL {
        let playlist = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_LINEUP_PLAYLIST_URL"])
        let seed = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-source-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [
            ["kind": "m3u", "name": "Lineup Fixture", "playlistURL": playlist]
        ]]).write(to: seed)
        return seed
    }

    func testAImportFromFilesAndKeepAfterRelaunch() throws {
        launch("channels")
        let package = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Package' OR label == 'Everything'")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["lineup.name"].exists)
        package.tap()
        XCTAssertFalse(app.buttons["Complete Guide"].exists)
        app.buttons["Everything"].firstMatch.tap()
        let button = app.buttons["lineup.import.file"]
        scrollToControl(button, in: app)
        button.tap()
        let stem = try XCTUnwrap(lineupFile).deletingPathExtension().lastPathComponent
        let file = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR identifier BEGINSWITH %@", stem, stem)).firstMatch
        if !file.waitForExistence(timeout: 5) {
            for label in ["Browse", "On My iPhone", "oStream"] {
                let control = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                    .allElementsBoundByIndex.first { $0.isHittable }
                control?.tap()
                if file.waitForExistence(timeout: 3) { break }
            }
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), "Staged lineup file is missing from Files")
        file.tap()
        XCTAssertTrue(app.alerts.staticTexts["Lineup imported."].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].tap()
        XCTAssertEqual(app.staticTexts["lineup.name"].label, "Complete US")
        launch("channels")
        XCTAssertTrue(app.staticTexts["lineup.name"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["lineup.name"].label, "Complete US")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Package' OR label == 'Everything'")).firstMatch
        picker.tap()
        XCTAssertTrue(app.buttons["Complete Guide"].waitForExistence(timeout: 10))
        app.buttons["Complete Guide"].tap()
        let seed = try lineupSourceFile()
        defer { try? FileManager.default.removeItem(at: seed) }
        launch("live", extra: ["-OpenStreamDevSources", seed.path,
            "-openstream.settings.live.scope.v1", "providerLineup"])
        XCTAssertTrue(app.buttons["live.guide"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).firstMatch.waitForExistence(timeout: 45))
        let importedLineup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(lineupFile))) as? [String: Any])
        let channels = try XCTUnwrap(importedLineup["channels"] as? [[String: Any]])
        let categories = Set(channels.compactMap { $0["category"] as? String })
        let visibleCategories = Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'live.category.'"))
            .allElementsBoundByIndex.map { String($0.identifier.dropFirst("live.category.".count)) })
        XCTAssertGreaterThanOrEqual(categories.intersection(visibleCategories).count, 2)
        XCTAssertFalse(visibleCategories.contains("Playlist Group"))
        app.buttons["live.guide"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let channel = try XCTUnwrap(channels.first { "Play " + ($0["name"] as? String ?? "") == row.label })
        let number = try XCTUnwrap(channel["number"] as? Int)
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(row.screenshot().image.cgImage)).perform([text])
        XCTAssertTrue(text.results?.contains { $0.topCandidates(1).first?.string == String(number) } == true)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "lineup-import-live"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBPairedWebUploadChangesTheLineupAndPersists() async throws {
        launch("web-management", extra: ["-OpenStreamStartWebManagement", "YES"])
        let address = app.staticTexts["webmanagement.address"]
        let code = app.staticTexts["webmanagement.pairingCode"]
        XCTAssertTrue(address.waitForExistence(timeout: 30))
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        let base = try XCTUnwrap(URL(string: address.label))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, paired) = try await session.data(from: try XCTUnwrap(URL(string: "?pair=" + code.label, relativeTo: base)))
        XCTAssertEqual((paired as? HTTPURLResponse)?.statusCode, 200)
        let original = try Data(contentsOf: XCTUnwrap(lineupFile))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["name"] = "Web Lineup"
        let boundary = "openstream-lineup-ui"
        var request = URLRequest(url: base.appendingPathComponent("lineup"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        func body(_ data: Data) -> Data {
            Data(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"lineup\"; filename=\"Complete US.oslineup\"\r\nContent-Type: application/json\r\n\r\n").utf8)
                + data + Data(("\r\n--" + boundary + "--\r\n").utf8)
        }
        request.httpBody = body(try JSONSerialization.data(withJSONObject: object))
        let (page, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Web Lineup"))
        request.httpBody = body(original)
        let (_, restored) = try await session.data(for: request)
        XCTAssertEqual((restored as? HTTPURLResponse)?.statusCode, 200)
        launch("channels")
        XCTAssertTrue(app.staticTexts["lineup.name"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["lineup.name"].label, "Complete US")
    }

    func testCURLImportContinuesAfterItsRowsScrollOffScreen() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_LINEUP_SERVER"].flatMap(URL.init(string:)))
        let seed = try lineupSourceFile()
        defer { try? FileManager.default.removeItem(at: seed) }
        launch("channels", extra: ["-OpenStreamDevSources", seed.path,
            "-openstream.settings.live.package.v1", "custom", "-openstream.settings.live.scope.v1", "providerLineup"])
        let selected = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove '")).firstMatch
        scrollToControl(selected, in: app)
        XCTAssertTrue(selected.exists)
        for _ in 0..<4 { app.swipeDown() }
        let field = app.textFields["lineup.url"]
        scrollToControl(field, in: app)
        field.tap()
        field.typeText(base.appendingPathComponent("delayed-lineup.oslineup").absoluteString)
        let importButton = app.buttons["lineup.import.url"]
        scrollToControl(importButton, in: app)
        importButton.tap()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, started) = try await session.data(from: base.appendingPathComponent("wait-for-lineup"))
        XCTAssertEqual((started as? HTTPURLResponse)?.statusCode, 200)
        for _ in 0..<6 where field.isHittable { app.swipeUp() }
        XCTAssertFalse(field.isHittable)
        let (_, released) = try await session.data(from: base.appendingPathComponent("release-lineup"))
        XCTAssertEqual((released as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(app.alerts.staticTexts["Lineup imported."].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].tap()
        launch("channels")
        XCTAssertTrue(app.staticTexts["lineup.name"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["lineup.name"].label, "Complete US")
    }
}

@MainActor
final class AppleIPTVConnectionUITests: OpenStreamUITestCase {
    private let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")

    override func tearDown() { app.terminate(); super.tearDown() }

    func testCloseThenPlayDifferentChannelFiveTimes() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OPENSTREAM_IPTV_CONNECTION_TEST"] == "1", "Requires the owner's seeded test simulator")
        let names = (environment["OPENSTREAM_IPTV_CHANNELS"] ?? "").split(separator: "|").map(String.init)
        continueAfterFailure = false
        XCTAssertEqual(names.count, 2)
        guard names.count == 2 else { return }
        XCTAssertNotEqual(names[0], names[1])
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
            "-openstream.settings.live.enabled.v1", "YES", "-OpenStreamHoldPlayerChrome", "YES",
            "-openstream.live.startWithLastChannel", "NO"]
        app.launch()
        let live = app.tabBars.buttons["Live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 30))
        live.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 90))
        print("IPTV1 iOS visible channels: " + rows.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | "))
        let guideShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        guideShot.name = "iptv-guide-before-playback"
        guideShot.lifetime = .keepAlways
        add(guideShot)
        play(names[0], cycle: 0)
        for cycle in 1...5 {
            let fullScreen = app.buttons["player.fullscreen"].firstMatch
            if !fullScreen.isHittable {
                app.descendants(matching: .any)["live.stage.player"].firstMatch.tap()
            }
            XCTAssertTrue(fullScreen.waitForExistence(timeout: 3))
            fullScreen.tap()
            let close = app.buttons["player.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
            play(names[cycle % names.count], cycle: cycle)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iptv-five-channel-transitions"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func play(_ name: String, cycle: Int) {
        let row = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'guide.play.' AND label == %@", "Play \(name)")).firstMatch
        let towardEarlier = cycle > 0 && cycle.isMultiple(of: 2)
        for _ in 0..<12 {
            if row.exists && row.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: towardEarlier ? 0.6 : 0.82))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: towardEarlier ? 0.85 : 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Missing channel \(name)")
        XCTAssertTrue(row.isHittable)
        let pressed = Date()
        row.tap()
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let deadline = pressed.addingTimeInterval(cycle == 0 ? 15 : 3)
        var ready = false
        while Date() < deadline {
            if stage.exists, stage.value as? String == "Playing", stage.label.localizedCaseInsensitiveContains(name) {
                ready = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let observedMilliseconds = Date().timeIntervalSince(pressed) * 1000
        print("IPTV1 iOS cycle=\(cycle) channel=\(name) ready=\(ready) observed_ms=\(Int(observedMilliseconds))")
        XCTAssertTrue(ready)
        if cycle > 0 { XCTAssertLessThanOrEqual(observedMilliseconds, 3000) }
    }
}
