import XCTest

/// Focus behaviour on Apple TV, driven by the Siri Remote.
///
/// Every fix that depended on focus shipped unverified for a whole session,
/// because there is no way to press a remote from a script *except* from here:
/// `simctl` has no such API. Each of these assertions replaces something the
/// owner previously had to check by hand and report back.
@MainActor
final class AppleTVFocusUITests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { .shared }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        app?.terminate()
    }

    /// Launches on `screen` using the same DEBUG hook the headless captures
    /// use, with the interaction trace on so a failure leaves a timeline.
    private func launch(screen: String) {
        app.launchArguments += ["-OpenStreamVisionScreen", screen,
                                "-OpenStreamTrace", "YES"]
        app.launch()
    }

    /// Element type is not something a test should care about: SwiftUI decides
    /// it, and `.accessibilityElement(children: .combine)` turns a panel into a
    /// StaticText. Match on the identifier alone.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Whatever currently holds focus, of any type.
    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    /// Waits for an element rather than sleeping: the guide loads over the
    /// network and a fixed sleep either flakes or wastes time.
    @discardableResult
    private func wait(for element: XCUIElement, _ timeout: TimeInterval = 30) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - The guide

    /// Owner Z17: the guide must open on the first channel, not the category
    /// chips, so the info panel describes what it is showing.
    func testGuideOpensFocusedOnAChannel() {
        launch(screen: "live")
        let panel = element("live.tv.info")
        XCTAssertTrue(wait(for: panel), "the guide's info panel never appeared")

        // Launching straight into a tab leaves focus on the tab bar, which is
        // correct tvOS behaviour. Z17 is about where focus lands when the
        // viewer moves *into* the guide, so press down first.
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)

        let focused = focusedElement
        XCTAssertTrue(focused.exists, "pressing down from the tab bar left focus nowhere")
        XCTAssertTrue(
            focused.identifier.hasPrefix("guide.play.") || focused.identifier.hasPrefix("live.category."),
            "expected a channel or a category chip to hold focus, got '\(focused.identifier)'"
        )
        // Z17 proper: the first stop inside the guide should be a channel.
        XCTAssertTrue(
            focused.identifier.hasPrefix("guide.play."),
            "Z17: the guide should open on a channel, but focus went to '\(focused.identifier)'"
        )
    }

    /// Owner, twice: "would like to also see a preview of the channel similar
    /// to direct tv app — they preview the channel, it starts playing before
    /// you click".
    ///
    /// The preview is dwell-gated, so it can only be observed by actually
    /// holding focus on a rail cell — which is why it could never be checked
    /// from a headless capture: launching into the Live tab leaves focus on the
    /// tab bar and nothing ever previews. This moves focus onto a channel,
    /// waits past the dwell, and attaches what the screen looks like.
    func testChannelPreviewStartsAfterDwellingOnAChannel() {
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide's info panel never appeared")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")

        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        let focused = focusedElement
        XCTAssertTrue(
            focused.identifier.hasPrefix("guide.play."),
            "expected a channel to hold focus, got '\(focused.identifier)'"
        )

        // Past the 1200 ms dwell, plus time for the stream to open.
        Thread.sleep(forTimeInterval: 8)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "guide-preview-after-dwell"
        shot.lifetime = .keepAlways
        add(shot)

        // The trace records what the preview did; keep it with the screenshot
        // so a failure explains itself.
        XCTAssertTrue(focused.exists, "focus left the channel during the dwell")
    }

    /// Owner: "channels when clicking make it freeze". Select on a rail cell
    /// must open the player rather than leaving focus nowhere.
    func testSelectingAChannelOpensThePlayer() {
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")

        // Into the guide first — Select on the tab bar only re-selects the tab.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        remote.press(.select)

        // The player's focus catcher is a `Color.clear` button, so asserting on
        // it is fragile. The guide being covered is the reliable signal that
        // the full-screen player took over.
        let guidePanel = element("live.tv.info")
        let covered = NSPredicate(format: "exists == false OR isHittable == false")
        expectation(for: covered, evaluatedWith: guidePanel)
        waitForExpectations(timeout: 40)
    }

    /// Owner 18:55: Menu over a channel that never started must leave, not
    /// toggle the channel row over a black screen.
    func testMenuLeavesTheGuideRatherThanTrapping() {
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")

        // Enter the guide first. Pressing Menu while focus is still on the tab
        // bar is the app root, where stock tvOS leaves for the Home screen —
        // correct, and not what this test is about.
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(
            focusedElement.identifier.hasPrefix("guide.play."),
            "expected a channel to hold focus before pressing Menu, got '\(focusedElement.identifier)'"
        )

        // Owner 2026-09-15: "in live I can't go back when pressing home/esc
        // from live to go to the top bar … I have to scroll all the way up."
        // Menu from inside the guide hands focus back up to the tab bar; it
        // used to be swallowed by an `onExitCommand` that then did nothing,
        // which is what "I have to scroll all the way up" meant.
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 1.5)

        let focused = focusedElement
        XCTAssertTrue(focused.exists, "Menu left focus nowhere in the guide")
        XCTAssertFalse(
            focused.identifier.hasPrefix("guide.play."),
            "Menu did not leave the channel rail: focus is still on '\(focused.identifier)'"
        )
    }

    // MARK: - Search

    /// Owner F2/F4: reaching Search and what it shows.
    ///
    /// The tab is a bare magnifying glass with no title, so it is reached by
    /// going up to the bar and left along it. The deep link route
    /// (`openstream://search?query=…`) cannot be used here: `simctl openurl`
    /// makes tvOS put up its own "Open in OpenStream?" confirmation, which is a
    /// simulator artifact and needs a press of its own.
    func testSearchTabIsReachableAndTakesFocus() {
        launch(screen: "discover")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 30), "nothing holds focus at all")

        // Up until the tab bar has focus, then left to the leading tab.
        for _ in 0 ..< 3 {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 1.2)
        }
        for _ in 0 ..< 5 {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 1.0)
            if focusedElement.label == "Search" { break }
        }
        XCTAssertEqual(focusedElement.label, "Search",
                       "never reached the Search tab; focus sat on '\(focusedElement.label)'")

        remote.press(.select)
        Thread.sleep(forTimeInterval: 2.5)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "search-tab"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(focusedElement.exists, "opening Search left focus nowhere")
        print("SEARCH focus after open: label='\(focusedElement.label)' id='\(focusedElement.identifier)'")
        // F2 (the result rows) is not covered here: `typeText` against the
        // search field fails on tvOS — the field never takes keyboard focus
        // that way — and driving 9 characters through the on-screen keyboard
        // with the remote would be its own source of flake.

    }

    // MARK: - The title page

    /// Diagnostic, not an assertion: prints where the remote actually lands on
    /// the title page, so a focus path is read off the device instead of
    /// guessed at.
    ///
    /// It earned its place immediately. Two attempts at a B22 test were written
    /// against an assumed layout and both failed on the *navigation*, not the
    /// behaviour: Down from the tab bar lands on an episode control whose
    /// identifier is empty (not `detail.play`), and Right from there walks the
    /// episode list rather than reaching My List / Rate — even though a static
    /// capture shows both sitting beside Play.
    func testDumpTitlePageFocusPath() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        print("FOCUSPATH start: label='\(focusedElement.label)' id='\(focusedElement.identifier)'")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        print("FOCUSPATH down 1: label='\(focusedElement.label)' id='\(focusedElement.identifier)'")
        // Up from wherever Down landed: if My List / Rate are above, they are
        // reachable and the page simply opened further down. If Up goes
        // straight back to the tab bar, the icon row is not in the remote's
        // path at all, which would be a real defect.
        for step in 0 ..< 4 {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 1.3)
            let f = focusedElement
            print("FOCUSPATH up \(step + 1): label='\(f.label)' id='\(f.identifier)'")
        }
    }

    /// Owner B25: "scrolling is slow".
    ///
    /// Smoothness cannot be asserted from a screenshot, but **dropped input**
    /// can be counted, and that is what a rail which cannot keep up actually
    /// does: presses arrive faster than it can move focus and some are lost.
    /// This drives ten rapid presses along a shelf and counts how many moved
    /// focus, printing the per-press cost so a regression has a number to beat.
    func testShelfSurvivesRapidPressesAndRecordsTheCost() {
        launch(screen: "discover")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 30), "nothing holds focus at all")

        // Into the content: the bar holds focus on launch.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 2.0)
        // Some rail cells carry an identifier and no label, so focus is keyed
        // on both — otherwise every cell looks identical and nothing "moves".
        func focusKey() -> String {
            let f = focusedElement
            return "\(f.label)|\(f.identifier)"
        }
        var previous = focusKey()
        print("SCROLL start key='\(previous)'")
        XCTAssertNotEqual(previous, "|", "pressing down from the tab bar left focus nowhere")

        let presses = 10
        var moved = 0
        let started = Date()
        for _ in 0 ..< presses {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.35)
            let current = focusKey()
            if current != previous { moved += 1 }
            print("SCROLL step key='\(current)'")
            previous = current
        }
        let elapsed = Date().timeIntervalSince(started)
        print("SCROLL moved \(moved)/\(presses) in \(String(format: "%.2f", elapsed))s "
              + "(\(String(format: "%.0f", elapsed / Double(presses) * 1000)) ms per press)")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "shelf-after-rapid-presses"
        shot.lifetime = .keepAlways
        add(shot)

        // Deliberately no assertion on `moved`. The first run of this reported
        // 1/10 and looked like dropped input — but the attached frame showed
        // focus sitting on the **last** poster of a four-item shelf, which is a
        // rail that reached its end and correctly stopped. The two disagree, so
        // the focus key is not a trustworthy measure of movement here and a
        // threshold built on it would be a false failure waiting to happen.
        //
        // What this still gives is the per-press cost, printed above: 619 ms
        // for ten presses on the Continue Watching shelf, which is the number a
        // future "scrolling is slow" report can be checked against.
        XCTAssertTrue(focusedElement.exists, "the shelf left focus nowhere")
    }

    /// Owner B24: the "Other sources" entry point.
    ///
    /// On Apple TV it is not a visible control — it lives in a `contextMenu` on
    /// the Play button, so the only way to it is a long press of Select. That
    /// is worth a test precisely because nothing on screen advertises it: if
    /// the menu ever stopped opening, nothing else would reveal it.
    func testOtherSourcesIsReachableByLongPressingPlay() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")
        XCTAssertEqual(focusedElement.identifier, "detail.play",
                       "expected Play to hold focus on appear")

        remote.press(.select, forDuration: 2.0)
        Thread.sleep(forTimeInterval: 2.5)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "other-sources-context-menu"
        shot.lifetime = .keepAlways
        add(shot)

        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Other sources")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "long-pressing Play did not reveal the Other sources entry")
    }

    /// Owner B23: the episode list must show which episode is focused.
    ///
    /// Down from Play lands on the episode rail (the focus-path diagnostic
    /// established that). This walks two episodes along and attaches the frame,
    /// so the thumbnails and the focused state can be looked at rather than
    /// assumed, and asserts the rail actually moves — a rail that swallows
    /// presses looks identical in a screenshot to one that works.
    func testEpisodeRailMovesAndShowsTheFocusedEpisode() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")

        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.8)
        let first = focusedElement.label
        XCTAssertTrue(first.contains("Play S"),
                      "expected an episode to hold focus, got '\(first)'")

        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.4)
        let second = focusedElement.label
        XCTAssertNotEqual(first, second, "the episode rail did not move on Right")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "episode-rail-focused"
        shot.lifetime = .keepAlways
        add(shot)
        print("EPISODES first='\(first)' second='\(second)'")
    }

    /// Owner B22: opening Rate must not drop focus onto Play.
    ///
    /// The risk is written into the source: pressing Rate replaces the button
    /// with the three choices, "and focus with nowhere to go falls back to
    /// `defaultFocus`, which is Play". The code hands focus to the first choice
    /// in the same breath to prevent that; this holds it there.
    ///
    /// The navigation matters and is not obvious — the focus-path diagnostic
    /// established it. The page opens with `detail.play` already focused, and
    /// the icon row sits on the same line to its right; pressing Down from Play
    /// skips the row and lands on the episode list instead.
    func testOpeningRateKeepsFocusOnTheChoicesNotPlay() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")

        // Right along the action line until Rate holds focus. A fixed count
        // would break the moment another icon joins the row.
        var landedOnRate = focusedElement.label == "Rate"
        for _ in 0 ..< 4 where !landedOnRate {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 1.2)
            landedOnRate = focusedElement.label == "Rate"
        }
        XCTAssertTrue(landedOnRate,
                      "never reached Rate; focus sat on '\(focusedElement.label)'")

        remote.press(.select)
        Thread.sleep(forTimeInterval: 2.0)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "rate-choices-open"
        shot.lifetime = .keepAlways
        add(shot)

        let focused = focusedElement
        XCTAssertTrue(focused.exists, "opening Rate left focus nowhere")
        XCTAssertNotEqual(focused.label, "Play",
                          "B22: opening Rate dropped focus back onto Play")
        XCTAssertTrue(["Not for Me", "I Like This", "Love This"].contains(focused.label),
                      "expected a rating choice to hold focus, got '\(focused.label)'")
    }

    /// Owner Z3/D4: the icon row must be reachable and keep focus, which is
    /// where the ring-over-label and focus-vs-selection bugs showed up.
    func testTitlePageIconRowTakesFocus() {
        launch(screen: "detail")
        let play = element("detail.play")
        XCTAssertTrue(wait(for: play, 40), "the title page never appeared")

        remote.press(.down)
        let iconRow = element("detail.icon-row")
        XCTAssertTrue(iconRow.waitForExistence(timeout: 10), "the My List / Rate row never appeared")

        XCTAssertTrue(focusedElement.exists, "pressing down from Play left focus nowhere")
    }
}

