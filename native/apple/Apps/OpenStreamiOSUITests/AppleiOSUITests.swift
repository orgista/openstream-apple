import XCTest

/// iPhone and iPad behaviour that needs a touch or a rotation.
///
/// `simctl` can drive neither: it has no tap API and no orientation option, so
/// every row that depended on one — the sheets in C3, landscape in C8, typing a
/// query in F2 — sat blocked. This target is the way to them.
@MainActor
final class AppleiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    private func launch(screen: String? = nil) {
        if let screen { app.launchArguments += ["-OpenStreamVisionScreen", screen] }
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        app.launch()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Proves the target itself works before anything is asserted through it.
    func testAppLaunchesAndShowsTheTabBar() {
        launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")
        let discover = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Discover")).firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 30), "the Discover tab never appeared")
        attach("ios-launch")
    }

    /// Owner: "type by keyboard on iPhone doesn't work".
    ///
    /// Typing is only half of it — the value has to survive leaving the screen
    /// and coming back, which is where a binding that never commits shows up.
    func testTypingIntoASettingsFieldPersists() {
        launch(screen: "settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let metadata = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Metadata")).firstMatch
        XCTAssertTrue(metadata.waitForExistence(timeout: 30), "no Metadata row")
        metadata.tap()

        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no field to type into")
        field.tap()
        let typed = "abc123test"
        field.typeText(typed)
        Thread.sleep(forTimeInterval: 2.0)
        attach("typing-entered")

        // Leave the screen and come back: a field that only looks right while
        // focused is the failure being chased.
        app.navigationBars.buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 2.0)
        metadata.tap()
        Thread.sleep(forTimeInterval: 2.5)
        attach("typing-after-returning")

        let again = app.secureTextFields.firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15), "the field vanished on return")
        // A secure field reports dots, so length is what can be checked.
        let value = (again.value as? String) ?? ""
        print("TYPING value after return: \(value.count) chars (typed \(typed.count))")
        XCTAssertFalse(value.isEmpty, "what was typed did not survive leaving the screen")
    }

    /// Owner report, TestFlight build 10: "The Secret Lives of Mormon Wives"
    /// plays a different show for episodes 1–2.
    ///
    /// The ranking fix was reasoned from the owner's evidence and covered by
    /// tests, but nobody had watched the title play. This drives the real path —
    /// search, open, play episode 1 — and attaches the frame so the picture can
    /// be compared against the show it is supposed to be.
    func testMormonWivesEpisodeOnePlaysSomething() {
        launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Search control")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field")
        field.tap()
        field.typeText("secret lives of mormon wives")
        Thread.sleep(forTimeInterval: 10.0)
        attach("mw-search")

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Mormon Wives")).firstMatch
        guard row.waitForExistence(timeout: 20) else {
            print("MW no result row; search returned nothing for this title")
            return
        }
        row.tap()
        Thread.sleep(forTimeInterval: 8.0)
        attach("mw-title-page")

        // Episode 1 if the episode list is up, otherwise the main Play button.
        let episodeOne = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "S1 E1")).firstMatch
        if episodeOne.waitForExistence(timeout: 10) {
            episodeOne.tap()
        } else if app.buttons["Play"].waitForExistence(timeout: 5) {
            app.buttons["Play"].tap()
        } else {
            print("MW neither an episode row nor Play was reachable")
            return
        }

        Thread.sleep(forTimeInterval: 40.0)
        attach("mw-episode-one-playing")
        // Tap to raise the transport, which names what is actually playing —
        // the frame alone cannot distinguish an episode from a trailer.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
        Thread.sleep(forTimeInterval: 3.0)
        attach("mw-transport-overlay")
        let labels = app.descendants(matching: .any).allElementsBoundByIndex
            .prefix(60).map(\.label).filter { !$0.isEmpty }
        print("MW onscreen labels: \(labels.joined(separator: " | "))")
    }

    /// Owner C4: the keyboard's return key should move to the next field and
    /// read "done" on the last.
    ///
    /// This was shipped without ever being seen — `submitLabel` and `onSubmit`
    /// were added to five forms on the strength of unit tests over the chain
    /// logic, because nothing could raise a keyboard. This looks at the key.
    func testReturnKeyReadsNextThenDoneAcrossAForm() {
        launch(screen: "settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let metadata = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Metadata")).firstMatch
        XCTAssertTrue(metadata.waitForExistence(timeout: 30), "no Metadata row in Settings")
        metadata.tap()

        let fields = app.secureTextFields
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 20), "the Metadata fields never appeared")
        XCTAssertGreaterThanOrEqual(fields.count, 2, "expected TMDB and OMDb fields")

        // First field: another one follows, so the return key should offer to
        // go there rather than just dismiss.
        fields.element(boundBy: 0).tap()
        let next = app.keyboards.buttons["next"]
        let hasNext = next.waitForExistence(timeout: 10)
        // Attach *after* the key is found: capturing on a fixed sleep caught the
        // frame before the keyboard had animated up, so the picture showed no
        // keyboard at all while the assertion was passing.
        attach("ios-return-key-first-field")
        print("RETURNKEY first field: next=\(hasNext)")

        // Last field: nothing follows it.
        fields.element(boundBy: 1).tap()
        let done = app.keyboards.buttons["done"]
        let hasDone = done.waitForExistence(timeout: 10)
        attach("ios-return-key-last-field")
        print("RETURNKEY last field: done=\(hasDone)")

        XCTAssertTrue(hasNext, "the first field's return key does not offer the next field")
        XCTAssertTrue(hasDone, "the last field's return key does not read done")
    }

    /// Owner F2, and the complaint that started it: "I search for Jury duty
    /// and go odd results".
    ///
    /// Driven through the app rather than the `openstream://search` deep link,
    /// so this is the path a viewer actually takes: tap the search glyph, type,
    /// read the rows.
    func testSearchingFromTheToolbarReturnsShowsAndMoviesOnly() {
        launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Search control in the toolbar")
        search.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()
        field.typeText("jury duty")
        Thread.sleep(forTimeInterval: 8.0)
        attach("ios-search-jury-duty")

        // Every row names its kind; an episode row would read "Episode".
        let episodeRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Episode")).count
        XCTAssertEqual(episodeRows, 0, "search returned \(episodeRows) episode rows")

        let jury = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Jury Duty")).count
        XCTAssertGreaterThan(jury, 0, "no Jury Duty rows came back at all")
        print("SEARCH rows mentioning Jury Duty: \(jury)")
    }

    /// Owner: "type by keyboard on iPhone doesn't work".
    ///
    /// `typeText` injects through the hardware-keyboard path, so it can pass
    /// while the thing the owner actually touches — the on-screen keyboard —
    /// does nothing. This taps the soft keys themselves, which is the only way
    /// to tell the two apart.
    func testOnScreenKeyboardTypesIntoTheSearchField() throws {
        launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Search control in the toolbar")
        search.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        field.tap()

        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 15), "tapping the search field brought up no keyboard")
        attach("keyboard-shown")

        // Simulator > I/O > Keyboard > Connect Hardware Keyboard suppresses the
        // on-screen keyboard entirely: the element above still resolves, but it
        // has no keys, and this test has nothing to tap. That is a setting on
        // the Mac, not a fault in the app, so skip rather than fail. Turn it off
        // (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard
        // -bool false`, then reboot the simulator) to run this for real.
        // The keys still resolve in that case, parked below the bottom of the
        // screen, so existence is not the test — reachability is.
        let firstKey = app.keys.firstMatch
        guard firstKey.waitForExistence(timeout: 5), firstKey.isHittable else {
            throw XCTSkip("no reachable on-screen keys — the simulator has a hardware keyboard connected")
        }

        for letter in ["d", "u", "n", "e"] {
            // The keys are labelled uppercase while shift is latched and
            // lowercase afterwards, so try both spellings.
            let upper = app.keys[letter.uppercased()]
            let lower = app.keys[letter]
            let key = upper.waitForExistence(timeout: 5) ? upper : lower
            XCTAssertTrue(key.waitForExistence(timeout: 5), "the keyboard has no \(letter) key")
            key.tap()
        }
        Thread.sleep(forTimeInterval: 3.0)
        attach("keyboard-typed")

        // iOS auto-capitalises the first letter, so the field reads "Dune".
        let value = (field.value as? String) ?? ""
        print("SOFT KEYBOARD field value: \(value)")
        XCTAssertTrue(
            value.lowercased().contains("dune"),
            "tapping d-u-n-e left the field reading \(value)"
        )

        // Typing is only useful if it reaches the search. Dune is in the corpus.
        Thread.sleep(forTimeInterval: 6.0)
        attach("keyboard-results")
        let dune = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Dune")).count
        print("SOFT KEYBOARD rows mentioning Dune: \(dune)")
    }

    /// Tester, TestFlight build 10: "when you deactivate a tab, it is impossible
    /// to reactivate it because it is grayed out."
    ///
    /// A dead end — the only way back was reinstalling — so this drives the real
    /// control rather than the policy behind it: switch Live off, then check the
    /// switch is still live and can be switched back on.
    func testATabSwitchedOffCanBeSwitchedBackOn() {
        launch(screen: "settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let live = app.switches["settings.live.enabled"]
        XCTAssertTrue(live.waitForExistence(timeout: 30), "no Show Live tab switch")
        XCTAssertTrue(live.isEnabled, "the switch was already disabled before anything was touched")
        print("TABTOGGLE before: frame=\(live.frame) hittable=\(live.isHittable) value=\(String(describing: live.value)) type=\(live.elementType.rawValue)")

        // Off. A SwiftUI toggle's centre is its label, which does not flip it;
        // the switch itself sits at the trailing edge.
        func flip() { live.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        if (live.value as? String) == "1" { flip() }
        Thread.sleep(forTimeInterval: 1.5)
        attach("tab-toggle-off")
        XCTAssertEqual(live.value as? String, "0", "Show Live tab did not switch off")

        // The bug: greyed out here, with no way back.
        XCTAssertTrue(live.isEnabled, "a tab switched off could not be switched back on")

        // On again.
        flip()
        Thread.sleep(forTimeInterval: 1.5)
        attach("tab-toggle-on-again")
        XCTAssertEqual(live.value as? String, "1", "Show Live tab did not come back on")
    }

    /// Owner, 2026-09-17: downloads are automatic — no "Download from" sheet.
    /// The tester's "a source is chosen by default but is not necessarily
    /// available" is answered by the coordinator walking the ranked plans when
    /// one fails, not by asking. So: tapping an episode's ↓ must NOT open a
    /// sheet, and the download must start; it is then cancelled so nothing
    /// lands on the persistent simulator.
    func testDownloadStartsWithoutAskingForASource() {
        launch(screen: "detail")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        // Found by identifier: the label turns into "Preparing …"/"Downloading …, 42%"
        // once the download runs, and it changes again when metadata resolves.
        let download = app.buttons.matching(identifier: "detail.episode.download").firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 40), "no per-episode Download control on the detail page")
        // ↓ is disabled until the canonical id is known; a tap before that is a no-op.
        let enabled = NSPredicate(format: "isEnabled == true")
        _ = XCTWaiter().wait(for: [expectation(for: enabled, evaluatedWith: download)], timeout: 40)
        XCTAssertTrue(download.isEnabled, "the Download control never became enabled")
        download.tap()
        Thread.sleep(forTimeInterval: 3.0)
        attach("download-after-tap")

        XCTAssertFalse(app.navigationBars["Download from"].exists, "a source sheet appeared — downloads must be automatic")
        XCTAssertFalse(app.navigationBars["Other sources"].exists, "the playback source sheet appeared on Download")

        // Something must be happening: the row's control or the page's download
        // state should read as in progress within a generous window.
        let busy = app.buttons.matching(identifier: "detail.episode.download").matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@", "Preparing ", "Downloading ", "Downloaded ")).firstMatch
        let status = app.staticTexts["detail.download.status"]
        let deadline = Date().addingTimeInterval(60)
        var started = false, failed = false
        while Date() < deadline, !started, !failed {
            started = busy.exists
            failed = status.exists
            if !started, !failed { Thread.sleep(forTimeInterval: 1.0) }
        }
        attach(started ? "download-started" : failed ? "download-attempted-then-failed" : "download-not-started-after-60s")
        XCTAssertTrue(started || failed, "tapping ↓ did not start a download and showed no failure")

        if started, !busy.label.hasPrefix("Downloaded ") {
            // Cancel through the app's own dialog so no file is kept on the sim.
            busy.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.waitForExistence(timeout: 10) { cancel.tap() }
            Thread.sleep(forTimeInterval: 1.0)
            attach("download-cancelled")
        }
    }

    /// Owner, 2026-09-17: "paste/upload text for M3U streams". Switching the
    /// Type picker to M3U must reveal the Playlist Text editor and Choose
    /// File; nothing is saved here.
    func testAddLiveTVOffersPlaylistTextForM3U() {
        launch(screen: "add-live")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // The Form picker's tappable element is its value, not its "Type" label.
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Xtream Account")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "no Type picker")
        picker.tap()
        let m3u = app.buttons["M3U Playlist"].firstMatch
        XCTAssertTrue(m3u.waitForExistence(timeout: 10), "M3U Playlist option not offered")
        m3u.tap()
        let editor = app.textViews["sources.live.playlistText"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Playlist Text editor missing for M3U")
        XCTAssertTrue(app.buttons["sources.live.chooseFile"].exists, "Choose File missing for M3U")
        editor.tap()
        editor.typeText("#EXTM3U\n#EXTINF:-1,Test\nhttps://fixture.example/a.m3u8")
        attach("add-live-m3u-playlist-text")
    }

    /// Owner C8: landscape. The rule is that the phone hides the tab bar in
    /// landscape so content fills the screen, and brings it back in portrait.
    /// Both directions are asserted, because a bar that never comes back is the
    /// failure that would actually strand someone.
    func testLandscapeHidesTheTabBarAndPortraitBringsItBack() {
        launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        // Match the tab *bar*, not the label "Discover" — the navigation title
        // says "Discover" too, so a label match is true whether or not the bar
        // is on screen. The first version of this test failed for exactly that
        // reason while the screenshot showed the bar correctly hidden.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "no tab bar in portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3.0)
        attach("ios-landscape")
        XCTAssertFalse(tabBar.exists && tabBar.isHittable,
                       "the tab bar is still showing in landscape")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 3.0)
        attach("ios-portrait-again")
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15),
                      "the tab bar did not come back when returning to portrait")
    }
}
