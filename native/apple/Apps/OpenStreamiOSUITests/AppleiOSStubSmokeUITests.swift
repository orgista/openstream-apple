import XCTest
import Vision

/// Launch → Discover row → title page → back, with every control-plane
/// request answered from `Apps/TestPlans/Stubs` (`-OpenStreamStubNetwork`):
/// isolated sources and the same screen every run. The trailer check uses
/// YouTube's live official player.
@MainActor
final class AppleiOSStubSmokeUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!

    func testSettingsAndAboutScreenshots() {
        for appearance in ["light", "dark"] {
            let arguments = Self.stubbedLaunchArguments + ["-OpenStreamDebugColorScheme", appearance,
                "-openstream.firstRunGuidanceSeen", "YES", "-openstream.backup.icloud.enabled.v1", "NO",
                "-openstream.reset.cloudRestoreHeld.v1", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
            func open(_ screen: String) {
                app.terminate()
                app.launchArguments = arguments + ["-OpenStreamVisionScreen", screen]
                app.launch()
            }
            open("settings")
            XCTAssertTrue(app.buttons["settings.sources"].firstMatch.waitForExistence(timeout: 20))
            captureTint("settings-root-" + appearance)
            let about = app.buttons["settings.about"].firstMatch
            scrollToControl(about, in: app)
            XCTAssertTrue(about.isHittable)
            about.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.about.version"].firstMatch.waitForExistence(timeout: 10))
            captureTint("settings-about-" + appearance)
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "settings.about.dolbyVision.")).firstMatch.exists)
            XCTAssertFalse(app.buttons["Share Diagnostics"].exists)
            let acknowledgements = app.buttons["settings.about.acknowledgements"].firstMatch
            XCTAssertTrue(acknowledgements.exists)
            XCTAssertTrue(app.buttons["settings.about.privacy"].exists)
            XCTAssertTrue(app.buttons["settings.about.support"].exists)
            acknowledgements.tap()
            let dovi = app.buttons["settings.acknowledgements.libdovi"].firstMatch
            scrollToControl(dovi, in: app)
            XCTAssertTrue(dovi.isHittable)
            dovi.tap()
            let license = app.staticTexts["settings.acknowledgements.license"].firstMatch
            XCTAssertTrue(license.waitForExistence(timeout: 10))
            XCTAssertTrue(license.label.contains("Permission is hereby granted"))
            captureTint("settings-libdovi-license-" + appearance)
            app.navigationBars.buttons.firstMatch.tap()
            app.navigationBars.buttons.firstMatch.tap()
            let noContent = app.staticTexts["settings.about.noContent"].firstMatch
            scrollToControl(noContent, in: app)
            XCTAssertTrue(noContent.isHittable)
            XCTAssertTrue(noContent.label.contains("doesn't provide any content"))
            captureTint("settings-about-no-content-" + appearance)

            open("backup")
            let transfer = app.buttons["setup.transfer.to"].firstMatch
            XCTAssertTrue(transfer.waitForExistence(timeout: 20))
            transfer.tap()
            XCTAssertTrue(app.textFields["setup.transfer.link"].waitForExistence(timeout: 10))
            captureTint("settings-transfer-" + appearance)

            open("add-live")
            XCTAssertTrue(app.textFields["Name"].firstMatch.waitForExistence(timeout: 20))
            let save = app.buttons["sources.live.save"].firstMatch
            scrollToControl(save, in: app)
            XCTAssertTrue(save.exists)
            captureTint("settings-add-live-" + appearance)

            open("metadata")
            let advanced = app.buttons["settings.metadata.advanced"].firstMatch
            XCTAssertTrue(advanced.waitForExistence(timeout: 20))
            XCTAssertFalse(app.secureTextFields.firstMatch.exists)
            advanced.tap()
            XCTAssertTrue(app.secureTextFields["settings.metadata.tmdb"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.secureTextFields["settings.metadata.omdb"].firstMatch.exists)
            captureTint("settings-metadata-advanced-" + appearance)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(advanced.waitForExistence(timeout: 10))

            if appearance == "dark" {
                open("playback-settings")
                let info = app.buttons["settings.playback.info"].firstMatch
                scrollToControl(info, in: app)
                XCTAssertTrue(info.isHittable)
                info.tap()
                XCTAssertTrue(app.navigationBars["Playback Info"].waitForExistence(timeout: 10))
                for label in ["Engine", "Platform", "HDR Playback"] {
                    XCTAssertTrue(app.descendants(matching: .any).matching(
                        NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.exists)
                }
                captureTint("settings-playback-info")
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = Self.stubbedLaunchArguments
    }

    override func tearDown() {
        app?.terminate()
    }

    func testDiscoverRowSizingScreenshots() throws {
        try launchHomeRowSettingsFixture(app)
        captureTint("r2-ios-hero")
        app.swipeUp()
        app.swipeUp()
        captureTint("r2-ios-rows")
        app.swipeUp()
        app.swipeUp()
        captureTint("r2-ios-posters")
    }

    private func homeHeading(_ title: String) -> XCUIElement {
        let heading = app.staticTexts[title].firstMatch
        for _ in 0..<12 {
            if heading.exists && heading.isHittable { return heading }
            if heading.exists && heading.frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        return heading
    }

    private func openHomeRowsSettings() {
        app.tabBars.buttons["Settings"].tap()
        let homeRows = app.buttons["settings.homeRows"].firstMatch
        scrollToControl(homeRows, in: app)
        XCTAssertTrue(homeRows.waitForExistence(timeout: 10))
        XCTAssertTrue(homeRows.isHittable)
        homeRows.tap()
        XCTAssertTrue(app.buttons["settings.homeRows.recentlyAdded"].firstMatch.waitForExistence(timeout: 10))
    }

    private func replaceHomeRowName(with name: String, submit: Bool = true) {
        let field = app.textFields["settings.homeRows.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + name)
        if submit { field.typeText("\n") }
    }

    func testHomeRowNameCommitsOnSubmitAndOnLeavingTheEditor() throws {
        try launchHomeRowSettingsFixture(app)
        openHomeRowsSettings()
        app.buttons["settings.homeRows.recentlyAdded"].firstMatch.tap()
        replaceHomeRowName(with: "Weekend Movies", submit: false)
        XCTAssertTrue(app.navigationBars["Recently Added"].exists, "Typing must leave the saved name unchanged")
        captureTint("r2-ios-name-draft")
        app.navigationBars.buttons.firstMatch.tap()
        let row = app.buttons["settings.homeRows.recentlyAdded"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Weekend Movies"].waitForExistence(timeout: 5))
        captureTint("r2-ios-name-on-exit")
        replaceHomeRowName(with: "Evening Movies")
        XCTAssertTrue(app.navigationBars["Evening Movies"].waitForExistence(timeout: 5))
        captureTint("r2-ios-name-submitted")
    }

    func testHomeRowsHideRenameAndReset() throws {
        try launchHomeRowSettingsFixture(app)
        XCTAssertTrue(homeHeading("Recently Added").isHittable)
        openHomeRowsSettings()
        app.buttons["settings.homeRows.recentlyAdded"].firstMatch.tap()
        let toggle = app.switches["settings.homeRows.show"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        captureTint("sizes-ios-row-editor")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        captureTint("sizes-ios-row-hidden")
        XCTAssertEqual(toggle.value as? String, "0")
        app.tabBars.buttons["Discover"].tap()
        XCTAssertFalse(app.staticTexts["Recently Added"].exists)

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        replaceHomeRowName(with: "My Movies")
        XCTAssertTrue(app.buttons["settings.homeRows.resetName"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(homeHeading("My Movies").isHittable)
        captureTint("sizes-ios-renamed")

        app.tabBars.buttons["Settings"].tap()
        let reset = app.buttons["settings.homeRows.resetAll"].firstMatch
        scrollToControl(reset, in: app)
        reset.tap()
        app.sheets.buttons["Reset All"].tap()
        app.tabBars.buttons["Discover"].tap()
        XCTAssertTrue(homeHeading("Recently Added").isHittable)
        XCTAssertFalse(app.staticTexts["My Movies"].exists)
        captureTint("sizes-ios-reset")
    }

    func testHomeRowTitleRenameAndHideShortcuts() throws {
        try launchHomeRowSettingsFixture(app)
        let heading = homeHeading("Recently Added")
        XCTAssertTrue(heading.isHittable)
        heading.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename..."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh"].exists)
        app.buttons["Rename..."].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "Weekend Picks")
        app.alerts.buttons["Save"].tap()
        let renamed = homeHeading("Weekend Picks")
        XCTAssertTrue(renamed.isHittable)
        renamed.press(forDuration: 1)
        app.buttons["Hide Row"].tap()
        XCTAssertFalse(app.staticTexts["Weekend Picks"].exists)
    }

    func testHomeRowsWithSixOverlappingLibraries() throws {
        guard let base = ProcessInfo.processInfo.environment["OPENSTREAM_HOME_ROWS_BASE"], base.hasPrefix("http://127.0.0.1:") else {
            throw XCTSkip("Run Tests/Fixtures/home_rows_proof.py")
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("home-rows-\(UUID()).json")
        let source: [String: Any] = ["kind": "mediaServer", "server": "jellyfin", "name": "Rill", "url": base + "/jf",
            "username": "fixture", "password": "fixture-password"]
        let folder: [String: Any] = ["kind": "folder", "name": "Fixture Library", "path": Self.stubDirectory + "/library"]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source, folder],
            "settings": ["tmdbAPIKey": "fixture"]]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamDevSources", file.path,
            "-OpenStreamVisionScreen", "discover", "-OpenStreamStubLiveBase", base,
            "-openstream.settings.discover.top10Lists.v1", "YES", "-openstream.reset.cloudRestoreHeld.v1", "YES",
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        app.launch()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 60))
        let expected = Set(["Recently Added", "Top 10 This Week", "Movies", "TV Shows", "Latest Movies · Rill", "Latest Shows · Rill"])
        var headings = Set<String>()
        var rowIDs = Set<String>()
        var titleRows: [String: String] = [:]
        func fixtureArtworkIsVisible(in frames: [CGRect], viewport: CGRect) -> Bool {
            guard let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
            let scaleX = CGFloat(image.width) / viewport.width
            let scaleY = CGFloat(image.height) / viewport.height
            return frames.allSatisfy { frame in
                let point = CGPoint(x: frame.midX * scaleX, y: frame.midY * scaleY)
                guard let pixel = image.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)) else { return false }
                var bytes = [UInt8](repeating: 0, count: 4)
                return bytes.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    let red = Int(buffer[0]), green = Int(buffer[1]), blue = Int(buffer[2])
                    return max(red, max(green, blue)) - min(red, min(green, blue)) > 12
                }
            }
        }
        for step in 0..<14 {
            let before = headings
            var currentTitles: [String: String] = [:]
            var artworkFrames: [CGRect] = []
            let snapshot = try app.snapshot()
            func collect(_ element: XCUIElementSnapshot, in row: String? = nil) {
                let id = element.identifier.hasPrefix("home.row.") ? element.identifier : row
                if element.identifier.hasPrefix("home.row.") { rowIDs.insert(element.identifier) }
                if element.elementType == .staticText, expected.contains(element.label), snapshot.frame.intersects(element.frame) {
                    headings.insert(element.label)
                }
                if let id, element.elementType == .button,
                   element.label.hasPrefix("Rill Movie ") || element.label.hasPrefix("Rill Show ") {
                    let title = element.label
                    if let prior = currentTitles[title] { XCTAssertEqual(prior, id, "Duplicate title in two rendered rows: \(title)") }
                    currentTitles[title] = id
                    titleRows[title] = id
                    let frame = element.frame
                    let picture = CGRect(x: frame.minX + frame.width * 0.2, y: frame.minY + frame.height * 0.15,
                        width: frame.width * 0.6, height: frame.height * 0.5)
                        .intersection(snapshot.frame.insetBy(dx: 0, dy: 100))
                    if picture.width > 20, picture.height > 20 { artworkFrames.append(picture) }
                }
                for child in element.children { collect(child, in: id) }
            }
            collect(snapshot)
            if step == 0 || headings != before {
                if !artworkFrames.isEmpty {
                    let frames = artworkFrames
                    let viewport = snapshot.frame
                    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        fixtureArtworkIsVisible(in: frames, viewport: viewport)
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed, "Fixture artwork must load before capture")
                }
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "home-rows-ios-\(step)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.swipeUp()
        }
        XCTAssertEqual(headings, expected)
        XCTAssertGreaterThanOrEqual(rowIDs.count, 6)
        XCTAssertGreaterThanOrEqual(titleRows.count, 4)
        XCTAssertLessThanOrEqual(rowIDs.count + 1, 8, "Includes the hero")
        XCTAssertFalse(app.staticTexts["Top Picks for You"].exists)
        XCTAssertFalse(app.staticTexts["Recommended for You"].exists)
        let evidence = XCTAttachment(string: "Rows: \(rowIDs.sorted())\nHeadings: \(headings.sorted())\nRendered titles: \(titleRows.keys.sorted())")
        evidence.name = "home-rows-ios-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testOneStartupIndicatorThroughResolutionAndBothEngines() async throws {
        for route in ["native", "surface"] {
            app.launchArguments = try startupFixtureArguments()
            app.launch()
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.' AND label == %@", "Stub Movie Five")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 30))
            title.tap()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            try await verifyStartupHandoff(app, route: route) { play.tap() }
            app.terminate()
        }
    }

    func testStartupCanBeCancelledAndFailureAppearsAfterDismissal() async throws {
        let play = try openStartupFixtureTitle()
        try await startupControl("reset-native")
        play.tap()
        try await waitForStartupRequest("resolving")
        let close = app.buttons["player.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            play.isHittable && play.isEnabled && play.label != "Preparing playback"
        }, object: nil)
        let returnedResult = await XCTWaiter.fulfillment(of: [returned], timeout: 10)
        captureTint("startup-returned-to-title")
        XCTAssertEqual(returnedResult, .completed)
        XCTAssertFalse(app.activityIndicators["player.connecting"].exists)
        try await startupControl("release-resolution")
        try await startupControl("release-media")
        try await startupControl("reset-native")
        play.tap()
        try await waitForStartupRequest("resolving")
        try await startupControl("fail-resolution")
        let alertAppeared = app.alerts["Playback Unavailable"].waitForExistence(timeout: 20)
        captureTint("startup-cancel-and-resolution-failure")
        XCTAssertTrue(alertAppeared)
    }

    func testStartupCanBeCancelledAtEngineHandoff() async throws {
        let play = try openStartupFixtureTitle()
        try await startupControl("reset-native")
        play.tap()
        try await waitForStartupRequest("resolving")
        try await startupControl("release-resolution")
        try await waitForStartupRequest("engine")
        let close = app.buttons["player.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        close.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            play.isHittable && play.isEnabled && play.label != "Preparing playback"
        }, object: nil)
        let returnedResult = await XCTWaiter.fulfillment(of: [returned], timeout: 10)
        captureTint("startup-returned-to-title")
        XCTAssertEqual(returnedResult, .completed)
        XCTAssertFalse(app.activityIndicators["player.connecting"].exists)
        captureTint("startup-engine-cancel")
        try await startupControl("release-media")
    }

    func testStartupTimeoutOffersRetryAndThenPlays() async throws {
        let play = try openStartupFixtureTitle()
        try await startupControl("reset-native")
        play.tap()
        try await waitForStartupRequest("resolving")
        let retry = app.buttons["player.startup.retry"].firstMatch
        let timeoutAppeared = retry.waitForExistence(timeout: 40)
        captureTint("startup-timeout-presentation")
        XCTAssertTrue(timeoutAppeared)
        XCTAssertTrue(app.staticTexts["Playback Timed Out"].exists)
        XCTAssertFalse(app.activityIndicators["player.connecting"].exists)
        captureTint("startup-timeout-retry")
        try await startupControl("release-resolution")
        try await startupControl("release-media")
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch.waitForExistence(timeout: 45))
        XCTAssertFalse(app.activityIndicators["player.connecting"].exists)
        captureTint("startup-timeout-recovered")
    }

    private func openStartupFixtureTitle() throws -> XCUIElement {
        app.launchArguments = try startupFixtureArguments()
        app.launch()
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.' AND label == %@", "Stub Movie Five")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        title.tap()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            play.isEnabled && play.label != "Preparing playback"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        return play
    }

    func testContinueWatchingCaptions() {
        app.launchArguments = ["-OpenStreamContinueWatchingFixture", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["S2 E5 · 23 min left"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["1 hr 12 min left"].exists)
        XCTAssertTrue(app.staticTexts["Next · S2 E6"].exists)
        captureTint("continue-watching")
    }

    func testTintControlsInLightAndDark() {
        for appearance in ["light", "dark"] {
            app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamVisionScreen", "detail-movie",
                "-OpenStreamDetailTitle", "Stub Movie Two", "-OpenStreamDebugColorScheme", appearance,
                "-openstream.settings.trailer.autoplay.v1", "NO"]
            configureFixtureLaunch(app)
            app.launch()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 60))
            captureTint("prominent-" + appearance)
            app.buttons["Rate"].firstMatch.tap()
            XCTAssertTrue(app.buttons["I Like This"].firstMatch.waitForExistence(timeout: 15))
            captureTint("menu-" + appearance)
            app.terminate()
            app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamVisionScreen", "about",
                "-OpenStreamDebugColorScheme", appearance]
            configureFixtureLaunch(app)
            app.launch()
            let acknowledgements = app.buttons["settings.about.acknowledgements"].firstMatch
            XCTAssertTrue(acknowledgements.waitForExistence(timeout: 10))
            acknowledgements.tap()
            let link = app.descendants(matching: .any)["settings.acknowledgements.sourceCode"].firstMatch
            scrollToControl(link, in: app, limit: 12)
            XCTAssertTrue(link.exists && link.isHittable)
            captureTint("link-" + appearance)
            app.terminate()
        }
    }

    private func captureTint(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "ios-tint-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCompactHeroPagesRespondAtTheTopOfTheir44PointTargets() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone hero targets")
        configureFixtureLaunch(app)
        app.launch()
        let pages = app.descendants(matching: .any)["home.featured.pages"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 60))
        captureTint("hero-targets-before")
        let value = try XCTUnwrap(pages.value as? String)
        let count = try XCTUnwrap(value.split(separator: " ").last.flatMap { Int($0) })
        XCTAssertGreaterThan(count, 1)
        XCTAssertGreaterThanOrEqual(pages.frame.height, 44)
        XCTAssertLessThanOrEqual(pages.frame.width, CGFloat(20 + (count - 1) * 12 + 44) + 1)
        for (page, fromLeading, inset, y): (Int, Bool, CGFloat, CGFloat) in [
            (count, false, 24, 1), (1, true, 24, 43),
            (count, false, 3, 22), (1, true, 3, 22)
        ] {
            let frame = pages.frame
            pages.coordinate(withNormalizedOffset: CGVector(
                dx: fromLeading ? inset / frame.width : (frame.width - inset) / frame.width,
                dy: y / frame.height)).tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "value == %@", "Page \(page) of \(count)"), object: pages)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "iphone-compact-hero-44-point-targets"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCompactHeroReferenceScreenshot() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone hero appearance")
        configureFixtureLaunch(app)
        app.launch()
        let pages = app.descendants(matching: .any)["home.featured.pages"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 60))
        XCTAssertEqual(pages.label, "Featured")
        let play = app.buttons["home.featured.play"].firstMatch
        let content = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND hittable == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [content], timeout: 30), .completed)
        let pixels = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().lowercased().filter(\.isLetter)
        XCTAssertTrue(words.contains("stubmoviesix"), "The hero title must be painted in the screenshot")
        let geometry = XCTAttachment(string: "\(pages.frame); center=(\(pages.frame.midX), \(pages.frame.midY))")
        geometry.name = "hero-indicator-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        captureTint("hero-reference")
    }

    func testTitleAboutAndInformationAppearExactlyOnce() {
        for screen in ["detail", "detail-movie"] {
            app.terminate()
            app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamVisionScreen", screen,
                "-openstream.settings.titlePage.about.v1", "YES",
                "-openstream.settings.titlePage.information.v1", "YES",
                "-openstream.settings.trailer.autoplay.v1", "NO"]
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
            var found = Set<String>()
            for _ in 0..<16 {
                for identifier in ["detail.about", "detail.information"] {
                    let matches = app.descendants(matching: .any).matching(identifier: identifier)
                    XCTAssertLessThanOrEqual(matches.count, 1, "Duplicate \(identifier) on \(screen)")
                    if matches.count == 1 { found.insert(identifier) }
                }
                app.swipeUp()
            }
            XCTAssertEqual(found, ["detail.about", "detail.information"], "Missing sections on \(screen)")
        }
    }

    func testRegularTitleInformationFollowsItsSwitch() throws {
        app.launch()
        try XCTSkipUnless(app.windows.firstMatch.horizontalSizeClass == .regular,
                          "Requires a regular-width title layout")
        for (visit, enabled) in [true, false, true].enumerated() {
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", "general-settings",
                "-OpenStreamResetOnLaunch", visit == 0 ? "YES" : "NO"]
            configureFixtureLaunch(app)
            app.launch()
            let toggle = app.switches["settings.titlePage.information"].firstMatch
            scrollToControl(toggle, in: app, limit: 20)
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            let wanted = enabled ? "1" : "0"
            if toggle.value as? String != wanted {
                let control = toggle.switches.firstMatch
                (control.exists ? control : toggle).tap()
            }
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", "detail", "-OpenStreamResetOnLaunch", "NO",
                "-openstream.settings.trailer.autoplay.v1", "NO"]
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
            let information = app.descendants(matching: .any)["detail.information"].firstMatch
            var found = information.exists
            for _ in 0..<12 {
                app.swipeUp()
                found = found || information.exists
            }
            XCTAssertEqual(found, enabled, "Information must follow its title-page switch")
        }
    }

    func testTitlePageSectionSwitchesKeepPlaybackAndEpisodes() {
        let names = ["trailers", "cast", "information", "about"]
        let sections = ["detail.trailers", "detail.cast", "detail.information", "detail.languages", "detail.about"]
        func launch(_ screen: String) {
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamStubNetwork", Self.stubDirectory,
                "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
                "-openstream.settings.trailer.autoplay.v1", "NO"]
            configureFixtureLaunch(app)
            app.launch()
        }
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        func setSections(on: Bool) {
            launch("general-settings")
            for name in names {
                let toggle = app.switches["settings.titlePage.\(name)"].firstMatch
                scrollToControl(toggle, in: app, limit: 20)
                XCTAssertTrue(toggle.waitForExistence(timeout: 10))
                let wanted = on ? "1" : "0"
                if toggle.value as? String != wanted {
                    let control = toggle.switches.firstMatch
                    (control.exists ? control : toggle).tap()
                }
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            }
            capture(on ? "fixture-title-switches-on" : "fixture-title-switches-off")
        }
        func visibleSections() -> Set<String> {
            var found = Set<String>()
            for _ in 0..<8 {
                for identifier in sections where app.descendants(matching: .any)[identifier].firstMatch.exists {
                    found.insert(identifier)
                }
                app.swipeUp()
            }
            return found
        }
        func openSeries() {
            launch("detail")
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
            let episodes = app.descendants(matching: .any)["detail.episodes"].firstMatch
            scrollToControl(episodes, in: app)
            XCTAssertTrue(episodes.waitForExistence(timeout: 10))
        }
        addTeardownBlock { @MainActor in setSections(on: true) }
        setSections(on: true)
        openSeries()
        let shown = visibleSections()
        XCTAssertTrue(shown.contains("detail.information"))
        XCTAssertTrue(shown.contains("detail.about"))
        capture("fixture-title-sections-on")
        setSections(on: false)
        openSeries()
        XCTAssertTrue(visibleSections().isEmpty, "Disabled title-page sections remain visible")
        capture("fixture-title-sections-off")
        setSections(on: true)
        openSeries()
        XCTAssertEqual(visibleSections(), shown, "Re-enabling the sections must restore them")
        capture("fixture-title-sections-restored")
    }

    func testDuoLayoutReferenceScreens() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let orientations: [UIDeviceOrientation] = isPad ? [.portrait, .landscapeLeft] : [.portrait]
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let prefix = "duo-\(isPad ? "ipad" : "iphone")-\(orientation == .portrait ? "portrait" : "landscape")"
            func capture(_ screen: String) {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = prefix + "-" + screen
                shot.lifetime = .keepAlways
                add(shot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = prefix + "-" + screen + "-elements"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            func open(_ screen: String) {
                app.terminate()
                app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamVisionScreen", screen]
                configureFixtureLaunch(app)
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            }
            open("discover")
            let details = app.buttons["home.featured.details"].firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 60))
            XCTAssertTrue(app.buttons["Search"].firstMatch.isHittable)
            capture("discover")
            details.tap()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            let back = app.buttons["detail.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            XCTAssertEqual(back.label, "Back")
            if min(app.frame.width, app.frame.height) < 600 {
                XCTAssertEqual(back.frame.minX, 16, accuracy: 1)
                XCTAssertGreaterThanOrEqual(back.frame.width, 44)
                XCTAssertGreaterThanOrEqual(back.frame.height, 44)
            }
            capture("title")
            open("live")
            XCTAssertTrue(app.descendants(matching: .any)["live.stage.player"].firstMatch.waitForExistence(timeout: 60))
            XCTAssertTrue(app.buttons["live.guide"].firstMatch.exists)
            capture("live")
            open("settings")
            XCTAssertTrue(app.buttons["Sources"].firstMatch.waitForExistence(timeout: 30))
            capture("settings")
        }
    }

    func testLargeWindowOnPhoneUsesThePadPresentation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Phone-hosted large window proof")
        }
        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamDebugLayoutSize", "951,669",
                                                            "-OpenStreamVisionScreen", "discover"]
        configureFixtureLaunch(app)
        app.launch()
        let captureButton = app.buttons["debug.layout.capture"].firstMatch
        XCTAssertTrue(captureButton.waitForExistence(timeout: 30))
        // Owner rule "no unused real estate": the unfolded canvas is used edge to edge.
        func assertSpansCanvas(_ element: XCUIElement, _ canvas: CGRect, _ what: String) {
            XCTAssertEqual(element.frame.minX, canvas.minX, accuracy: 2, what + " starts at the window edge")
            XCTAssertEqual(element.frame.width, canvas.width, accuracy: 2, what + " spans the window")
        }
        var captureIndex = 0
        func capture(_ name: String) {
            captureButton.tap()
            let value = captureButton.value as? String ?? ""
            XCTAssertTrue(value.contains("duo-layout-\(captureIndex).png"), value)
            let record = XCTAttachment(string: value)
            record.name = name + "-canvas"
            record.lifetime = .keepAlways
            add(record)
            let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            preview.name = name + "-host"
            preview.lifetime = .keepAlways
            add(preview)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + "-elements"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            captureIndex += 1
        }
        for shape in ["wide", "portrait"] {
            if shape == "portrait" {
                app.buttons["debug.layout.rotate"].firstMatch.tap()
            }
            let size = shape == "wide" ? "951x669" : "669x951"
            XCTAssertTrue((captureButton.value as? String ?? "").contains(size + " phone regular"))
            tapTab("Discover")
            let details = app.buttons["home.featured.details"].firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 60))
            // A phone keeps its landing chrome at any size (owner 2026-10-20): no bar, round Search over the art.
            XCTAssertFalse(app.navigationBars["Discover"].exists)
            XCTAssertTrue(app.buttons["discover.compact-title.search"].firstMatch.isHittable)
            let play = app.buttons["home.featured.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            let canvas = app.windows.containing(.button, identifier: "home.featured.play").firstMatch
            XCTAssertTrue(canvas.exists)
            let canvasFrame = canvas.frame
            let scale = min(canvas.frame.width / (shape == "wide" ? 951 : 669),
                            canvas.frame.height / (shape == "wide" ? 669 : 951))
            XCTAssertEqual(play.frame.minX / scale, 24, accuracy: 2)
            XCTAssertEqual(play.frame.width / scale, 180, accuracy: 2)
            let heroAtEdges = expectation(for: NSPredicate { _, _ in
                self.heroArtReachesBothEdges(of: canvasFrame, rows: [120, 160, 200, 240, 280].map { $0 * scale })
            }, evaluatedWith: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [heroAtEdges], timeout: 15), .completed,
                           "The Discover hero's art reaches both edges")
            capture("duo-large-\(shape)-discover")
            details.tap()
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30))
            capture("duo-large-\(shape)-title")
            app.buttons["detail.back"].firstMatch.tap()
            XCTAssertTrue(details.waitForExistence(timeout: 10), "Back must return to Discover")

            tapTab("Library")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title."))
                .firstMatch.waitForExistence(timeout: 60))
            XCTAssertFalse(app.navigationBars["Library"].exists)
            XCTAssertTrue(app.buttons["library.compact-title.search"].firstMatch.isHittable)
            capture("duo-large-\(shape)-library")
            tapTab("Live")
            let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
            XCTAssertTrue(stage.waitForExistence(timeout: 60))
            let guide = app.buttons["live.guide"].firstMatch
            XCTAssertTrue(guide.exists)
            let schedule = app.descendants(matching: .any)["live.stage.schedule"].firstMatch
            let list = app.descendants(matching: .any)["live.list"].firstMatch
            XCTAssertTrue(list.exists)
            if shape == "wide" {
                XCTAssertGreaterThan(guide.frame.midX, stage.frame.maxX)
                XCTAssertTrue(schedule.waitForExistence(timeout: 10), "The stage's column must continue with the schedule")
                XCTAssertGreaterThanOrEqual(schedule.frame.minY, stage.frame.maxY - 1)
                XCTAssertLessThan(schedule.frame.maxX, guide.frame.minX)
                // Stage and channel list side by side share the whole width.
                XCTAssertEqual(stage.frame.minX, canvasFrame.minX, accuracy: 2, "The Live stage starts at the window edge")
                XCTAssertGreaterThanOrEqual(list.frame.minX, stage.frame.maxX - 2)
                XCTAssertGreaterThanOrEqual(list.frame.maxX, tabColumnEdge(canvasFrame) - 24 * scale,
                                            "The channel list reaches the tab bar")
            } else {
                XCTAssertGreaterThan(guide.frame.minY, stage.frame.maxY)
                XCTAssertFalse(schedule.exists)
                assertSpansCanvas(stage, canvasFrame, "The Live stage")
                assertSpansCanvas(list, canvasFrame, "The channel list")
            }
            let playing = expectation(for: NSPredicate(format: "value == %@", "Playing"), evaluatedWith: stage)
            XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed)
            capture("duo-large-\(shape)-live")
            tapTab("Settings")
            let sources = app.buttons["Sources"].firstMatch
            XCTAssertTrue(sources.waitForExistence(timeout: 30))
            XCTAssertTrue(sources.isHittable)
            let mediaServer = app.buttons["Media Server"].firstMatch
            XCTAssertTrue(mediaServer.waitForExistence(timeout: 15))
            let beside = expectation(for: NSPredicate { _, _ in
                mediaServer.exists && sources.exists && mediaServer.frame.minX > sources.frame.maxX
            }, evaluatedWith: nil)
            let splitResult = XCTWaiter.wait(for: [beside], timeout: 15)
            capture("duo-large-\(shape)-settings")
            XCTAssertEqual(splitResult, .completed, "Settings must keep both panes beside each other")
            XCTAssertGreaterThanOrEqual(app.navigationBars.count, 2)
        }
        tapTab("Discover")
        app.buttons["home.featured.details"].firstMatch.tap()
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["debug.layout.fold"].firstMatch.tap()
        XCTAssertTrue((captureButton.value as? String ?? "").contains("466x678 phone compact"))
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 15))
        capture("duo-folded-title")
        app.buttons["debug.layout.fold"].firstMatch.tap()
        XCTAssertTrue((captureButton.value as? String ?? "").contains("669x951 phone regular"))
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 15))
        capture("duo-unfolded-title")
    }

    /// Every iPad window keeps the iPad's layout: a 1/3 split (compact width,
    /// under 600 pt) gets the bar over the landing hero, the title page's
    /// toolbar Back, the iPad's Live page and a pushed Settings stack.
    func testCompactIPadWindowKeepsThePadLayout() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad split-window proof")
        }
        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamDebugLayoutSize", "375,1032,compact",
                                                            "-OpenStreamVisionScreen", "discover"]
        configureFixtureLaunch(app)
        app.launch()
        let captureButton = app.buttons["debug.layout.capture"].firstMatch
        XCTAssertTrue(captureButton.waitForExistence(timeout: 30))
        XCTAssertTrue((captureButton.value as? String ?? "").contains("375x1032 pad compact"))
        func capture(_ name: String) {
            captureButton.tap()
            let record = XCTAttachment(string: captureButton.value as? String ?? "")
            record.name = name + "-canvas"
            record.lifetime = .keepAlways
            add(record)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = name + "-elements"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        let details = app.buttons["home.featured.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 60))
        XCTAssertTrue(app.navigationBars["Discover"].exists, "An iPad split keeps the bar over the hero")
        XCTAssertFalse(app.buttons["discover.compact-title.search"].exists)
        capture("ipad-split-discover")
        details.tap()
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30))
        let back = app.navigationBars.buttons["detail.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The iPad title page keeps Back in its toolbar")
        capture("ipad-split-title")
        back.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 10))

        tapTab("Library")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title."))
            .firstMatch.waitForExistence(timeout: 60))
        XCTAssertTrue(app.navigationBars["Library"].exists)
        capture("ipad-split-library")
        tapTab("Live")
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["live.guide"].firstMatch.exists)
        XCTAssertGreaterThan(app.buttons["live.guide"].firstMatch.frame.minY, stage.frame.maxY - 1)
        capture("ipad-split-live")
        tapTab("Settings")
        XCTAssertTrue(app.buttons["Sources"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Media Server"].exists, "A compact iPad window pushes Settings pages")
        capture("ipad-split-settings")
    }

    /// A 1/2 split on a 13-inch iPad on its side stacks Live like full screen.
    func testHalfIPadWindowStacksLive() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad split-window proof")
        }
        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamDebugLayoutSize", "683,1032",
                                                            "-OpenStreamVisionScreen", "live"]
        configureFixtureLaunch(app)
        app.launch()
        let captureButton = app.buttons["debug.layout.capture"].firstMatch
        XCTAssertTrue(captureButton.waitForExistence(timeout: 30))
        XCTAssertTrue((captureButton.value as? String ?? "").contains("683x1032 pad regular"))
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 60))
        let bar = app.descendants(matching: .any)["live.categories"].firstMatch
        let list = app.descendants(matching: .any)["live.list"].firstMatch
        XCTAssertTrue(bar.exists && list.exists)
        XCTAssertEqual(stage.frame.width, bar.frame.width, accuracy: 1, "The stage spans the window")
        XCTAssertEqual(bar.frame.minY, stage.frame.maxY, accuracy: 1)
        XCTAssertEqual(list.frame.minX, bar.frame.minX, accuracy: 1)
        XCTAssertEqual(list.frame.width, bar.frame.width, accuracy: 1)
        captureButton.tap()
        let record = XCTAttachment(string: (captureButton.value as? String ?? "")
            + "\nstage: \(stage.frame)\nbar: \(bar.frame)\nlist: \(list.frame)")
        record.name = "ipad-half-live-canvas"
        record.lifetime = .keepAlways
        add(record)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "ipad-half-live"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The hero's art, not the page's black background, reaches both side edges of `window`:
    /// at each edge at least one sample, `rows` points below the window's top, is not the page's
    /// pure black. The screenshot is lossless, so even near-black art (10, 10, 10 in a stub) counts;
    /// several rows keep one black spot in the art from reading as a gap.
    private func heroArtReachesBothEdges(of window: CGRect, rows: [CGFloat]) -> Bool {
        guard let image = XCUIScreen.main.screenshot().image.cgImage, app.frame.width > 0 else { return false }
        let ratio = CGFloat(image.width) / app.frame.width
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        func differsFromPage(x: CGFloat, y: CGFloat) -> Bool {
            let column = min(max(Int(x * ratio), 0), width - 1), row = min(max(Int(y * ratio), 0), height - 1)
            let offset = (row * width + column) * 4
            return pixels[offset..<offset + 3].contains { $0 > 3 }
        }
        return [window.minX + 2, window.maxX - 3].allSatisfy { x in
            rows.contains { differsFromPage(x: x, y: window.minY + $0) }
        }
    }

    /// Where a side tab bar (the unfolded Duo's) begins, else the window's edge.
    private func tabColumnEdge(_ window: CGRect) -> CGFloat {
        let rail = app.toolbars.buttons["Discover"].firstMatch
        return rail.exists && rail.frame.minX > window.midX ? rail.frame.minX : window.maxX
    }

    private func tapTab(_ title: String) {
        // iPadOS exposes floating tabs as buttons identified by their system symbols.
        let symbols = ["Discover": "sparkles", "Library": "books.vertical",
                       "Live": "dot.radiowaves.left.and.right", "Settings": "gearshape"]
        guard let symbol = symbols[title] else {
            XCTFail("Unknown native tab: \(title)")
            return
        }
        let buttons = [app.tabBars.buttons[title].firstMatch, app.toolbars.buttons[title].firstMatch,
                       app.buttons.matching(NSPredicate(format: "label == %@ AND identifier == %@", title, symbol)).firstMatch]
        let available = expectation(for: NSPredicate { _, _ in
            buttons.contains { $0.exists && $0.isHittable }
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 15), .completed)
        guard let button = buttons.first(where: { $0.exists && $0.isHittable }) else {
            XCTFail("The native \(title) tab is unavailable")
            return
        }
        button.tap()
    }

    /// On the code Apple TV shares: a film on a throwaway SMB share
    /// (`OPENSTREAM_RESUME_SMB`) watched part way, the app left with the
    /// player up and then quit, resumes from its title page. The film is
    /// private, so it stays out of the widgets' snapshot.
    func testShareFilmResumesFromTheTitlePageAndStaysOutOfTheWidgets() throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_RESUME_SMB"],
              let source = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw XCTSkip("Requires OPENSTREAM_RESUME_SMB") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resume-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let base = ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
                    "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
        app.launchArguments = base + ["-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES"]
        app.launch()
        func openFilm() {
            tapTab("Library")
            let film = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Verity'")).firstMatch
            XCTAssertTrue(film.waitForExistence(timeout: 90), "the share's film never reached the Library")
            film.tap()
        }
        openFilm()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.tap()
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "the film never played")
        Thread.sleep(forTimeInterval: 25)
        // Leaving the app saves the position and publishes the widgets.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 6)
        let widgets = (try? openStreamShelfSnapshot()["continueWatching"]) as? [[String: Any]] ?? []
        XCTAssertFalse(widgets.contains { ($0["title"] as? String)?.contains("Verity") == true },
                       "a private share title reached the widgets")
        app.terminate()
        app.launchArguments = base
        app.launch()
        openFilm()
        let resume = app.buttons.matching(NSPredicate(format: "identifier == 'detail.play' AND label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 60), "the title page does not offer Resume")
        let mark = openStreamTraceMark()
        resume.tap()
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "Resume did not play")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.alerts["Playback Unavailable"].exists)
        let trace = (try? currentOpenStreamTrace()) ?? []
        let log = XCTAttachment(string: trace.joined(separator: "\n"))
        log.name = "ios-share-resume-trace"; log.lifetime = .keepAlways; add(log)
        XCTAssertGreaterThan(openStreamPlayStart(of: "Verity", in: trace, after: mark, viaLink: false) ?? -1, 15,
                             "playback started over instead of resuming")
    }

    func testDuoNativeScreensAndTransitions() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_DUO_DEFAULT_POSTURE"] != "1" else {
            throw XCTSkip("Native fold control is unavailable; default window has its own capture test")
        }
        try await captureNativeDuoScreens(exercisesFolding: true)
    }

    func testDuoNativeDefaultPostureScreens() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_DUO_DEFAULT_POSTURE"] == "1" else {
            throw XCTSkip("Opt-in native Duo default-window capture")
        }
        try await captureNativeDuoScreens(exercisesFolding: false)
    }

    private func captureNativeDuoScreens(exercisesFolding: Bool) async throws {
        guard let address = ProcessInfo.processInfo.environment["OPENSTREAM_DUO_CONTROL_URL"] else {
            throw XCTSkip("Native Duo capture requires its loopback control server")
        }
        let controlURL = try XCTUnwrap(URL(string: address))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        executionTimeAllowance = 600

        func wait(_ predicate: NSPredicate, on object: Any? = nil, timeout: TimeInterval = 30) async {
            let pending = XCTNSPredicateExpectation(predicate: predicate, object: object)
            let result = await XCTWaiter.fulfillment(of: [pending], timeout: timeout)
            XCTAssertEqual(result, .completed, predicate.predicateFormat)
        }
        func request(_ command: String, tag: String? = nil) async throws {
            var components = try XCTUnwrap(URLComponents(url: controlURL.appendingPathComponent(command),
                                                        resolvingAgainstBaseURL: false))
            if let tag { components.queryItems = [URLQueryItem(name: "tag", value: tag)] }
            let url = try XCTUnwrap(components.url)
            let (_, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 60))
            XCTAssertEqual(try XCTUnwrap(response as? HTTPURLResponse).statusCode, 200)
        }
        func setFolded(_ folded: Bool) async throws {
            try await request(folded ? "fold" : "unfold")
            await wait(NSPredicate { _, _ in
                let frame = self.app.frame
                let shortSide = min(frame.width, frame.height)
                return !frame.isEmpty && (folded ? shortSide < 600 : shortSide >= 600)
            })
        }
        func capture(_ tag: String) async throws {
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertFalse(app.buttons["debug.layout.capture"].exists)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = tag; image.lifetime = .keepAlways; add(image)
            let tree = XCTAttachment(string: "app.frame=\(app.frame)\n" + app.debugDescription)
            tree.name = tag + "-elements"; tree.lifetime = .keepAlways; add(tree)
            try await request("capture", tag: tag)
        }
        func tab(_ title: String) async {
            let tabBarButton = app.tabBars.buttons[title].firstMatch
            let railButton = app.toolbars.buttons[title].firstMatch
            await wait(NSPredicate { _, _ in
                (tabBarButton.exists && tabBarButton.isHittable) || (railButton.exists && railButton.isHittable)
            })
            let button = tabBarButton.exists && tabBarButton.isHittable ? tabBarButton : railButton
            button.tap()
            await wait(NSPredicate(format: "selected == true"), on: button)
        }
        func seconds() -> Double? {
            let slider = app.sliders.firstMatch
            guard slider.exists, let text = slider.value as? String,
                  text.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
            return text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        func playing(after position: Double? = nil) async {
            await wait(NSPredicate { _, _ in
                let transport = self.app.buttons["player.play-pause"].firstMatch
                guard transport.exists, transport.label == "Pause",
                      let current = seconds() else { return false }
                return position.map { current > $0 } ?? true
            }, timeout: 60)
        }

        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamVisionScreen", "discover",
                                                             "-OpenStreamHoldPlayerChrome", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        await wait(NSPredicate { _, _ in self.app.state == .runningForeground })
        let details = app.buttons["home.featured.details"].firstMatch
        let detail = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
        let play = app.buttons["detail.play"].firstMatch
        let back = app.buttons["detail.back"].firstMatch
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch

        // Owner rule "no unused real estate": the art and the stage run edge to edge in every posture.
        func assertSpansWindow(_ element: XCUIElement, _ what: String) {
            XCTAssertEqual(element.frame.minX, app.frame.minX, accuracy: 1, what + " starts at the window edge")
            XCTAssertEqual(element.frame.width, app.frame.width, accuracy: 1, what + " spans the window")
        }
        defer { XCUIDevice.shared.orientation = .portrait }
        let small = min(app.frame.width, app.frame.height) < 600
        let passes: [(folded: Bool, landscape: Bool)] = exercisesFolding
            ? [(true, false), (true, true), (false, false), (false, true)]
            : [(small, false), (small, true)]
        for (index, pass) in passes.enumerated() {
            let folded = pass.folded
            let posture = exercisesFolding ? (folded ? "folded" : "unfolded")
                : (folded ? "default-small-window" : "default-large-window")
            let shape = posture + (pass.landscape ? "-landscape" : "")
            let exercisesTransitions = exercisesFolding && index == 0
            if exercisesFolding { try await setFolded(folded) }
            XCUIDevice.shared.orientation = pass.landscape ? .landscapeLeft : .portrait
            // A large window follows the device; a small phone window stays upright outside the player.
            await wait(NSPredicate { _, _ in
                (self.app.frame.width > self.app.frame.height) == (pass.landscape && !folded)
            })
            await tab("Discover")
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: details, timeout: 60)
            // Below the folded screen's status bar, which sits in the column beside the content.
            // The art loads after the hero's buttons.
            await wait(NSPredicate { _, _ in
                self.heroArtReachesBothEdges(of: self.app.frame, rows: [180, 220, 260, 300, 340])
            }, timeout: 15)
            try await capture("duo-native-\(shape)-discover")
            details.tap()
            await wait(NSPredicate(format: "exists == true"), on: play)
            await wait(NSPredicate(format: "exists == true"), on: detail)
            let titleID = detail.identifier
            XCTAssertFalse(titleID.isEmpty)
            try await capture("duo-native-\(shape)-title")
            if exercisesTransitions {
                for next in [false, true] {
                    try await setFolded(next)
                    await wait(NSPredicate(format: "exists == true AND hittable == true"), on: back)
                    XCTAssertEqual(detail.identifier, titleID)
                    XCTAssertTrue(play.exists)
                    try await capture("duo-native-title-transition-\(next ? "folded" : "unfolded")")
                }
            }
            back.tap()
            await wait(NSPredicate(format: "exists == false"), on: back)
            await wait(NSPredicate(format: "hittable == true"), on: details)

            await tab("Library")
            let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title.")).firstMatch
            await wait(NSPredicate(format: "exists == true"), on: tile, timeout: 60)
            try await capture("duo-native-\(shape)-library")
            await tab("Live")
            await wait(NSPredicate(format: "exists == true AND value == %@", "Playing"), on: stage, timeout: 60)
            let guide = app.buttons["live.guide"].firstMatch
            XCTAssertTrue(guide.exists)
            if folded {
                assertSpansWindow(stage, "The Live stage")
                let categories = app.descendants(matching: .any)["live.categories"].firstMatch
                XCTAssertGreaterThanOrEqual(categories.frame.minY, stage.frame.maxY - 1, "The stage stays above the category row")
            }
            if !folded {
                let list = app.descendants(matching: .any)["live.list"].firstMatch
                XCTAssertTrue(list.exists)
                if app.frame.width > app.frame.height {
                    XCTAssertGreaterThan(guide.frame.midX, stage.frame.maxX)
                    // Stage and channel list side by side share the whole width.
                    XCTAssertEqual(stage.frame.minX, app.frame.minX, accuracy: 1, "The Live stage starts at the window edge")
                    XCTAssertGreaterThanOrEqual(list.frame.minX, stage.frame.maxX - 1)
                    XCTAssertGreaterThanOrEqual(list.frame.maxX, tabColumnEdge(app.frame) - 24,
                                                "The channel list reaches the tab bar")
                } else {
                    XCTAssertGreaterThan(guide.frame.minY, stage.frame.maxY)
                    assertSpansWindow(stage, "The Live stage")
                    assertSpansWindow(list, "The channel list")
                }
            }
            try await capture("duo-native-\(shape)-live")
            await tab("Settings")
            let sources = app.buttons["Sources"].firstMatch
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: sources)
            if !folded {
                let mediaServer = app.buttons["Media Server"].firstMatch
                await wait(NSPredicate(format: "exists == true"), on: mediaServer)
                XCTAssertGreaterThan(mediaServer.frame.minX, sources.frame.maxX)
                XCTAssertGreaterThanOrEqual(app.navigationBars.count, 2)
            }
            try await capture("duo-native-\(shape)-settings")

            await tab("Discover")
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: details)
            details.tap()
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: play)
            let playingTitleID = detail.identifier
            play.tap()
            let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
            await wait(NSPredicate(format: "exists == true"), on: ready, timeout: 60)
            await playing()
            let start = try XCTUnwrap(seconds())
            await playing(after: start)
            try await capture("duo-native-\(shape)-player")
            if exercisesTransitions {
                for next in [false, true] {
                    let previous = try XCTUnwrap(seconds())
                    try await setFolded(next)
                    await wait(NSPredicate(format: "exists == true"), on: ready)
                    await playing()
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(seconds()), previous - 1)
                    await playing(after: previous)
                    try await capture("duo-native-player-transition-\(next ? "folded" : "unfolded")")
                }
            }
            let close = app.buttons["player.close"].firstMatch
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: close)
            close.tap()
            await wait(NSPredicate(format: "exists == true AND hittable == true"), on: back)
            XCTAssertEqual(detail.identifier, playingTitleID)
            back.tap()
            await wait(NSPredicate(format: "exists == false"), on: back)
        }
        if exercisesFolding { try await setFolded(true) }
    }

    func testMatchedLocalSeasonUsesProviderEpisodeMetadata() throws {
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture", "-OpenStreamStubNetwork", Self.stubDirectory,
            "-OpenStreamResetOnLaunch", "NO", "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = Self.stubDirectory + "/library-polish"
        app.launch()
        let title = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'library.title.' AND label CONTAINS[c] 'Abbott Elementary'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60))
        title.tap()
        let season = app.descendants(matching: .any).matching(identifier: "detail.season").firstMatch
        scrollToControl(season, in: app)
        XCTAssertTrue(season.waitForExistence(timeout: 30))
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Play S6 E1 · New Class")).firstMatch
        let hasProviderTitle = first.waitForExistence(timeout: 30)
        if !hasProviderTitle {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "polish-local-season6-elements"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            failure.name = "polish-local-season6-missing-title"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertTrue(hasProviderTitle, "The matched file did not receive its provider episode title")
        scrollToControl(first, in: app)
        let second = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Play S6 E2 · School Project")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "polish-local-season6-provider-metadata"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        first.swipeLeft()
        XCTAssertTrue(second.isHittable)
        let next = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        next.name = "polish-local-season6-second-still"
        next.lifetime = .keepAlways
        add(next)
    }

    func testLocalLibrarySearchHasNoRefreshAndOpensResult() {
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture", "-OpenStreamStubNetwork", Self.stubDirectory,
            "-OpenStreamResetOnLaunch", "NO", "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = Self.stubDirectory + "/library-polish"
        app.launch()
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Refresh"].exists)
        field.tap()
        field.typeText("Abbott")
        let result = app.links.matching(NSPredicate(format: "label CONTAINS[c] 'Abbott Elementary'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "Search must expose its result as an accessible link")
        XCTAssertFalse(app.buttons["Refresh"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "polish-search-no-refresh-accessible-result"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        result.tap()
        XCTAssertTrue(app.otherElements["detail.episodes"].firstMatch.waitForExistence(timeout: 30))
    }

    func testLiveUsesProviderLogoAndCleanMonograms() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("polish-live-\(UUID().uuidString).json")
        try Data(#"{"version":1,"sources":[{"kind":"m3u","name":"Polish Live","playlistURL":"https://fixture.example/iptv/polish-channels.m3u","epgURL":"https://fixture.example/iptv/guide.xml"}]}"#.utf8).write(to: file)
        app.launchArguments = ["-OpenStreamStubNetwork", Self.stubDirectory, "-OpenStreamVisionScreen", "live",
            "-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES",
            "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        for name in ["CBS", "Fixture News", "Fixture Film"] {
            let channel = app.buttons.matching(NSPredicate(format:
                "identifier BEGINSWITH 'guide.play.' AND label BEGINSWITH %@", "Play " + name)).firstMatch
            XCTAssertTrue(channel.waitForExistence(timeout: 60), "Live did not display the clean channel name")
        }
        func channel(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format:
                "identifier BEGINSWITH 'guide.play.' AND label BEGINSWITH %@", "Play " + name)).firstMatch
        }
        // The fixture logo is a solid (64,64,64) image. Its area distinguishes
        // rendered provider art from text or a fallback tile in the actual row.
        func logoArea(in row: XCUIElement) -> Double {
            guard row.exists, let image = row.screenshot().image.cgImage, row.frame.width > 0 else { return 0 }
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return 0 }
            let count = stride(from: 0, to: pixels.count, by: 4).filter { offset in
                (60...68).contains(pixels[offset]) && (60...68).contains(pixels[offset + 1])
                    && (60...68).contains(pixels[offset + 2])
            }.count
            let scale = Double(width) / Double(row.frame.width)
            return Double(count) / (scale * scale)
        }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            logoArea(in: channel("CBS")) > 250
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed,
            "Live must render the provider logo rather than a monogram")
        tapTab("Library")
        XCTAssertTrue(channel("CBS").waitForNonExistence(timeout: 10), "Switching to Library did not leave Live")
        tapTab("Live")
        let cached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            logoArea(in: channel("CBS")) > 250
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cached], timeout: 10), .completed,
            "A recreated Live row must show its memory-cached logo")
        for name in ["Fixture News", "Fixture Film"] {
            let row = channel(name)
            XCTAssertLessThan(logoArea(in: row), 100, "Missing and failed logos must use monograms")
            let screenshot = row.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "polish-monogram-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let scale = Double(image.width) / Double(row.frame.width)
            // Include the Live row's leading inset and its full 50-point tile.
            let tile = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0,
                width: min(Double(image.width), 72 * scale), height: Double(image.height))))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01
            try VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])
            let expected = name == "Fixture News" ? "FN" : "FF"
            let recognized = request.results?.compactMap { $0.topCandidates(1).first?.string.uppercased() } ?? []
            XCTAssertTrue(recognized.contains(expected), "Expected \(expected) in \(name)'s tile; recognized \(recognized)")
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "polish-live-provider-logo-missing-and-failed-logo-monograms"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testTitlePageFillDistribution() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_DETAIL_SPEED_MEASURE"] == "1" else {
            throw XCTSkip("Opt-in repeated library opening measurement")
        }
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture", "-OpenStreamStubNetwork", Self.stubDirectory,
            "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamDebugDetailsDelay", "2"]
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = Self.stubDirectory + "/library"
        for mode in ["cold", "warm"] {
            for sample in 1...10 {
                if mode == "cold" {
                    app.terminate()
                    app.launchEnvironment["OPENSTREAM_DETAIL_SPEED_COLD"] = mode == "cold" ? "1" : "0"
                    app.launch()
                }
                let tile = app.descendants(matching: .any).matching(identifier: "library.title.Stub Movie One").firstMatch
                XCTAssertTrue(tile.waitForExistence(timeout: 60))
                // The same shelf dwell in both builds lets the normal library
                // matcher publish catalog fields before navigation.
                Thread.sleep(forTimeInterval: 2)
                tile.tap()
                XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 20))
                Thread.sleep(forTimeInterval: 2)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "detail-speed-\(mode)-\(sample)"
                shot.lifetime = .keepAlways
                add(shot)
                let back = app.buttons["detail.back"].firstMatch
                if back.exists { back.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
                XCTAssertTrue(tile.waitForExistence(timeout: 10))
            }
        }
    }

    /// Requires network access to YouTube's official player.
    func testMediaServerHeroTrailerReachesPlaying() {
        app.launchArguments += ["-OpenStreamDebugTrailerKeys", "M7lc1UVf-VE",
                                "-openstream.settings.trailer.autoplay.v1", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        let details = app.buttons["home.featured.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 60), "A media-server-only setup has no Discover hero")
        details.tap()
        XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 30))
        let preview = app.buttons["detail.trailer.toggle"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'Playing'"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 60), .completed,
                       "The official YouTube player never revealed playing video")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "official-trailer-playing"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testServerHostedTrailerReachesPlaying() {
        app.launchArguments += ["-openstream.settings.trailer.autoplay.v1", "NO"]
        configureFixtureLaunch(app)
        app.launch()
        let details = app.buttons["home.featured.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 60))
        details.tap()
        let trailer = app.buttons["detail.serverTrailer"].firstMatch
        XCTAssertTrue(trailer.waitForExistence(timeout: 30))
        trailer.tap()
        let playing = app.descendants(matching: .any).matching(identifier: "trailer.player.playing").firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 30),
                       "The server-hosted trailer clock never advanced")
        XCTAssertEqual(playing.label, "")
        XCTAssertEqual(playing.frame.size, .zero)
    }

    func testDiscoverRowOpensATitleFromStubsAndComesBack() {
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        // The five hero titles consume the Latest row. Six remains in Continue Watching.
        let poster = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.continue.", "Stub Movie Six")).firstMatch
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.' OR identifier BEGINSWITH 'discover.'")).firstMatch
            .waitForExistence(timeout: 60), "Discover never drew")
        // The row is lazy and a page swipe can carry it past the top: scroll
        // until it is on screen, and back down a little when it went by.
        // A frame check, not `isHittable`: a card still outside the window has
        // no activation point, and asking for one fails the test outright.
        let visible = app.frame.insetBy(dx: 0, dy: 80)
        func onScreen() -> Bool {
            guard let frame = (try? poster.snapshot())?.frame else { return false }
            return visible.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0 ..< 10 where !onScreen() {
            guard let frame = (try? poster.snapshot())?.frame else { app.swipeUp(); _ = poster.waitForExistence(timeout: 3); continue }
            if frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertTrue(onScreen(), "the fixture server's row never drew")
        poster.tap()

        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(app.staticTexts["Stub Movie Six"].firstMatch.waitForExistence(timeout: 10))

        if min(app.frame.width, app.frame.height) < 600 {
            // Owner, 2026-10-19: "in the content page there is a search icon we don't need".
            XCTAssertFalse(app.buttons["Search"].firstMatch.isHittable)
            XCTAssertFalse(app.navigationBars.firstMatch.exists)
            let compactTitle = app.staticTexts["detail.compact-title"].firstMatch
            XCTAssertFalse(compactTitle.exists)
            // The compact title appears once the hero block has scrolled away: Play
            // is gone from the hierarchy or its frame is above the status bar. A
            // page that cannot scroll at all (Play's frame unchanged after the first
            // swipe) keeps the hero, and no compact title is the right outcome.
            // Snapshots, not live reads: iOS 27 has no status-bar element and Play
            // can leave the hierarchy mid-loop, and a live read of either raises.
            let statusBarBottom = (try? app.statusBars.firstMatch.snapshot())?.frame.maxY ?? 0
            let startFrame = (try? play.snapshot())?.frame ?? .zero
            for swipe in 0..<6 {
                app.swipeUp()
                let playFrame = (try? play.snapshot())?.frame
                if swipe == 0, let playFrame, playFrame == startFrame {
                    print("note: the stub title page cannot scroll; compact title not asserted")
                    break
                }
                if playFrame == nil || playFrame!.maxY < statusBarBottom {
                    XCTAssertTrue(compactTitle.waitForExistence(timeout: 5),
                                  "the hero scrolled away but the compact title never appeared")
                    break
                }
            }
        }

        let back = app.buttons["detail.back"].firstMatch
        if back.waitForExistence(timeout: 5) {
            if min(app.frame.width, app.frame.height) < 600 {
                // Row 30: a 44 pt control on every iOS, glass included (iOS 27 measured 26.67 pt before).
                XCTAssertGreaterThanOrEqual(back.frame.width, 44, "Back is narrower than 44 pt")
                XCTAssertGreaterThanOrEqual(back.frame.height, 44, "Back is shorter than 44 pt")
            }
            back.tap()
        } else { app.navigationBars.buttons.firstMatch.tap() }
        XCTAssertFalse(play.waitForExistence(timeout: 5), "the title page did not close")
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "Discover did not come back")
    }

    /// Library → Unmatched → Match picks a title, which leaves the shelf with
    /// its art; Use Automatic Match on the title page puts it back.
    func testUnmatchedShelfMatchesAndReverts() throws {
        // The reset clears metadata keys and lookup caches left on the
        // simulator, so the fixture's misses cache as no-matches. Match
        // searches TMDB, answered from the stub files.
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture"] + Self.stubbedLaunchArguments
            + (try tmdbFixtureKeyLaunchArguments())
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = Self.stubDirectory + "/library-unmatched"
        app.launch()
        func shot(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0 ..< 6 where !(element.exists && element.isHittable) {
                app.swipeUp()
                _ = element.waitForExistence(timeout: 2)
            }
        }

        // The Library is lazy: Unmatched sits under the other shelves and only
        // enters the hierarchy once it scrolls into view.
        let tile = app.buttons["library.unmatched.Quiet Harbor Home Video"].firstMatch
        XCTAssertTrue(app.buttons["library.title.Quiet Harbor Home Video"].firstMatch.waitForExistence(timeout: 60),
                      "the fixture library never drew")
        reveal(tile)
        XCTAssertTrue(tile.exists && tile.isHittable, "the Unmatched shelf never drew")
        XCTAssertTrue(app.buttons["library.unmatched.Lantern Street Rehearsal"].firstMatch.exists)
        shot("unmatched-shelf")
        tile.tap()

        let query = app.textFields["detail.fixMatch.query"].firstMatch
        XCTAssertTrue(query.waitForExistence(timeout: 10), "Match did not open")
        XCTAssertTrue(app.navigationBars["Match"].exists)
        query.tap()
        query.typeText("Stub Movie Two")
        app.buttons["detail.fixMatch.search"].firstMatch.tap()
        let result = app.buttons["detail.fixMatch.result.tt0000002"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "no search result")
        shot("unmatched-match-results")
        result.tap()
        XCTAssertTrue(tile.waitForNonExistence(timeout: 10), "the matched title stayed on the Unmatched shelf")
        XCTAssertTrue(app.buttons["library.unmatched.Lantern Street Rehearsal"].firstMatch.exists)
        shot("unmatched-after-match")

        let matched = app.buttons["library.title.Quiet Harbor Home Video"].firstMatch
        app.swipeDown()
        reveal(matched)
        matched.tap()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(app.staticTexts["Stub Movie Two"].firstMatch.waitForExistence(timeout: 10))
        play.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["detail.fixMatch"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["detail.fixMatch"].firstMatch.label, "Change Metadata")
        let automatic = app.buttons["detail.automaticMatch"].firstMatch
        XCTAssertTrue(automatic.exists, "a manual match offers no way back")
        shot("unmatched-title-menu")
        automatic.tap()
        XCTAssertTrue(app.staticTexts["Quiet Harbor Home Video"].firstMatch.waitForExistence(timeout: 10),
                      "the automatic title did not replace the manual match")
        shot("unmatched-after-automatic-match")
        let back = app.buttons["detail.back"].firstMatch
        let backExists = back.waitForExistence(timeout: 5)
        if !backExists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "unmatched-after-automatic-match-elements"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(backExists, "automatic matching lost the title page's Back control")
        back.tap()
        XCTAssertTrue(matched.waitForExistence(timeout: 10), "the Library did not come back")
        reveal(tile)
        XCTAssertTrue(tile.exists, "Use Automatic Match did not return the title to Unmatched")
    }
}
