import XCTest
#if os(macOS)
import AppKit
import CoreGraphics
#endif

/// Captures the macOS app's own window through XCUITest.
///
/// The `screencapture` CLI needs a Screen Recording grant on the calling process,
/// which cannot be given headlessly. `XCUIElement.screenshot()` goes through the
/// automation path instead and only ever sees the app's own window.
/// Resets require OPENSTREAM_MAC_UI_TEST_ALLOW_RESET=1 in the test runner's
/// environment. Set it only in a disposable macOS account with fixture data.
@MainActor
final class AppleMacScreenshotUITests: OpenStreamUITestCase {
    private var stubs: String {
        ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("TestPlans/Stubs").path
    }

    private func fixtureArguments(reset: Bool = true,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        ["-OpenStreamStubNetwork", stubs, "-OpenStreamStubLiveBase", "http://127.0.0.1:8767",
         "-OpenStreamStubMediaBase", "http://127.0.0.1:8767", "-OpenStreamResetOnLaunch",
         reset && environment["OPENSTREAM_MAC_UI_TEST_ALLOW_RESET"] == "1" ? "YES" : "NO",
         "-openstream.firstRunGuidanceSeen", "YES", "-OpenStreamDebugNoKeychain", "YES", "-OpenStreamUITestFixtureCredentials", "YES",
         "-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES", "-OpenStreamTrace", "YES",
         "-openstream.settings.trailer.autoplay.v1", "NO"]
    }

    func testFixtureResetRequiresExplicitOptIn() throws {
        for (environment, reset, expected): ([String: String], Bool, String) in [
            ([:], true, "NO"), (["OPENSTREAM_MAC_UI_TEST_ALLOW_RESET": "0"], true, "NO"),
            (["OPENSTREAM_MAC_UI_TEST_ALLOW_RESET": "1"], true, "YES"),
            (["OPENSTREAM_MAC_UI_TEST_ALLOW_RESET": "1"], false, "NO")
        ] {
            let arguments = fixtureArguments(reset: reset, environment: environment)
            let index = try XCTUnwrap(arguments.firstIndex(of: "-OpenStreamResetOnLaunch"))
            XCTAssertEqual(arguments[index + 1], expected)
        }
    }

    #if os(macOS)
    func testTouchHeroClickRevealsPaging() throws {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { movePointerOutsideContent(app); terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamMacHeroHold", "YES"]
        app.launch()
        let pages = app.descendants(matching: .any)["home.featured.pages"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 60))
        let next = app.buttons["home.featured.next"].firstMatch
        let list = app.buttons["home.featured.my-list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let saved = try XCTUnwrap(list.value as? String)
        movePointerOutsideContent(app)
        try clickWithoutMovingPointer(at: CGPoint(x: list.frame.midX, y: list.frame.midY))
        XCTAssertTrue(next.waitForExistence(timeout: 2), "A child button click must also hold the hero controls")
        let toggled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", saved), object: list)
        XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 5), .completed,
                       "The injected click must also reach a child button")
        movePointerOutsideContent(app)
        waitForAbsence(next)
        capture(app, "mac-touch-hero-idle")
        let point = CGPoint(x: app.windows.firstMatch.frame.maxX - 120, y: pages.frame.minY - 100)
        try clickWithoutMovingPointer(at: point)
        let revealed = next.waitForExistence(timeout: 2)
        capture(app, "mac-touch-hero-click")
        XCTAssertTrue(revealed, "A click must reveal paging without a hover event")
        waitForAbsence(next)
        let dots = pages.buttons.allElementsBoundByIndex
        for dot in dots {
            XCTAssertGreaterThanOrEqual(dot.frame.width, 36)
            XCTAssertGreaterThanOrEqual(dot.frame.height, 36)
        }
        let hitOutset: CGFloat = (36 - 7) / 2
        let frames = dots.map(\.frame).sorted { $0.minX < $1.minX }
        XCTAssertGreaterThan(frames.count, 1)
        for (left, right) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(right.minX - left.maxX + 2 * hitOutset, 8, accuracy: 1,
                           "Overlapping targets must preserve the visible 8 pt dot gap")
        }
        for dot in dots {
            try clickWithoutMovingPointer(at: CGPoint(x: dot.frame.midX, y: dot.frame.midY))
            XCTAssertTrue(dot.isSelected, "Each overlapping target must select its own dot at its center")
        }
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                         mouseCursorPosition: point, mouseButton: .left))
        move.post(tap: .cghidEventTap)
        XCTAssertTrue(next.waitForExistence(timeout: 2), "Pointer hover must still reveal paging")
    }

    func testTouchHeroHorizontalDragChangesPage() {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { movePointerOutsideContent(app); terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamMacHeroHold", "YES"]
        app.launch()
        let pages = app.descendants(matching: .any)["home.featured.pages"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 60))
        let details = app.buttons["home.featured.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        let title = details.label
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: pages.frame.midX - window.frame.minX + 120, dy: pages.frame.minY - window.frame.minY - 160))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)))
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label != %@", title), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        capture(app, "mac-touch-hero-drag")
    }

    func testTouchPlayerClickRevealsClose() throws {
        continueAfterFailure = false
        guard let media = ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] else {
            throw XCTSkip("Requires OPENSTREAM_FULLPASS_MEDIA from the local fixture origin")
        }
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { movePointerOutsideContent(app); terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "add-files",
            "-OpenStreamVisionPlaybackURL", media, "-openstream.playback.engine", "native"]
        app.launch()
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        XCTAssertEqual(ready.value as? String, "Playing")
        let playerWindow = app.windows.containing(.any, identifier: "player.playback.ready").firstMatch
        XCTAssertTrue(playerWindow.exists)
        let close = app.buttons["player.close"].firstMatch
        movePointerOutsideContent(app)
        waitForAbsence(close)
        capture(app, "mac-touch-player-idle", window: playerWindow)
        let window = playerWindow.frame
        try clickWithoutMovingPointer(at: CGPoint(x: window.minX + window.width * 0.72,
                                                  y: window.minY + window.height * 0.35))
        let revealed = close.waitForExistence(timeout: 2)
        capture(app, "mac-touch-player-click", window: playerWindow)
        XCTAssertTrue(revealed, "A click must reveal Close without a hover event")
        XCTAssertEqual(ready.value as? String, "Playing", "A playback-state change must not mask a swallowed click")
        close.click()
        waitForAbsence(app.descendants(matching: .any)["player.playback.ready"].firstMatch)
    }

    func testTouchLiveClickRevealsFullWindow() throws {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { movePointerOutsideContent(app); terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "live",
            "-openstream.playback.engine", "native"]
        app.launch()
        let channel = app.buttons["Play Fixture News"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 45))
        channel.click()
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 45), .completed)
        let fullWindow = app.buttons["player.fullscreen"].firstMatch
        movePointerOutsideContent(app)
        waitForAbsence(fullWindow)
        let frame = stage.frame
        try clickWithoutMovingPointer(at: CGPoint(x: frame.minX + frame.width * 0.72,
                                                  y: frame.minY + frame.height * 0.35))
        XCTAssertTrue(fullWindow.waitForExistence(timeout: 2), "A click must reveal Full Screen without hover")
        XCTAssertEqual(stage.value as? String, "Playing", "The reveal must not come from a playback-state change")
        capture(app, "mac-touch-live-click")
    }

    func testTouchRailClickRevealsPaging() throws {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { movePointerOutsideContent(app); terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamMacWindowOrigin", "80,80",
            "-OpenStreamMacWindowSize", "900,800"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home.featured.pages"].firstMatch.waitForExistence(timeout: 60))
        for _ in 0..<4 {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
            for rail in app.scrollViews.matching(identifier: "discover.rail").allElementsBoundByIndex {
                let frame = rail.frame
                guard frame.height > 20, frame.minY > app.windows.firstMatch.frame.minY + 60,
                      frame.maxY < app.windows.firstMatch.frame.maxY else { continue }
                XCTAssertEqual(rail.buttons.matching(identifier: "discover.rail").count, 0,
                               "The scroll view's identifier must not be inherited by cards")
                movePointerOutsideContent(app)
                let next = rail.buttons["discover.rail.next"].firstMatch
                waitForAbsence(next)
                try clickWithoutMovingPointer(at: CGPoint(x: frame.midX, y: frame.minY + 2))
                if next.waitForExistence(timeout: 1) {
                    capture(app, "mac-touch-rail-click")
                    waitForAbsence(next)
                    return
                }
            }
        }
        XCTFail("No overflowing rail revealed its paging button after a click")
    }

    func testTouchPlayMenuKeepsTheContextMenu() {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "detail-movie",
            "-OpenStreamDetailTitle", "Stub Movie Two"]
        app.launch()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["detail.my-list"].firstMatch.frame.height, 44)
        app.descendants(matching: .any)["detail.play.more"].firstMatch.click()
        XCTAssertTrue(app.menuItems["Play version…"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "mac-touch-play-menu")
        app.typeKey(.escape, modifierFlags: [])
        play.rightClick()
        XCTAssertTrue(app.menuItems["Play version…"].firstMatch.waitForExistence(timeout: 5))
    }

    private func movePointerOutsideContent(_ app: XCUIApplication) {
        let screen = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 40, dy: 40)
        let windows = app.windows.allElementsBoundByIndex.map(\.frame)
        let candidates = [CGPoint(x: screen.minX, y: screen.midY), CGPoint(x: screen.maxX, y: screen.midY),
                          CGPoint(x: screen.midX, y: screen.minY), CGPoint(x: screen.midX, y: screen.maxY)]
        guard let point = candidates.first(where: { point in !windows.contains { $0.contains(point) } }) else {
            XCTFail("The click-only proof requires screen space outside the app window")
            return
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func clickWithoutMovingPointer(at point: CGPoint) throws {
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.orgista.openstream").first)
        // Posting to the app avoids mouse-move/enter events that would let hover mask a missing click path.
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                             mouseCursorPosition: point, mouseButton: .left))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.postToPid(running.processIdentifier)
        }
    }

    private func waitForAbsence(_ element: XCUIElement) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 8), .completed)
    }
    #endif

    func testTintControlsInLightAndDark() {
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        for appearance in ["light", "dark"] {
            app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "detail-movie",
                "-OpenStreamDetailTitle", "Stub Movie Two", "-OpenStreamDebugColorScheme", appearance]
            app.launch()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 60))
            capture(app, "mac-tint-prominent-" + appearance)
            app.buttons["Rate"].firstMatch.click()
            XCTAssertTrue(app.buttons["I Like This"].firstMatch.waitForExistence(timeout: 15))
            capture(app, "mac-tint-menu-" + appearance)
            app.terminate()
            app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "about",
                "-OpenStreamDebugColorScheme", appearance]
            app.launch()
            let acknowledgements = app.buttons["settings.about.acknowledgements"].firstMatch
            XCTAssertTrue(acknowledgements.waitForExistence(timeout: 10))
            acknowledgements.click()
            let link = app.descendants(matching: .any)["settings.acknowledgements.sourceCode"].firstMatch
            for _ in 0..<12 where !link.exists || !link.isHittable {
                app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -400)
            }
            XCTAssertTrue(link.waitForExistence(timeout: 15))
            XCTAssertTrue(link.isHittable)
            capture(app, "mac-tint-link-" + appearance)
            app.terminate()
        }
    }

    func testLiveReconnectShowsOneLoadingIndicator() async throws {
        try await checkLiveReconnect(engine: "native")
    }

    func testLiveReconnectOnSurfaceRouteShowsOneImmediateIndicator() async throws {
        try await checkLiveReconnect(engine: "engine")
    }

    private func checkLiveReconnect(engine: String) async throws {
        continueAfterFailure = false
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        let (_, reset) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/reset"))
        XCTAssertEqual((reset as? HTTPURLResponse)?.statusCode, 200)
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", base.appendingPathComponent(engine == "engine" ? "reconnect-surface/stream" : "reconnect/index.m3u8").absoluteString,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-openstream.playback.engine", engine]
        app.launch()
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        await fulfillment(of: [playing], timeout: 45)
        if engine == "engine" {
            XCTAssertTrue(app.descendants(matching: .any)["player.software.surface"].firstMatch.exists,
                          "This regression must exercise the software surface route")
        }
        let (_, stalled) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/stall"))
        XCTAssertEqual((stalled as? HTTPURLResponse)?.statusCode, 200)
        let reconnecting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Reconnecting'"), object: stage)
        await fulfillment(of: [reconnecting], timeout: 90)
        XCTAssertTrue(app.descendants(matching: .any)["live.reconnecting"].firstMatch.exists,
                      "The reconnect indicator must appear with the reconnect state, without a tuning delay")
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
        capture(app, "mac-live-" + engine + "-reconnecting-indicator")
    }

    func testConfigurationExportImportsFixtureSources() throws {
        continueAfterFailure = false
        guard let directory = ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_EXPORT_DIR"] else {
            throw XCTSkip("Requires the local full-pass export directory")
        }
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "backup"]
        app.launch()
        let passphrase = "fixture-backup-passphrase"
        let seal = app.secureTextFields["backup.passphrase"].firstMatch
        XCTAssertTrue(seal.waitForExistence(timeout: 30))
        seal.click()
        seal.typeText(passphrase)
        let export = app.buttons["backup.export"].firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 30))
        export.click()
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Export"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 30))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        app.typeText(directory + "\n")
        capture(app, "mac-backup-save-sheet")
        save.click()
        let replace = app.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 2) { replace.click() }
        XCTAssertTrue(app.staticTexts["Configuration exported"].waitForExistence(timeout: 30))
        capture(app, "mac-backup-exported")
        app.buttons["backup.import"].click()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeKey("a", modifierFlags: .command)
        let file = URL(fileURLWithPath: directory).appendingPathComponent("openstream-config.json")
        app.typeText(file.path + "\n")
        if open.waitForExistence(timeout: 5) { open.click() }
        let confirm = app.buttons["Import"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 30))
        let unlock = app.secureTextFields["backup.import.passphrase"].firstMatch
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        unlock.click()
        unlock.typeText(passphrase)
        capture(app, "mac-backup-import-review")
        confirm.click()
        XCTAssertTrue(app.staticTexts["Configuration imported"].waitForExistence(timeout: 30))
        capture(app, "mac-backup-imported")
    }

    func testFixtureLibrarySearchTitleAndLiveGuide() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] != nil,
                          "Requires the local full-pass fixture origin")
        continueAfterFailure = false
        executionTimeAllowance = 600
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        for (screen, expected) in [("library", "library.title.Stub Movie One"), ("detail", "detail.play"),
                                   ("detail-movie", "detail.play"),
                                   ("episodes", "detail.episodes"), ("live", "live.stage.player")] {
            app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", screen]
            if screen == "detail-movie" { app.launchArguments += ["-OpenStreamDetailTitle", "Stub Movie Two"] }
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)[expected].firstMatch.waitForExistence(timeout: 60))
            capture(app, "mac-fixture-" + screen)
            if screen == "detail-movie" {
                app.buttons["detail.play"].rightClick()
                let versions = app.menuItems["Play version…"].firstMatch
                XCTAssertTrue(versions.waitForExistence(timeout: 10))
                versions.click()
                let alternate = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Alternate'")).firstMatch
                XCTAssertTrue(alternate.waitForExistence(timeout: 10))
                capture(app, "mac-movie-versions")
                alternate.click()
                XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch.waitForExistence(timeout: 45))
                capture(app, "mac-alternate-version-playing")
                app.buttons["player.close"].click()
                let trailer = app.buttons["detail.serverTrailer"].firstMatch
                XCTAssertTrue(trailer.waitForExistence(timeout: 20))
                trailer.click()
                XCTAssertTrue(app.descendants(matching: .any)["trailer.player.playing"].firstMatch.waitForExistence(timeout: 45))
                capture(app, "mac-server-trailer-playing")
                XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
            }
            if screen == "live" {
                let channel = app.buttons["Play Fixture News"].firstMatch
                XCTAssertTrue(channel.waitForExistence(timeout: 30))
                channel.click()
                let stage = app.descendants(matching: .any)[expected].firstMatch
                let playing = XCTNSPredicateExpectation(predicate: NSPredicate(
                    format: "value == 'Playing' AND label == 'Live player for Fixture News'"), object: stage)
                XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 45), .completed)
                channel.rightClick()
                let favorite = app.menuItems["Favorite"].firstMatch
                XCTAssertTrue(favorite.waitForExistence(timeout: 10))
                favorite.click()
                let favorites = app.buttons["Favorites"].firstMatch
                XCTAssertTrue(favorites.waitForExistence(timeout: 10))
                favorites.click()
                XCTAssertTrue(channel.waitForExistence(timeout: 10))
                XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).count, 1)
                capture(app, "mac-live-favorites")
                app.buttons["All"].firstMatch.click()
                let guide = app.buttons["live.guide"].firstMatch
                XCTAssertTrue(guide.waitForExistence(timeout: 10))
                guide.click()
                let done = app.buttons["live.guide.done"].firstMatch
                XCTAssertTrue(done.waitForExistence(timeout: 10))
                capture(app, "mac-live-guide")
                done.click()
                app.buttons["Search"].firstMatch.click()
                let search = app.searchFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                search.click()
                search.typeText("Fixture News")
                XCTAssertTrue(channel.waitForExistence(timeout: 15))
                capture(app, "mac-live-search")
            }
            app.terminate()
        }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "search"]
        app.launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.click()
        search.typeText("Stub Movie Two")
        let result = app.staticTexts["Stub Movie Two"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        capture(app, "mac-search-results")
        result.click()
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30))
        capture(app, "mac-search-title")
    }

    func testFixtureLiveSourceCanBeAddedDisabledAndDeleted() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] != nil,
                          "Requires the local full-pass fixture origin")
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "add-live"]
        app.launch()
        for (label, value) in [("Name", "Fullpass Live"), ("Server URL", "http://127.0.0.1:8767"),
                               ("Username", "fixture")] {
            let field = app.textFields[label].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 30))
            field.click()
            field.typeText(value)
        }
        let password = app.secureTextFields["Password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.click()
        password.typeText("fixture")
        app.buttons["sources.live.save"].click()
        let source = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fullpass Live'")).firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 45))
        source.click()
        let enabled = app.switches["Enabled"].firstMatch.exists
            ? app.switches["Enabled"].firstMatch : app.checkBoxes["Enabled"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertEqual(enabled.value as? String, "1")
        capture(app, "mac-source-added")
        enabled.click()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        capture(app, "mac-source-disabled")
        app.buttons["Delete Source"].click()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        capture(app, "mac-source-deleted")
    }

    func testStalledLiveFixtureLeavesRetryAndChannelsUsable() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] != nil,
                          "Requires the local full-pass fixture origin")
        continueAfterFailure = false
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "add-live"]
        app.launch()
        let type = app.popUpButtons.firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 30))
        type.click()
        app.menuItems["M3U Playlist"].firstMatch.click()
        for (label, value) in [("Name", "Stalled fixture"),
                               ("Playlist URL", "http://127.0.0.1:8767/failure/channels.m3u")] {
            let field = app.textFields[label].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.click()
            field.typeText(value)
        }
        app.buttons["sources.live.save"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stalled fixture'"))
            .firstMatch.waitForExistence(timeout: 30))
        app.typeKey("3", modifierFlags: .command)
        let stalled = app.buttons["Play A&E Fixture"].firstMatch
        XCTAssertTrue(stalled.waitForExistence(timeout: 30))
        stalled.click()
        let retry = app.buttons["live.failure.retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        let working = app.buttons["Play Fixture News"].firstMatch
        XCTAssertTrue(working.isHittable, "The stalled channel blocked the channel list")
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        XCTAssertEqual(stage.progressIndicators.count, 0)
        capture(app, "mac-stalled-live-retry")
        working.click()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value == 'Playing' AND label == 'Live player for Fixture News'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 45), .completed)
        capture(app, "mac-working-channel-after-stall")
    }

    func testTitlePageSectionSwitchesKeepPlaybackAndEpisodes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] != nil,
                          "Requires the local full-pass fixture origin")
        continueAfterFailure = true
        executionTimeAllowance = 600
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "detail"]
        app.launch()
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
        let names = ["trailers", "cast", "information", "about"]
        let sections = ["detail.trailers", "detail.cast", "detail.information", "detail.languages", "detail.about"]
        var enabledSections = Set<String>()
        for (visit, enabled) in [true, false, true].enumerated() {
            app.typeKey("4", modifierFlags: .command)
            let sources = app.descendants(matching: .any)["settings.sources"].firstMatch
            for _ in 0..<12 where !sources.exists || !sources.isHittable {
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 400)
            }
            let general = app.descendants(matching: .any)["settings.general"].firstMatch
            for _ in 0..<12 where !general.exists || !general.isHittable {
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
            }
            XCTAssertTrue(general.isHittable)
            general.click()
            for name in names {
                let toggle = app.descendants(matching: .any)["settings.titlePage.\(name)"].firstMatch
                let scroll = app.scrollViews.firstMatch
                for _ in 0..<12 where !toggle.exists || !toggle.isHittable {
                    scroll.scroll(byDeltaX: 0, deltaY: -200)
                }
                XCTAssertTrue(toggle.waitForExistence(timeout: 10))
                let wanted = enabled ? "1" : "0"
                if toggle.value as? String != wanted { toggle.click() }
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            }
            capture(app, "mac-title-switches-\(visit)-\(enabled ? "on" : "off")")
            app.typeKey("1", modifierFlags: .command)
            let play = app.buttons["detail.play"].firstMatch
            let scroll = app.scrollViews.firstMatch
            for _ in 0..<12 where !play.exists || !play.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: 400)
            }
            XCTAssertTrue(play.waitForExistence(timeout: 15))
            XCTAssertTrue(play.isEnabled)
            XCTAssertTrue(app.descendants(matching: .any)["detail.episodes"].firstMatch.waitForExistence(timeout: 15))
            var shown = Set<String>()
            for _ in 0..<10 {
                for identifier in sections where app.descendants(matching: .any)[identifier].firstMatch.exists {
                    shown.insert(identifier)
                }
                scroll.scroll(byDeltaX: 0, deltaY: -400)
            }
            capture(app, "mac-title-sections-\(visit)-\(enabled ? "on" : "off")")
            if !enabled {
                XCTAssertTrue(shown.isEmpty, "Disabled title-page sections remain visible")
            } else {
                XCTAssertTrue(shown.contains("detail.about"))
                XCTAssertTrue(shown.contains("detail.information"))
                if visit == 0 { enabledSections = shown }
                else { XCTAssertEqual(shown, enabledSections) }
            }
        }
    }

    func testSettingsAndSourceScreensHaveContent() {
        continueAfterFailure = true
        executionTimeAllowance = 600
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        let screens = [
            ("settings", "settings.general"), ("sources", "Media Server"),
            ("add-files", "Choose Folder"), ("add-live", "Name"),
            ("add-media-server", "sources.mediaServer.url"), ("network-share", "sources.smb.address"),
            ("playback-settings", "settings.liveBuffer"), ("subtitle-languages", "settings.subtitleLanguages.eng"),
            ("metadata", "settings.metadata.advanced"), ("watch-providers", "Streaming Services"),
            ("privacy", "Diagnostic Logging"), ("storage", "Clear Cache"),
            ("about", "settings.about.version"), ("backup", "backup.export"),
        ]
        for (screen, expected) in screens {
            app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", screen]
            app.launch()
            let content = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@ OR label == %@", expected, expected)).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 30), "The \(screen) screen did not show \(expected)")
            capture(app, "mac-screen-" + screen)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "mac-screen-" + screen + "-elements"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
    }

    func testFixtureVODTransportTracksAndResumeInTheAppWindow() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        guard let media = ProcessInfo.processInfo.environment["OPENSTREAM_FULLPASS_MEDIA"] else {
            throw XCTSkip("Requires the local full-pass media fixture")
        }
        let url = try XCTUnwrap(URL(string: media))
        guard url.scheme == "http", url.host == "127.0.0.1" else {
            XCTFail("The Mac playback fixture must use the loopback origin")
            return
        }
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        func playFixture(reset: Bool) {
            app.launchArguments = fixtureArguments(reset: reset) + ["-OpenStreamVisionScreen", "add-files"]
            app.launch()
            let direct = app.buttons["Direct URL"].firstMatch
            XCTAssertTrue(direct.waitForExistence(timeout: 30))
            direct.click()
            let field = app.textFields["URL"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.click()
            field.typeText(media)
            app.buttons["Play"].firstMatch.click()
        }
        playFixture(reset: true)
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        let window = app.windows.containing(.any, identifier: "player.playback.ready").firstMatch
        XCTAssertTrue(window.exists)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "mac-local-vod-playing"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "mac-local-vod-controls"
        tree.lifetime = .keepAlways
        add(tree)
        let transport = app.buttons["player.play-pause"].firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        func pause() {
            if transport.label == "Pause" { transport.click() }
            let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: transport)
            XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        }
        func seconds(_ slider: XCUIElement) -> Double? {
            guard let value = slider.value as? String else { return nil }
            let components = value.split(separator: ":").compactMap { Double($0) }
            guard !components.isEmpty else { return nil }
            return components.reduce(0) { $0 * 60 + $1 }
        }
        pause()
        let slider = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let sought = try XCTUnwrap(seconds(slider), "Playback position did not expose a time")
        XCTAssertGreaterThan(sought, 300)
        app.buttons["player.skip-forward"].click()
        let skipped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let position = seconds(slider) else { return false }
            return abs(position - sought - 10) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [skipped], timeout: 10), .completed)
        app.buttons["player.skip-back"].click()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let position = seconds(slider) else { return false }
            return abs(position - sought) <= 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        capture(app, "mac-vod-paused-and-scrubbed")
        let captions = app.buttons["player.captions"].firstMatch
        XCTAssertTrue(captions.waitForExistence(timeout: 10))
        captions.click()
        let spanish = app.menuItems.matching(NSPredicate(format: "label BEGINSWITH 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 10))
        capture(app, "mac-vod-audio-and-subtitles-menu")
        spanish.click()
        pause()
        captions.click()
        let off = app.menuItems["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 10))
        off.click()
        let subtitlesOff = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Subtitles off'"), object: captions)
        XCTAssertEqual(XCTWaiter.wait(for: [subtitlesOff], timeout: 10), .completed)
        captions.click()
        let english = app.menuItems["English"].firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        english.click()
        let subtitlesOn = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'Subtitles on'"), object: captions)
        XCTAssertEqual(XCTWaiter.wait(for: [subtitlesOn], timeout: 10), .completed)
        pause()
        capture(app, "mac-vod-subtitles-on")
        app.buttons["player.close"].click()
        app.terminate()
        playFixture(reset: false)
        let resume = app.alerts.matching(NSPredicate(format: "label BEGINSWITH 'Resume'")).firstMatch
        if resume.waitForExistence(timeout: 5) { resume.buttons["Resume"].click() }
        XCTAssertTrue(ready.waitForExistence(timeout: 45))
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(try XCTUnwrap(seconds(slider)), 300, "The saved VOD position was lost on relaunch")
        capture(app, "mac-vod-resumed")
    }

    func testNarratedSettingsTransferAndMetadata() {
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        defer { terminateCapturingFailure(app) }
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "settings"]
        app.launch()
        XCTAssertFalse(app.descendants(matching: .any)["settings.transfer"].firstMatch.exists)
        let backup = app.descendants(matching: .any)["settings.backup"].firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 30))
        backup.click()
        XCTAssertTrue(app.descendants(matching: .any)["setup.transfer.to"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["setup.transfer.from"].exists)
        capture(app, "mac-transfer")
        app.terminate()
        app.launchArguments = fixtureArguments() + ["-OpenStreamVisionScreen", "metadata"]
        app.launch()
        let advanced = app.buttons["settings.metadata.advanced"].firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 30))
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        advanced.click()
        XCTAssertTrue(app.secureTextFields["settings.metadata.tmdb"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["settings.metadata.omdb"].exists)
        capture(app, "mac-metadata-advanced")
    }

    private func terminateCapturingFailure(_ app: XCUIApplication) {
        if let run = testRun, run.totalFailureCount > 0, app.state == .runningForeground {
            capture(app, "mac-failure-" + name)
        }
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, _ name: String, window: XCUIElement? = nil) {
        let attachment = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDiscoverWindowScreenshot() throws {
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = fixtureArguments()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60), "The macOS app never opened a window.")

        // Give the Discover shelves a chance to render before the shutter.
        let discover = app.descendants(matching: .any).matching(identifier: "tab.discover").firstMatch
        _ = discover.waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 6)

        let shot = window.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "macOS Discover"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Text proof alongside the pixels, so a blank window cannot pass silently.
        let labels = app.descendants(matching: .any)
            .allElementsBoundByIndex
            .prefix(60)
            .map { "\($0.elementType.rawValue) \($0.identifier) \($0.label)" }
            .joined(separator: "\n")
        let tree = XCTAttachment(string: labels)
        tree.name = "macOS accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)

        app.terminate()
    }
}
