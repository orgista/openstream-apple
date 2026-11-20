import XCTest

@MainActor
final class AppleVisionDeviceSmokeUITests: XCTestCase {
    func testTheAppAndItsOrnamentOpen() throws {
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { app.terminate() }
        app.launchArguments = ["-OpenStreamTrace", "YES"]
        #if targetEnvironment(simulator)
        if let stubs = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"] {
            app.launchArguments += ["-OpenStreamStubNetwork", stubs,
                                    "-OpenStreamStubMediaBase", "http://127.0.0.1:8767"]
        }
        #endif
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        XCTAssertTrue(app.buttons["gearshape"].firstMatch.waitForExistence(timeout: 45))
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "vision-device-launch"
        tree.lifetime = .keepAlways
        add(tree)
        try app.performAccessibilityAudit()
        #if !targetEnvironment(simulator)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "vision-device-launch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}

/// Vision Pro: the player lives inside the app's one window, takes the
/// film's shape while it plays, and gives the window back as it was
/// (owner, 2026-10-07). Plays the loopback fixtures from
/// `Tests/Fixtures/serve.py` (`OPENSTREAM_FIXTURE_BASE`, default
/// http://127.0.0.1:8765), entered through Settings › Add Files › Direct URL
/// the way a viewer would.
///
/// `OPENSTREAM_VISION_CAPTURE_URL` is the runner's loopback service that
/// supplies a compositor PNG or the Debug app's window canvas: `XCUIScreen`
/// returns a 1×1 placeholder on this runtime.
@MainActor
final class AppleVisionPlayerUITests: XCTestCase {
    private let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")

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
    private func prepare(screen: String? = "add-files", reset: Bool = true, firstLaunch: Bool = false,
                         extra: [String] = []) {
        continueAfterFailure = false
        if !teardownAdded {
            teardownAdded = true
            addTeardownBlock { @MainActor [self] in
                if let run = testRun, run.totalFailureCount > 0 {
                    capture("failure-\(name)")
                    let tree = XCTAttachment(string: app.debugDescription)
                    tree.name = "failure-accessibility"; tree.lifetime = .keepAlways; add(tree)
                }
                app.terminate()
            }
        }
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamVisionWindowCapture", "YES",
                               "-OpenStreamProbeVideoFrames", "YES",
                               "-OpenStreamMuteAudio", "YES", "-openstream.backup.icloud.enabled.v1", "NO",
                               "-openstream.settings.trailer.autoplay.v1", "NO"]
        if reset { app.launchArguments += ["-OpenStreamResetOnLaunch", "YES"] }
        if !firstLaunch { app.launchArguments += ["-openstream.firstRunGuidanceSeen", "YES"] }
        if let screen { app.launchArguments += ["-OpenStreamVisionScreen", screen] }
        app.launchArguments += extra
        if let stubs = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"] {
            app.launchArguments += ["-OpenStreamStubNetwork", stubs,
                                    "-OpenStreamStubMediaBase", fixtureBase]
        }
    }

    // MARK: Tests

    func testLiveReconnectShowsOneLoadingIndicator() async throws {
        continueAfterFailure = false
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        let (_, reset) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/reset"))
        XCTAssertEqual((reset as? HTTPURLResponse)?.statusCode, 200)
        launchPage(nil, extra: ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", base.appendingPathComponent("reconnect/index.m3u8").absoluteString,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-openstream.playback.engine", "native"])
        let stage = element("live.stage.player")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        await fulfillment(of: [playing], timeout: 45)
        let (_, stalled) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/stall"))
        XCTAssertEqual((stalled as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(element("live.reconnecting").waitForExistence(timeout: 90))
        let indicators = app.descendants(matching: .any).matching(identifier: "live.loading")
        XCTAssertEqual(indicators.count, 1, "Reconnect must have one loading indicator")
        XCTAssertEqual(indicators.firstMatch.label, "Reconnecting")
        let stageFrame = stage.frame
        let visibleIndicators = (app.activityIndicators.allElementsBoundByAccessibilityElement
            + app.progressIndicators.allElementsBoundByAccessibilityElement).filter {
            !$0.frame.isEmpty && stageFrame.intersects($0.frame)
                && $0.descendants(matching: .activityIndicator).count == 0
                && $0.descendants(matching: .progressIndicator).count == 0
        }
        XCTAssertEqual(visibleIndicators.count, 1, "Reconnect must not leave an unnamed spinner visible")
        capture("vision-live-reconnecting-indicator")
    }

    private func launchLocalLivePlaylist(_ playlist: String) throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-live-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [
            ["kind": "m3u", "name": "IPTV", "playlistURL": base.appendingPathComponent(playlist).absoluteString]
        ]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        launchPage("live", extra: ["-OpenStreamDevSources", file.path, "-OpenStreamHoldPlayerChrome", "YES",
                                  "-OpenStreamStubLiveBase", base.absoluteString,
                                  "-openstream.settings.live.package.v1", "everything"])
    }

    func testSlidingLiveStartsAtTheEdgeAndItsInlineControlsMatch() throws {
        try launchLocalLivePlaylist("sliding/channels.m3u")
        continueAfterFailure = true
        let stage = element("live.stage.player")
        XCTAssertTrue(stage.waitForExistence(timeout: 30))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed)
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live initial edge joined") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 10), .completed)
        capture("vision-live-inline-controls-at-edge")
        let mute = element("player.mute")
        let full = element("player.fullscreen")
        XCTAssertTrue(mute.exists)
        XCTAssertTrue(full.exists)
        XCTAssertEqual(mute.frame.width, full.frame.width, accuracy: 1)
        XCTAssertEqual(mute.frame.height, full.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(full.frame.height, 60)
        full.tap()
        XCTAssertTrue(waitForPlayer())
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        pausePlayerForFrameCapture(custom: false)
        XCTAssertTrue(waitUntilHittable(element("player.close"), timeout: 10))
        assertPlayerControlFrames(["player.close", "player.more"], name: "vision-live-fullwindow-top")
        capture("vision-live-fullwindow-controls-at-edge")
        element("player.more").tap()
        let sleepTimer = element("player.sleepTimer")
        XCTAssertTrue(sleepTimer.waitForExistence(timeout: 5))
        sleepTimer.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        capture("vision-live-more-sleep-timer")
        off.tap()
        XCTAssertTrue(waitUntilHittable(element("player.close"), timeout: 10))
        element("player.close").tap()
        XCTAssertTrue(full.waitForExistence(timeout: 10))
    }

    func testVODControlRowsHaveMatchingFrames() throws {
        for engine in ["native", "engine"] {
            launchPage("add-files", extra: ["-OpenStreamVisionPlaybackURL", fixtureBase + "/media/e2e-long.mp4",
                "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", engine,
                "-OpenStreamHoldPlayerChrome", "YES"])
            continueAfterFailure = true
            XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
            contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
            let custom = element("player.options").exists
            if custom {
                pausePlayerForFrameCapture(custom: true)
            } else {
                element("UIA.LinearMediaKit.PlaybackControls.toggle-playback").tap()
            }
            capture("vision-vod-\(engine)-visible-controls")
            assertPlayerControlFrames(["player.close", custom ? "player.options" : "player.more"], name: "vision-vod-\(engine)-top")
            if custom {
                assertPlayerControlFrames(["player.skip-back", "player.play-pause", "player.skip-forward"],
                                          name: "vision-vod-\(engine)-transport")
                assertPlayerControlFrames(["player.captions"], name: "vision-vod-\(engine)-captions")
            } else {
                assertPlayerControlFrames(["UIA.LinearMediaKit.PlaybackControls.go-backward",
                    "UIA.LinearMediaKit.PlaybackControls.toggle-playback", "UIA.LinearMediaKit.PlaybackControls.go-forward"],
                                          name: "vision-vod-\(engine)-native-transport")
            }
            capture("vision-vod-\(engine)-native-transport")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "vision-vod-\(engine)-native-control-frames"; tree.lifetime = .keepAlways; add(tree)
            app.terminate()
        }
    }

    private func pausePlayerForFrameCapture(custom: Bool) {
        let toggle = element(custom ? "player.play-pause" : "UIA.LinearMediaKit.PlaybackControls.toggle-playback")
        if !toggle.exists { contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.label == "Pause" { toggle.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
    }

    private func assertPlayerControlFrames(_ identifiers: [String], name: String) {
        let controls = identifiers.map(element)
        for (identifier, control) in zip(identifiers, controls) { XCTAssertTrue(control.exists, "Missing \(identifier)") }
        guard controls.allSatisfy(\.exists), let first = controls.first else { return }
        for control in controls {
            XCTAssertEqual(control.frame.width, first.frame.width, accuracy: 1)
            XCTAssertEqual(control.frame.height, first.frame.height, accuracy: 1)
            XCTAssertEqual(control.frame.midY, first.frame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(control.frame.width, 60)
            XCTAssertGreaterThanOrEqual(control.frame.height, 60)
        }
        let record = XCTAttachment(string: zip(identifiers, controls).map { "\($0): \($1.frame)" }.joined(separator: "\n"))
        record.name = name + "-frames"; record.lifetime = .keepAlways; add(record)
        capture(name)
    }

    func testStalledLiveOriginStopsLoading() throws {
        try launchLocalLivePlaylist("failure/channels.m3u")
        let failed = element("live.failure.retry")
        XCTAssertTrue(failed.waitForExistence(timeout: 30))
        XCTAssertEqual(failed.label, "Retry")
        XCTAssertTrue(app.staticTexts["Can’t reach this channel’s server"].exists)
        assertPlayerControlFrames(["live.failure.retry"], name: "vision-live-failure-retry")
        capture("vision-live-stalled-origin-after-deadline")
        XCTAssertTrue(element("live.list").exists)
    }

    func testMediaServerLibraryLoadShowsConnectedInSources() throws {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"])
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-server-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [
            ["kind": "mediaServer", "server": "jellyfin", "name": "Rill", "url": base.appendingPathComponent("jf").absoluteString,
             "username": "fixture", "password": "fixture"]]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        launchPage("discover", extra: ["-OpenStreamDevSources", file.path, "-OpenStreamStubLiveBase", base.absoluteString])
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("dev sources: done") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 20), .completed)
        launchPage("source-detail", reset: false, extra: ["-OpenStreamStubLiveBase", base.absoluteString])
        XCTAssertTrue(app.staticTexts["Health, Connected"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Connected · '")).firstMatch.exists)
        capture("vision-sources-rill-connected")
    }

    func testStalledPlaylistKeepsSavedChannelsWithoutAnImmediateWarning() throws {
        try launchLocalLivePlaylist("saved/channels.m3u")
        XCTAssertTrue(element("live.list").waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Play Fixture Live 1"].firstMatch.waitForExistence(timeout: 30))
        try stallOpenStreamSavedPlaylist()
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"])
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        app.terminate()
        launchPage("live", reset: false, extra: ["-OpenStreamStubLiveBase", base.absoluteString])
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live playlist failed: IPTV saved=true") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 45), .completed)
        XCTAssertFalse(element("live.sourceError").exists)
        app.terminate()
        launchPage("source-detail", reset: false, extra: ["-OpenStreamStubLiveBase", base.absoluteString])
        XCTAssertTrue(app.staticTexts["Health, Showing saved channels"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS 'Showing saved channels · last updated '")).firstMatch.exists)
        capture("vision-sources-saved-channels-after-timeout")
    }

    /// One window before, during and after; the player is in it; the window
    /// keeps its width, turns 16:9 while playing and comes back exactly; the
    /// tab ornament leaves and returns; the page underneath is untouched.
    func testThePlayerLivesInTheWindowAndGivesItBack() throws {
        launch()
        let before = contentWindow.frame
        let tabsBefore = element("books.vertical").exists
        XCTAssertEqual(windowCount, 1, "More than one window before playback")
        try checkpoint("vision-01-before-play")

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
        try checkpoint("vision-02-playing")

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
        try checkpoint("vision-03-after-close")
    }

    /// A clip that plays to its end closes the player and restores the window.
    func testAClipThatEndsGivesTheWindowBack() throws {
        launch()
        let before = contentWindow.frame
        try play(clipURL)
        XCTAssertTrue(waitForPlayer(), "The player never appeared")
        XCTAssertEqual(windowCount, 1)
        try checkpoint("vision-clip-playing")
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
        try checkpoint("vision-04-failure")
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
        launchPage("add-files", reset: false)
        XCTAssertTrue(waitUntilHittable(directURLRow, timeout: 30))
        XCTAssertEqual(windowCount, 1, "A relaunch after playback brought back more than one window")
        XCTAssertFalse(playerCloseExists, "A relaunch reopened the player")
        try checkpoint("vision-one-window-relaunch")
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

    // MARK: Crawl

    func testFirstLaunchCanAddANetworkShare() throws {
        let seed = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vision-empty-sources.json")
        try Data(#"{"version":1,"sources":[]}"#.utf8).write(to: seed)
        defer { try? FileManager.default.removeItem(at: seed) }
        launchPage(nil, firstLaunch: true, extra: ["-OpenStreamDevSources", seed.path,
                                                   "-OpenStreamDebugNetworkShareFixture", "add"])
        let notNow = app.buttons["Not Now"].firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 30))
        try checkpoint("first-launch-welcome")
        notNow.tap()
        XCTAssertTrue(app.staticTexts["No Sources"].waitForExistence(timeout: 30))
        try checkpoint("first-launch-no-sources")
        app.buttons["Open Settings"].firstMatch.tap()
        let share = app.buttons["Network Share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        share.tap()
        let add = element("sources.smb.add")
        XCTAssertTrue(waitUntilHittable(add, timeout: 20))
        try checkpoint("share-confirm")
        add.tap()
        XCTAssertTrue(app.buttons["Network Share"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sources.smb.saved.'")).firstMatch.waitForExistence(timeout: 15),
                      "The added share is missing from Sources")
        XCTAssertFalse(app.staticTexts["No Sources"].exists, "Adding the share left Sources empty")
        try checkpoint("share-added")
    }

    func testEveryOrnamentTabHasContentAndSearchFindsATitle() throws {
        launchPage("discover")
        let shelf = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.ms.'")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 60), "Discover has no media-server titles")
        assertNamedButtons(prefix: "home.ms.")
        try checkpoint("discover-filled")
        contentWindow.swipeUp()
        XCTAssertTrue(shelf.isHittable, "Discover's poster row is not reachable")
        try checkpoint("discover-rows")
        tapTab("Library")
        let title = element("library.title.Stub Movie One")
        XCTAssertTrue(title.waitForExistence(timeout: 60), "The seeded folder did not reach Library")
        XCTAssertFalse(title.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try checkpoint("library-filled")
        tapTab("Live")
        let channel = app.buttons["Play Fixture News"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 60))
        XCTAssertFalse(channel.label.isEmpty)
        XCTAssertTrue(element("live.stage.player").exists)
        try checkpoint("live-filled")
        tapTab("Settings")
        XCTAssertTrue(element("settings.sources").waitForExistence(timeout: 20))
        try checkpoint("settings-from-ornament")
        tapTab("Discover")
        app.buttons["Search"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(waitUntilHittable(search, timeout: 15))
        search.tap()
        search.typeText("Stub Movie Two\n")
        let match = app.staticTexts["Stub Movie Two"].firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 30), "Search did not find a fixture movie")
        try checkpoint("search-results")
        match.tap()
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        try checkpoint("search-title")
    }

    func testFixtureLiveSourceCanBeAddedDisabledAndDeleted() throws {
        launchPage("add-live", extra: ["-OpenStreamStubLiveBase", fixtureBase])
        for (label, value) in [("Name", "Fullpass Live"), ("Server URL", fixtureBase), ("Username", "fixture")] {
            let field = app.textFields[label].firstMatch
            XCTAssertTrue(waitUntilHittable(field, timeout: 30))
            field.tap()
            field.typeText(value)
        }
        let password = app.secureTextFields["Password"].firstMatch
        XCTAssertTrue(waitUntilHittable(password, timeout: 10))
        password.tap()
        password.typeText("fixture")
        element("sources.live.save").tap()
        let notNow = app.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 10) { notNow.tap() }
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fullpass Live'")).firstMatch
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 15))
        let sourcesList = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX })
        scrollTo(source, in: sourcesList)
        XCTAssertTrue(waitUntilHittable(source, timeout: 10))
        source.tap()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 15))
        let detailList = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX })
        let enabled = app.switches["Enabled"].firstMatch
        scrollTo(enabled, in: detailList)
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "1")
        try checkpoint("vision-source-added")
        let control = enabled.switches.firstMatch
        (control.exists ? control : enabled).tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        try checkpoint("vision-source-disabled")
        let delete = app.buttons["Delete Source"].firstMatch
        scrollTo(delete, in: detailList)
        XCTAssertTrue(waitUntilHittable(delete, timeout: 10))
        delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(waitUntilHittable(confirm, timeout: 10))
        confirm.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        try checkpoint("vision-source-deleted")
    }

    func testTitlePageSectionSwitchesKeepPlaybackAndEpisodes() throws {
        launchPage("detail")
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 60))
        let names = ["trailers", "cast", "information", "about"]
        let sections = ["detail.trailers", "detail.cast", "detail.information", "detail.languages", "detail.about"]
        var enabledSections = Set<String>()
        for (visit, enabled) in [true, false, true].enumerated() {
            tapTab("Settings")
            let general = element("settings.general")
            scrollTo(general, towardTop: true)
            XCTAssertTrue(waitUntilHittable(general, timeout: 10))
            general.tap()
            for name in names {
                let toggle = element("settings.titlePage.\(name)")
                scrollTo(toggle)
                XCTAssertTrue(waitUntilHittable(toggle, timeout: 10))
                let wanted = enabled ? "1" : "0"
                if toggle.value as? String != wanted {
                    let control = toggle.switches.firstMatch
                    (control.exists ? control : toggle).tap()
                }
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            }
            try checkpoint("vision-title-switches-\(visit)-\(enabled ? "on" : "off")")
            tapTab("Discover")
            let play = element("detail.play")
            for _ in 0..<8 where !play.exists || !play.isHittable { contentWindow.swipeDown() }
            XCTAssertTrue(play.waitForExistence(timeout: 15))
            XCTAssertTrue(play.isEnabled)
            XCTAssertTrue(element("detail.episodes").waitForExistence(timeout: 15))
            var shown = Set<String>()
            for _ in 0..<8 {
                for identifier in sections where element(identifier).exists { shown.insert(identifier) }
                contentWindow.swipeUp()
            }
            try checkpoint("vision-title-sections-\(visit)-\(enabled ? "on" : "off")")
            if !enabled { XCTAssertTrue(shown.isEmpty, "Disabled title-page sections remain visible") }
            else {
                XCTAssertTrue(shown.contains("detail.information"), "Enabled Information is missing")
                if visit == 0 { enabledSections = shown }
                else { XCTAssertEqual(shown, enabledSections, "Re-enabling the sections must restore them") }
            }
        }
    }

    func testSettingsPagesOpenAndReturnToSources() throws {
        launchPage("settings")
        for name in ["Channel Manager", "Restrictions", "Backup & Sync", "Channel Health",
                     "Metadata", "Streaming Services", "Playback", "Privacy", "Storage", "About"] {
            let row = app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            scrollTo(row)
            XCTAssertTrue(waitUntilHittable(row, timeout: 10), "Cannot open \(name)")
            row.tap()
            let selected = app.buttons.matching(NSPredicate(format: "label == %@ AND selected == true", name)).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 10), "\(name) did not become the selected page")
            try checkpoint("settings-" + name.replacingOccurrences(of: " ", with: "-"))
        }
        let sources = element("settings.sources")
        scrollTo(sources, towardTop: true)
        sources.tap()
        XCTAssertTrue(app.buttons["Network Share"].firstMatch.waitForExistence(timeout: 15))
        try checkpoint("settings-return-sources")
    }

    func testMovieVersionsAndServerTrailerPlayInTheWindow() throws {
        launchPage("detail-movie", extra: ["-OpenStreamDetailTitle", "Stub Movie Two"])
        let play = element("detail.play")
        XCTAssertTrue(waitUntilHittable(play, timeout: 60))
        XCTAssertTrue(app.staticTexts["Stub Movie Two"].firstMatch.exists)
        try checkpoint("movie-metadata")
        play.press(forDuration: 1)
        let versions = app.buttons["Play version…"].firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 15), "The movie has no versions menu")
        versions.tap()
        let alternate = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Alternate'")).firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout: 10))
        try checkpoint("movie-versions")
        alternate.tap()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        XCTAssertEqual(windowCount, 1)
        try closePlayer()
        let trailer = element("detail.serverTrailer")
        XCTAssertTrue(waitUntilHittable(trailer, timeout: 20))
        trailer.tap()
        XCTAssertTrue(element("trailer.player.playing").waitForExistence(timeout: 45))
        XCTAssertEqual(windowCount, 1)
        try checkpoint("movie-server-trailer")
        XCTAssertTrue(waitUntilHittable(play, timeout: 60), "The title did not return after the trailer ended")
    }

    func testTintControlsInLightAndDark() throws {
        executionTimeAllowance = 600
        for appearance in ["light", "dark"] {
            launchPage("detail-movie", extra: ["-OpenStreamDetailTitle", "Stub Movie Two",
                "-OpenStreamDebugColorScheme", appearance])
            let play = element("detail.play")
            XCTAssertTrue(waitUntilHittable(play, timeout: 60))
            capture("vision-tint-prominent-" + appearance)
            app.buttons["Rate"].firstMatch.tap()
            XCTAssertTrue(app.buttons["I Like This"].firstMatch.waitForExistence(timeout: 15))
            capture("vision-tint-menu-" + appearance)
            launchPage("about", extra: ["-OpenStreamDebugColorScheme", appearance])
            let acknowledgements = element("settings.about.acknowledgements")
            XCTAssertTrue(waitUntilHittable(acknowledgements, timeout: 10))
            acknowledgements.tap()
            let link = element("settings.acknowledgements.sourceCode")
            scrollTo(link, in: app.collectionViews.allElementsBoundByIndex.last)
            XCTAssertTrue(waitUntilHittable(link, timeout: 15))
            capture("vision-tint-link-" + appearance)
        }
    }

    func testReplayAndSeekAfterPlaybackEndsKeepDecodedVideo() throws {
        executionTimeAllowance = 600
        launchPage("add-files", extra: ["-OpenStreamVisionPlaybackURL", fixtureBase + "/media/e2e-long.mp4",
            "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", "engine",
            "-OpenStreamHoldPlayerChrome", "YES"])
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        let initialFrame = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS 'ready=1'"), object: element("player.video.frame"))
        XCTAssertEqual(XCTWaiter.wait(for: [initialFrame], timeout: 30), .completed)
        pausePlayback()
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        seek(slider, to: 0.98)
        let transport = element("player.play-pause")
        transport.tap()
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 45), .completed)
        let finalFrame = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value CONTAINS 'ready=1'"), object: element("player.video.frame"))
        XCTAssertEqual(XCTWaiter.wait(for: [finalFrame], timeout: 10), .completed)
        capture("playback-ended")
        transport.tap()
        let replaying = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            transport.label == "Pause" && Self.playbackSeconds(slider.value as? String ?? "") < 30
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [replaying], timeout: 10), .completed)
        try assertDecodedVideoFrame("replay-after-end")
        pausePlayback()
        seek(slider, to: 0.98)
        transport.tap()
        let endedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [endedAgain], timeout: 45), .completed)
        seek(slider, to: 0.25)
        try assertDecodedVideoFrame("seek-after-end")
    }

    func testAudioTrackSwitchKeepsDecodedVideoFrame() throws {
        executionTimeAllowance = 600
        launchPage("add-files", extra: ["-OpenStreamVisionPlaybackURL", fixtureBase + "/media/e2e-long.mp4",
            "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", "engine",
            "-OpenStreamHoldPlayerChrome", "YES"])
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        try assertDecodedVideoFrame("audio-switch-before")
        pausePlayback()
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        seek(slider, to: 0.25)
        let position = Self.playbackSeconds(try XCTUnwrap(slider.value as? String))
        try assertDecodedVideoFrame("audio-switch-scrubbed", expectedPosition: position)
        let captions = element("player.captions")
        XCTAssertTrue(captions.waitForExistence(timeout: 10))
        captions.tap()
        let spanishAudio = app.descendants(matching: .any).matching(NSPredicate(format:
            "label BEGINSWITH 'Spanish'")).firstMatch
        XCTAssertTrue(waitUntilHittable(spanishAudio, timeout: 10))
        spanishAudio.press(forDuration: 0.1)
        dismissTrackMenu(spanishAudio)
        pausePlayback()
        try assertDecodedVideoFrame("audio-switch-after")
        XCTAssertEqual(Self.playbackSeconds(try XCTUnwrap(slider.value as? String)), position, accuracy: 1)
        captions.tap()
        XCTAssertTrue(spanishAudio.images["checkmark"].firstMatch.waitForExistence(timeout: 10))
    }

    func testAudioSwitchHonoursPauseAndUserSeek() throws {
        executionTimeAllowance = 600
        launchPage("add-files", extra: ["-OpenStreamVisionPlaybackURL", fixtureBase + "/media/e2e-long.mp4",
            "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", "engine",
            "-OpenStreamHoldPlayerChrome", "YES"])
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        try assertDecodedVideoFrame("audio-switch-user-seek-before")
        pausePlayback()
        let captions = element("player.captions")
        XCTAssertTrue(captions.waitForExistence(timeout: 10))
        captions.tap()
        let spanish = app.descendants(matching: .any).matching(NSPredicate(format:
            "label BEGINSWITH 'Spanish'")).firstMatch
        XCTAssertTrue(waitUntilHittable(spanish, timeout: 10))
        spanish.press(forDuration: 0.1)
        dismissTrackMenu(spanish)
        pausePlayback()
        let slider = app.sliders["Playback position"].firstMatch
        seek(slider, to: 0.5)
        let position = Self.playbackSeconds(try XCTUnwrap(slider.value as? String))
        try assertDecodedVideoFrame("audio-switch-user-seek", expectedPosition: position)
        XCTAssertEqual(element("player.play-pause").label, "Play")
        captions.tap()
        XCTAssertTrue(spanish.images["checkmark"].firstMatch.waitForExistence(timeout: 10))
    }

    func testTransportScrubbingCaptionsAndSavedResume() throws {
        // Native visionOS menus can each consume a 60-second XCTest animation-idle wait.
        executionTimeAllowance = 600
        let url = fixtureBase + "/media/e2e-long.mp4"
        launchPage("add-files")
        try play(url)
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        try assertDecodedVideoFrame("player-start")
        let transport = element("player.play-pause")
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10))
        transport.tap()
        XCTAssertEqual(transport.label, "Play")
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        seek(slider, to: 0.25)
        let beforeSkip = try XCTUnwrap(slider.value as? String)
        let beforeSkipSeconds = Self.playbackSeconds(beforeSkip)
        app.buttons["Forward 10 seconds"].firstMatch.tap()
        let skipped = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return abs(Self.playbackSeconds(value) - beforeSkipSeconds - 10) <= 1
        }, object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [skipped], timeout: 10), .completed)
        app.buttons["Back 10 seconds"].firstMatch.tap()
        let returnedToSeek = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return abs(Self.playbackSeconds(value) - beforeSkipSeconds) <= 1
        }, object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToSeek], timeout: 10), .completed)
        try assertDecodedVideoFrame("player-paused-scrubbed", expectedPosition: beforeSkipSeconds)
        try checkpoint("player-paused-scrubbed")
        let captions = element("player.captions")
        XCTAssertTrue(captions.waitForExistence(timeout: 10))
        captions.tap()
        try checkpoint("player-audio-menu")
        let spanishAudio = app.descendants(matching: .any).matching(NSPredicate(format:
            "label BEGINSWITH 'Spanish'")).firstMatch
        XCTAssertTrue(spanishAudio.waitForExistence(timeout: 10), "The audio menu did not load both fixture tracks")
        spanishAudio.tap()
        dismissTrackMenu(spanishAudio)
        pausePlayback()
        try assertDecodedVideoFrame("player-after-audio-switch", expectedPosition: beforeSkipSeconds)
        XCTAssertTrue(captions.waitForExistence(timeout: 10))
        captions.tap()
        let spanishSelected = spanishAudio.images["checkmark"].firstMatch
        XCTAssertTrue(spanishSelected.waitForExistence(timeout: 10))
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'English'")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        try checkpoint("player-audio-subtitles")
        let off = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Off'")).firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 10))
        off.tap()
        dismissTrackMenu(english)
        pausePlayback()
        assertCaptionState("Subtitles off")
        captions.tap()
        XCTAssertTrue(english.waitForExistence(timeout: 10), "The subtitle menu did not reopen")
        english.tap()
        dismissTrackMenu(english)
        pausePlayback()
        assertCaptionState("Subtitles on")
        XCTAssertTrue(waitUntilHittable(playerClose, timeout: 10))
        let savedPosition = try XCTUnwrap(slider.value as? String)
        try closePlayer()
        launchPage("add-files", reset: false)
        try play(url)
        let resume = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch
        if resume.waitForExistence(timeout: 5) { resume.buttons["Resume"].tap() }
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        revealControls()
        let resumed = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(resumed.waitForExistence(timeout: 10))
        let resumedTime = try XCTUnwrap(resumed.value as? String)
        let components = resumedTime.split(separator: ":").compactMap { Double($0) }
        let seconds = components.reduce(0) { $0 * 60 + $1 }
        XCTAssertGreaterThan(seconds, 300, "Resume was lost (saved \(savedPosition), reopened \(resumedTime))")
        XCTAssertEqual(windowCount, 1)
        try assertDecodedVideoFrame("player-resumed-after-relaunch")
        try checkpoint("player-resumed-after-relaunch")
        try closePlayer()
    }

    func testAnEpisodePlaysAndItsResumeActionReturnsToTheSavedPoint() throws {
        launchPage("detail", extra: ["-OpenStreamNextEpisodeLeadSeconds", "60",
                                     "-OpenStreamHoldPlayerChrome", "YES"])
        let play = element("detail.play")
        XCTAssertTrue(waitUntilHittable(play, timeout: 60))
        play.tap()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        revealControls()
        XCTAssertTrue(waitUntilHittable(element("player.play-pause"), timeout: 10),
                      "Revealing held episode controls must leave them visible")
        try assertDecodedVideoFrame("episode-start")
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        seek(slider, to: 0.25)
        try assertDecodedVideoFrame("episode-player")
        try checkpoint("episode-player")
        let stopped = Self.playbackSeconds(try XCTUnwrap(slider.value as? String))
        try closePlayer()
        capture("episode-title-after-playback")
        let resume = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'Resume'"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [resume], timeout: 20), .completed)
        try checkpoint("episode-title-resume")
        play.tap()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        let returned = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 15))
        let position = try XCTUnwrap(returned.value as? String)
        let resumedSeconds = Self.playbackSeconds(position)
        XCTAssertGreaterThan(resumedSeconds, 300)
        XCTAssertEqual(resumedSeconds, stopped, accuracy: 5, "Resume restarted at the preceding keyframe")
        XCTAssertEqual(windowCount, 1)
        try assertDecodedVideoFrame("episode-resumed")
        try checkpoint("episode-resumed")
        let transport = element("player.play-pause")
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10))
        let transportReady = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label == 'Pause' OR label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [transportReady], timeout: 10), .completed)
        if transport.label == "Pause" { transport.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        seek(returned, to: 0.98)
        let next = element("player.nextEpisode.play")
        XCTAssertTrue(waitUntilHittable(next, timeout: 15))
        try checkpoint("episode-next-offer")
        next.tap()
        let offerDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [offerDismissed], timeout: 30), .completed, "The old Next Episode offer stayed visible")
        let restarted = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            return value.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 } < 30
        }, object: returned)
        XCTAssertEqual(XCTWaiter.wait(for: [restarted], timeout: 30), .completed, "Next Episode did not start")
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 15))
        XCTAssertEqual(windowCount, 1)
        try assertDecodedVideoFrame("episode-next-playing")
        try checkpoint("episode-next-playing")
        try closePlayer()
    }

    func testLargestTextHeroPlayAndResumeRemainTappable() throws {
        let extra = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                     "-OpenStreamHeroTitle", "Stub Movie Two",
                     "-OpenStreamVisionBrowseWidth", "1180", "-OpenStreamVisionBrowseHeight", "820"]
        launchPage("discover", extra: extra)
        let play = element("home.featured.play")
        XCTAssertTrue(waitUntilHittable(play, timeout: 60))
        XCTAssertEqual(play.label, "Play")
        XCTAssertTrue(element("home.featured.pages").exists)
        capture("largest-text-hero-play")
        play.tap()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45), "The hero's Play tap did not start playback")
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        seek(slider, to: 0.25)
        try closePlayer()
        let resume = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND hittable == true AND label CONTAINS[c] 'Resume'"), object: element("detail.play"))
        XCTAssertEqual(XCTWaiter.wait(for: [resume], timeout: 20), .completed, "Closing playback did not save the title's Resume action")
        capture("largest-text-title-after-close")
        launchPage("discover", reset: false, extra: extra)
        let relaunched = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND hittable == true AND label CONTAINS[c] 'Resume'"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [relaunched], timeout: 30), .completed)
        try checkpoint("largest-text-hero-resume")
        play.tap()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45), "The hero's Resume tap did not start playback")
        let returned = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 15))
        let position = try XCTUnwrap(returned.value as? String)
        XCTAssertGreaterThan(position.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }, 300)
        try closePlayer()
    }

    // MARK: Helpers

    private func pausePlayback() {
        revealControls()
        let transport = element("player.play-pause")
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10))
        if transport.label == "Pause" { transport.tap() }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed,
                       "Menu interactions require paused playback: \(element("player.video.frame").value ?? "missing frame")")
    }

    private func launchPage(_ screen: String?, reset: Bool = true, firstLaunch: Bool = false, extra: [String] = []) {
        prepare(screen: screen, reset: reset, firstLaunch: firstLaunch, extra: extra)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
    }

    private func tapTab(_ name: String) {
        let symbols = ["Discover": "sparkles", "Library": "books.vertical",
                       "Live": "dot.radiowaves.left.and.right", "Settings": "gearshape"]
        let tab = app.buttons[symbols[name] ?? name].firstMatch
        XCTAssertTrue(waitUntilHittable(tab, timeout: 15), "No \(name) ornament tab")
        tab.tap()
    }

    private func dismissTrackMenu(_ item: XCUIElement) {
        if item.exists {
            contentWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, "The track menu did not close")
    }

    private func assertCaptionState(_ value: String) {
        let captions = element("player.captions")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            captions.exists && captions.value as? String == value
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed,
                       "The captions control did not publish \(value) after the menu closed")
    }

    private func assertNamedButtons(prefix: String) {
        let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        XCTAssertFalse(buttons.isEmpty)
        for button in buttons { XCTAssertFalse(button.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }

    private func scrollTo(_ target: XCUIElement, towardTop: Bool = false, in collection: XCUIElement? = nil) {
        let list = collection ?? app.collectionViews.firstMatch
        for _ in 0..<10 {
            if target.exists, target.isHittable { return }
            if towardTop { list.swipeDown() } else { list.swipeUp() }
        }
    }

    nonisolated private static func playbackSeconds(_ value: String) -> Double {
        value.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    nonisolated private static func frameMeasurements(_ raw: String) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: raw.split(separator: ";").compactMap { field -> (String, Double)? in
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Double(pair[1]) else { return nil }
            return (String(pair[0]), value)
        })
    }

    private func seek(_ slider: XCUIElement, to fraction: Double) {
        let before = Self.playbackSeconds(slider.value as? String ?? "")
        // visionOS reports zero scrubber endpoints; drag the knob's own hit region.
        let knob = slider.otherElements["AXSliderKnob"].firstMatch
        XCTAssertTrue(knob.waitForExistence(timeout: 5))
        let thumb = knob.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = slider.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        thumb.press(forDuration: 0.1, thenDragTo: target)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String else { return false }
            let after = Self.playbackSeconds(value)
            return abs(after - before) > 30
        }, object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 15), .completed, "The scrubber did not seek")
        if element("player.play-pause").label == "Play" {
            let frame = element("player.video.frame")
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let raw = frame.value as? String, let label = slider.value as? String else { return false }
                let values = Self.frameMeasurements(raw)
                guard let position = values["position"], let picture = values["frame"],
                      let nonblack = values["nonblack"] else { return false }
                return abs(position - Self.playbackSeconds(label)) < 1 && abs(picture - position) < 2 && nonblack > 0.02
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 20), .completed,
                           "The paused seek did not display its target frame")
        }
    }

    private func assertDecodedVideoFrame(_ name: String, expectedPosition: Double? = nil) throws {
        revealControls()
        let frame = element("player.video.frame")
        let transport = element("player.play-pause")
        XCTAssertTrue(waitUntilHittable(transport, timeout: 10), "Frame readback requires visible player controls")
        let wasPlaying = transport.label == "Pause"
        if wasPlaying {
            let picture = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                guard let raw = (object as? XCUIElement)?.value as? String else { return false }
                return raw.contains("ready=1") || raw.contains("nonblack=")
            }, object: frame)
            let ready = XCTWaiter.wait(for: [picture], timeout: 30)
            let state = XCTAttachment(string: frame.value as? String ?? "missing")
            state.name = name + "-renderer-ready"
            state.lifetime = .keepAlways
            add(state)
            XCTAssertEqual(ready, .completed, "No video frame reached the display layer")
        }
        if wasPlaying {
            revealControls()
            XCTAssertTrue(waitUntilHittable(transport, timeout: 10))
            transport.tap()
        }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed,
                       "Displayed-frame readback requires paused playback")
        defer { if wasPlaying { transport.tap() } }
        let slider = app.sliders["Playback position"].firstMatch
        let time = try XCTUnwrap(slider.value as? String)
        let position = Self.playbackSeconds(time)
        let expected = expectedPosition ?? position
        XCTAssertEqual(position, expected, accuracy: 1, "Playback moved away from the requested scrub position")
        let decoded = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let raw = (object as? XCUIElement)?.value as? String else { return false }
            let values = Self.frameMeasurements(raw)
            guard let itemTime = values["frame"], let position = values["position"],
                  let fraction = values["nonblack"] else { return false }
            return abs(itemTime - position) < 2 && abs(itemTime - expected) < 2
                && abs(position - expected) < 2 && fraction > 0.02
        }, object: frame)
        let result = XCTWaiter.wait(for: [decoded], timeout: 20)
        let evidence = XCTAttachment(string: "Expected playback \(expected); decoded \(frame.value ?? "missing")")
        evidence.name = name + "-decoded-pixels"
        evidence.lifetime = .keepAlways
        add(evidence)
        capture(name + "-decoded-frame")
        XCTAssertEqual(result, .completed, "No nonblack decoded video frame at the requested playback position")
    }

    private func checkpoint(_ name: String) throws {
        capture(name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
        var systemFindings: [String] = []
        try app.performAccessibilityAudit { issue in
            // The stock AVKit trailer knob fails this runtime's hit-region audit.
            guard issue.auditType == .hitRegion,
                  issue.element?.identifier == "UIA.LinearMediaKit.ScrubberView.background-AXSliderKnob" else { return false }
            systemFindings.append(issue.detailedDescription)
            return true
        }
        if !systemFindings.isEmpty {
            let system = XCTAttachment(string: systemFindings.joined(separator: "\n\n"))
            system.name = name + "-system-finding-\(systemFindings.count)"
            system.lifetime = .keepAlways
            add(system)
        }
        let audit = XCTAttachment(string: systemFindings.isEmpty ? "No findings" : "No app findings; system finding attached")
        audit.name = name + "-audit-0"
        audit.lifetime = .keepAlways
        add(audit)
    }

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

    private var windowCount: Int {
        // Each app scene owns an SFBSystemService subtree; its ornament,
        // alerts and empty compositor containers also report as Windows.
        app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "com.orgista.openstream:SFBSystemService-")).count
    }

    private var contentWindow: XCUIElement {
        app.windows.allElementsBoundByIndex.filter { $0.frame.width >= 480 && $0.frame.height >= 260 }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app.windows.firstMatch
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
                                                    object: element("books.vertical"))
        return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    }

    private func capture(_ name: String) {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_VISION_CAPTURE_URL"], !raw.isEmpty else {
            #if !targetEnvironment(simulator)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            add(screenshot)
            #endif
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + "-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            return
        }
        guard var components = URLComponents(string: raw) else { return XCTFail("Invalid Vision capture endpoint") }
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        components.queryItems = [URLQueryItem(name: "name", value: safeName)]
        guard let url = components.url else { return XCTFail("Invalid Vision capture endpoint") }
        let done = expectation(description: "capture \(name)")
        URLSession.shared.dataTask(with: url) { _, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
    }
}
