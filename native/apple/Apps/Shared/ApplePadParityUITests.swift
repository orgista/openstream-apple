#if os(iOS) || os(visionOS)
import XCTest

/// The iPad's screens, and Vision Pro drawing the same ones (spec avp-native
/// 2026-10-18): the same checkpoints run unchanged on the iPad and the
/// Vision Pro simulators. Each checkpoint keeps a screenshot, the
/// accessibility tree and the system audit's findings as attachments.
@MainActor
final class ApplePadParityUITests: XCTestCase {
    private let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
    private var teardownAdded = false

    /// An 11-inch iPad on its side; Vision Pro's opening window
    /// (`AppleVisionPlayerWindowPolicy.defaultWindowSize`).
    private static let defaultSize = CGSize(width: 1180, height: 820)
    #if os(visionOS)
    /// `AppleVisionPlayerWindowPolicy.browseMinimum`.
    private static let smallestSize = CGSize(width: 960, height: 600)
    #else
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad parity")
    }
    #endif

    private var stubs: String {
        ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("TestPlans/Stubs").path
    }

    func testDiscoverLibraryAndSettingsUseTheIPadLayout() throws {
        launch("discover")
        let pages = element("home.featured.pages")
        XCTAssertTrue(pages.waitForExistence(timeout: 60), "Discover has no billboard pages")
        XCTAssertTrue((pages.value as? String)?.hasPrefix("Page ") == true)
        let previousPage = try XCTUnwrap(pages.value as? String)
        contentWindow.swipeLeft()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", previousPage), object: pages)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Swiping did not page the billboard")
        let myList = element("home.featured.my-list")
        XCTAssertTrue(myList.exists)
        myList.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Saved"), object: myList)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        try checkpoint("discover-billboard")
        launch("library")
        XCTAssertTrue(element("library.sort").waitForExistence(timeout: 60), "Library did not draw")
        try checkpoint("library")
        launch("settings")
        XCTAssertTrue(element("settings.sources").waitForExistence(timeout: 60), "Settings did not draw")
        let shownSection = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND selected == true", "Sources")).firstMatch
        XCTAssertTrue(shownSection.waitForExistence(timeout: 10), "Settings is not a sidebar and a pane")
        try checkpoint("settings")
    }

    func testLiveStageGuideAndSearchUseTheOnNowList() throws {
        launch("live")
        XCTAssertTrue(element("live.stage.player").waitForExistence(timeout: 60))
        XCTAssertTrue(element("live.categories").exists)
        XCTAssertTrue(element("live.list").exists)
        let channel = app.buttons.matching(NSPredicate(format: "label == %@", "Play Fixture News")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 20))
        #if os(iOS)
        // Paramount+ on iPad (owner 2026-10-21): the stage spans the window, the list fills the rest below it.
        let stage = element("live.stage.player")
        XCTAssertEqual(stage.frame.width, app.frame.width, accuracy: 1)
        XCTAssertGreaterThan(element("live.guide").frame.minY, stage.frame.maxY - 1)
        XCTAssertGreaterThan(channel.frame.minY, stage.frame.maxY - 1)
        #endif
        try checkpoint("live-stage")
        element("live.guide").tap()
        let done = element("live.guide.done")
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        let guideReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [guideReady], timeout: 5), .completed, "The Guide did not finish presenting")
        try checkpoint("live-guide")
        done.tap()
        element("live.search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Fixture News\n")
        XCTAssertTrue(channel.waitForExistence(timeout: 15))
        try checkpoint("live-search")
        // A row on the stage plays in the frame above the list. (Choosing a
        // search result does not switch the channel on the iPad either.)
        launch("live")
        XCTAssertTrue(channel.waitForExistence(timeout: 60))
        channel.tap()
        let playing = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Live player for Fixture News")).firstMatch
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: playing)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 45), .completed, "The channel did not play inline")
        #if os(visionOS)
        try checkpoint("live-inline")
        #else
        capture("live-inline")
        #endif
    }

    #if os(iOS)
    func testLiveSearchDifferentChannelRestoresIPadNavigation() throws {
        launch("live")
        try checkLiveSearchSelection(channelName: "CBS")
    }

    func testLiveSearchSameChannelRestoresIPadNavigation() throws {
        launch("live")
        try checkLiveSearchSelection(channelName: "Fixture News")
    }

    /// A start that does not come from the search results (a Live TV link)
    /// still takes the Search page down.
    func testLiveLinkWhileSearchingDismissesSearch() throws {
        launch("live")
        let stage = element("live.stage.player")
        let row = app.buttons["Play Fixture Film"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        let channelID = String(row.identifier.dropFirst("guide.play.".count))
        let link = try XCTUnwrap(URL(string: "openstream://live/" + channelID))

        element("live.search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        app.open(link)
        let dialog = app.sheets["Play Live TV"]
        let confirm = dialog.buttons["Play"].firstMatch
        // The dialog first shows centred, then moves to its popover anchor as the
        // app reactivates; a tap during that move is dropped, so tap the settled one.
        for _ in 1...2 where dialog.exists || dialog.waitForExistence(timeout: 15) {
            let asked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: confirm)
            XCTAssertEqual(XCTWaiter.wait(for: [asked], timeout: 15), .completed, "The Live TV link asked nothing")
            confirm.tap()
            let answered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dialog)
            if XCTWaiter.wait(for: [answered], timeout: 3) == .completed { break }
        }

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, "A Live TV link left Live search open")
        let close = element("player.close")
        if !close.waitForExistence(timeout: 5) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            XCTAssertTrue(close.waitForExistence(timeout: 15), "The link did not open the player")
        }
        XCTAssertTrue(close.isHittable, "The visible Close control cannot receive a tap")
        close.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: element("player.controls.show"))
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed, "Close left the full-screen player open")
        for title in ["Discover", "Library", "Live", "Settings"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 10), "The \(title) tab disappeared")
        }
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label == 'Live player for Fixture Film'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 45), .completed, "The stage did not move to Fixture Film")
        capture("live-link-while-searching")
    }

    /// Owner iPad 2026-10-28: the tabs went while a playlist reload was still waiting for
    /// the provider. The second launch shows the saved lineup and its reload never answers.
    func testLiveSearchSelectionDuringAPendingReloadRestoresIPadNavigation() throws {
        launch("live")
        XCTAssertTrue(app.buttons["Play Fixture News"].firstMatch.waitForExistence(timeout: 60))
        launch("live", resets: false, arguments: ["-OpenStreamStubPlaylistStall", "600"])
        try checkLiveSearchSelection(channelName: "CBS")
    }

    private func checkLiveSearchSelection(channelName: String) throws {
        let stage = element("live.stage.player")
        let initialChannel = app.buttons["Play Fixture News"].firstMatch
        XCTAssertTrue(initialChannel.waitForExistence(timeout: 60))
        initialChannel.tap()
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == 'Playing' AND label == 'Live player for Fixture News'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 60), .completed)
        let tabTitles = ["Discover", "Library", "Live", "Settings"]
        for title in tabTitles {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 10))
        }

        element("live.search").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(channelName + "\n")
        let excludedName = channelName == "CBS" ? "Fixture News" : "CBS"
        let excluded = app.buttons["Play " + excludedName].firstMatch
        let filtered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: excluded)
        XCTAssertEqual(XCTWaiter.wait(for: [filtered], timeout: 10), .completed)
        let channel = app.buttons["Play " + channelName].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 15))
        channel.tap()

        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, "Selecting a channel kept Live search open")
        // Past the field's end, the fallback pop and the start that follows the pick:
        // the tabs used to go after Search had already left.
        Thread.sleep(forTimeInterval: 3)
        for title in tabTitles {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "The \(title) tab disappeared after Live search")
            XCTAssertTrue(tab.isHittable)
        }
        XCTAssertTrue(excluded.waitForExistence(timeout: 10), "Live kept the search filter after selection")
        XCTAssertTrue(element("live.search").isHittable)
        XCTAssertTrue(element("live.guide").isHittable)
        XCTAssertFalse(element("player.close").exists, "A search selection opened the full-screen player")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == 'Playing' AND label == %@", "Live player for " + channelName), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 45), .completed, "The stage did not select \(channelName)")
        capture("live-search-selected-" + channelName)

        element("live.search").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 15), "Live search did not open again")
        // Observed on iPadOS 26.x: Back is drawn at the bar's leading edge, level with the
        // field, but is not in the accessibility tree while the field is focused.
        let searchBar = app.navigationBars["Search"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 10))
        // A tap while the push is still settling is dropped, so tap again until Search leaves.
        for _ in 1...3 where field.exists {
            searchBar.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 32, dy: field.frame.midY - searchBar.frame.minY)).tap()
            let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: field)
            _ = XCTWaiter.wait(for: [left], timeout: 3)
        }
        XCTAssertFalse(field.exists, "Back did not leave Live search")
        for title in tabTitles {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 10), "Back from search lost the \(title) tab")
        }

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(element("settings.sources").waitForExistence(timeout: 30))
        app.buttons["Live"].firstMatch.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 30))
    }
    #endif

    /// The fixture Jellyfin's Stub Series (`Tests/Fixtures/serve.py`): two seasons of three chapters.
    func testSeriesHasEpisodeRailAndSeasonMenu() throws {
        launch("detail")
        XCTAssertTrue(screen("detail.screen.series.").waitForExistence(timeout: 60))
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        try checkpoint("series-hero")
        let rail = element("detail.episodes")
        scrollTo(rail)
        XCTAssertTrue(rail.exists)
        let seasonOne = rail.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 1."))
        XCTAssertTrue(seasonOne.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(seasonOne.count, 2)
        XCTAssertEqual(seasonOne.element(boundBy: 0).frame.minY, seasonOne.element(boundBy: 1).frame.minY,
                       accuracy: 2, "Episodes are stacked instead of a rail")
        try checkpoint("series-episodes")
        element("detail.season").tap()
        let seasonTwo = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "detail.season.2", "Season 2")).firstMatch
        XCTAssertTrue(seasonTwo.waitForExistence(timeout: 10))
        #if os(visionOS)
        try checkpoint("series-season-menu")
        #else
        capture("series-season-menu")
        #endif
        seasonTwo.tap()
        XCTAssertTrue(rail.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 2.1")).firstMatch
            .waitForExistence(timeout: 15), "Season 2's episodes did not load")
        try checkpoint("series-season-two")
    }

    func testMovieHeroHasMetadataAndPlay() throws {
        launch("detail-movie")
        XCTAssertTrue(screen("detail.screen.movie.").waitForExistence(timeout: 60))
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        XCTAssertTrue(element("detail.play").isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Stub Movie")).firstMatch.exists)
        try checkpoint("movie-hero")
    }

    func testPortraitTitleHeroContainsThePlayAction() throws {
        #if os(visionOS)
        launch("detail-movie", size: CGSize(width: Self.smallestSize.width, height: 1100))
        #else
        launch("detail-movie", size: CGSize(width: 820, height: 1180))
        #endif
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, "Play is not reachable upright")
        XCTAssertLessThan(play.frame.maxY, contentWindow.frame.maxY, "Play fell below the window")
        try checkpoint("movie-hero-portrait")
    }

    func testLargestTextKeepsRowsTitleAndLiveActionsReachable() throws {
        launch("discover", largestText: true)
        #if os(visionOS)
        XCTAssertTrue(element("home.featured.pages").waitForExistence(timeout: 60), "Discover has no featured titles")
        try checkpoint("discover-largest-text-hero")
        #endif
        let poster = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.ms.")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 60))
        scrollTo(poster)
        XCTAssertTrue(poster.isHittable, "The largest text size hid Discover's first row")
        #if os(visionOS)
        try checkpoint("discover-largest-text")
        #else
        capture("discover-largest-text")
        #endif
        launch("library", largestText: true)
        XCTAssertTrue(element("library.sort").waitForExistence(timeout: 60))
        #if os(visionOS)
        try checkpoint("library-largest-text")
        #else
        capture("library-largest-text")
        #endif
        launch("detail-movie", largestText: true)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        #if os(visionOS)
        scrollTo(play)
        #endif
        XCTAssertTrue(play.isHittable, "The largest text size hid Play")
        #if os(visionOS)
        try checkpoint("movie-largest-text")
        #else
        capture("movie-largest-text")
        #endif
        launch("detail", largestText: true)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 60))
        let episodes = element("detail.episodes")
        scrollTo(episodes)
        XCTAssertTrue(episodes.exists)
        #if os(visionOS)
        try checkpoint("episodes-largest-text")
        #else
        capture("episodes-largest-text")
        #endif
        launch("live", largestText: true)
        XCTAssertTrue(element("live.list").waitForExistence(timeout: 60), "Live channel list did not load")
        let channel = app.buttons.matching(NSPredicate(format: "label == %@", "Play Fixture News")).firstMatch
        // The largest iPad text size puts the lazy channel rows below the stage.
        scrollTo(channel)
        XCTAssertTrue(channel.waitForExistence(timeout: 60))
        XCTAssertTrue(channel.isHittable, "The largest text size hid the channel list")
        #if os(visionOS)
        try checkpoint("live-largest-text")
        #else
        capture("live-largest-text")
        #endif
    }

    #if os(visionOS)
    func testSmallestWindowKeepsTheIPadLayout() throws {
        launch("live", size: Self.smallestSize)
        let channel = app.buttons.matching(NSPredicate(format: "label == %@", "Play Fixture News")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 60))
        XCTAssertTrue(channel.isHittable)
        let player = element("live.stage.player")
        XCTAssertGreaterThan(channel.frame.minX, player.frame.maxX - 1,
                             "The channel list left the player's side in the smallest window")
        try checkpoint("live-stage-smallest")
        launch("detail", size: Self.smallestSize)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        XCTAssertTrue(play.isHittable)
        try checkpoint("series-hero-smallest")
    }
    #endif

    private func launch(_ screen: String, size: CGSize = ApplePadParityUITests.defaultSize, largestText: Bool = false,
                        resets: Bool = true, arguments: [String] = []) {
        continueAfterFailure = false
        if !teardownAdded {
            teardownAdded = true
            addTeardownBlock { @MainActor [self] in
                defer {
                    app.terminate()
                    #if os(iOS)
                    XCUIDevice.shared.orientation = .portrait
                    #endif
                }
                if let run = testRun, run.totalFailureCount > 0 { capture("failure-\(name)") }
            }
        }
        #if os(iOS)
        XCUIDevice.shared.orientation = size.width > size.height ? .landscapeLeft : .portrait
        #endif
        app.terminate()
        app.launchArguments = ["-OpenStreamStubNetwork", stubs, "-OpenStreamResetOnLaunch", resets ? "YES" : "NO",
            "-OpenStreamStubMediaBase", "http://127.0.0.1:8767", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamTrace", "YES", "-openstream.firstRunGuidanceSeen", "YES",
            "-openstream.backup.icloud.enabled.v1", "NO", "-OpenStreamVisionScreen", screen,
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments += arguments
        #if os(visionOS)
        app.launchArguments += ["-OpenStreamVisionWindowCapture", "YES",
                                "-OpenStreamVisionBrowseWidth", String(Int(size.width)),
                                "-OpenStreamVisionBrowseHeight", String(Int(size.height))]
        #endif
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        #if os(visionOS)
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let window = object as? XCUIElement else { return false }
            let frame = window.frame
            return frame.height > 0 && abs(frame.width / frame.height - size.width / size.height) <= 0.02
        }, object: contentWindow)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 15), .completed, "The window did not take its requested size")
        #endif
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func screen(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private var contentWindow: XCUIElement {
        app.windows.allElementsBoundByIndex.filter { $0.frame.width >= 480 && $0.frame.height >= 260 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app.windows.firstMatch
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists, element.isHittable,
               element.frame.midY < contentWindow.frame.maxY - 80 { return }
            #if os(visionOS)
            contentWindow.swipeUp()
            #else
            let start = contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.82))
            let end = contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.30))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            #endif
        }
    }

    /// A screenshot and the accessibility tree, plus the system audit's
    /// findings as attachments. iPad keeps its comparison record; visionOS
    /// requires every audit to pass.
    private func checkpoint(_ name: String) throws {
        capture(name)
        var findings: [String] = []
        try app.performAccessibilityAudit { issue in
            findings.append(issue.detailedDescription + "\n" + (issue.element?.debugDescription ?? "Application-level issue"))
            return true
        }
        let audit = XCTAttachment(string: findings.isEmpty ? "No findings" : findings.joined(separator: "\n\n"))
        audit.name = "\(name)-audit-\(findings.count)"
        audit.lifetime = .keepAlways
        add(audit)
        #if os(visionOS)
        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "\n\n"))
        #endif
    }

    /// The Vision Pro simulator's `XCUIScreen` screenshot comes back blank, so
    /// a runner can pass `OPENSTREAM_VISION_CAPTURE_URL`, an endpoint on the
    /// host that saves `simctl io screenshot` under `?name=`.
    private func capture(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
        guard let endpoint = ProcessInfo.processInfo.environment["OPENSTREAM_VISION_CAPTURE_URL"],
              var components = URLComponents(string: endpoint) else {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            return
        }
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        components.queryItems = [URLQueryItem(name: "name", value: safeName)]
        guard let url = components.url else { return XCTFail("Bad capture endpoint \(endpoint)") }
        let saved = expectation(description: "capture \(name)")
        URLSession.shared.dataTask(with: url) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Host capture of \(name) failed")
            saved.fulfill()
        }.resume()
        wait(for: [saved], timeout: 30)
    }
}
#endif
