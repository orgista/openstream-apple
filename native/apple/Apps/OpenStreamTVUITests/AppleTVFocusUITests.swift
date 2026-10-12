import XCTest
import Vision

/// Focus behaviour on Apple TV, driven by the Siri Remote.
///
/// Every fix that depended on focus shipped unverified for a whole session,
/// because there is no way to press a remote from a script *except* from here:
/// `simctl` has no such API. Each of these assertions replaces something the
/// owner previously had to check by hand and report back.
@MainActor
final class AppleTVFocusUITests: OpenStreamUITestCase {
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
        if screen == "live", let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"],
           let url = URL(string: fixture), url.scheme == "http", url.host == "127.0.0.1" {
            app.launchArguments += ["-OpenStreamDebugLiveFixture", fixture,
                                    url.deletingLastPathComponent().appendingPathComponent("guide.xml").absoluteString,
                                    "-OpenStreamTrace", "YES",
                                    "-openstream.settings.trailer.autoplay.v1", "NO"]
            if let date = ProcessInfo.processInfo.environment["OPENSTREAM_GUIDE_DATE"] {
                app.launchArguments += ["-OpenStreamDebugGuideDate", date]
            }
        } else {
            app.launchArguments += ["-OpenStreamVisionScreen", screen,
                                    "-OpenStreamTrace", "YES"]
        }
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

    /// The focused element, if it also matches `predicate`. Waiting on this
    /// replaces "press, sleep, read the focus": it resolves as soon as focus
    /// lands and fails with a timeout rather than a guess.
    private func focused(where predicate: NSPredicate) -> XCUIElement {
        app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "hasFocus == true"), predicate
        ])).firstMatch
    }

    /// Waits for an element rather than sleeping: the guide loads over the
    /// network and a fixed sleep either flakes or wastes time.
    @discardableResult
    private func wait(for element: XCUIElement, _ timeout: TimeInterval = 30) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - The guide

    func testSeasonMenuStartsOnCurrentSeasonAndReturnsFocus() {
        app.launchArguments += ["-OpenStreamMuteAudio", "YES"]
        if let title = ProcessInfo.processInfo.environment["OPENSTREAM_DETAIL_FIXTURE_NAME"] {
            app.launchArguments += ["-OpenStreamDetailTitle", title, "-openstream.settings.trailer.autoplay.v1", "NO"]
        }
        if let id = ProcessInfo.processInfo.environment["OPENSTREAM_DETAIL_FIXTURE_ID"] {
            app.launchArguments += ["-OpenStreamDebugPlayID", id, "-OpenStreamDebugPlayType", "series", "-OpenStreamDebugStreamFixture", "YES"]
        }
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40))
        let season = element("detail.season")
        XCTAssertTrue(season.waitForExistence(timeout: 40))
        remote.press(.down)
        let seasonFocus = season.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(season.hasFocus || seasonFocus.waitForExistence(timeout: 10))
        let current = season.value as? String ?? season.label
        remote.press(.select)
        let openMenu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        openMenu.name = "season-menu-open"
        openMenu.lifetime = .keepAlways
        add(openMenu)
        // The system popup does not expose its focused row to XCUITest.
        // Selecting immediately must choose the already checked season;
        // Specials receiving focus instead would change this value.
        remote.press(.select)
        XCTAssertTrue(season.hasFocus || seasonFocus.waitForExistence(timeout: 10))
        XCTAssertEqual(season.value as? String ?? season.label, current,
                       "Season menu did not start on its checked season")
        remote.press(.select)
        remote.press(.menu)
        XCTAssertTrue(season.hasFocus || seasonFocus.waitForExistence(timeout: 10))
    }

    func testLeftFromBottomOfPlaybackPaneReachesSidebar() {
        app.launchArguments += ["-OpenStreamMuteAudio", "YES", "-OpenStreamSettingsPane", "playback"]
        launch(screen: "settings")
        XCTAssertTrue(element("settings.section.sources").waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 1)
        remote.press(.right)
        for _ in 0..<18 { remote.press(.down) }
        XCTAssertFalse(focusedElement.identifier.hasPrefix("settings.section."))
        remote.press(.left)
        XCTAssertTrue(focused(where: NSPredicate(format: "identifier BEGINSWITH %@", "settings.section."))
            .waitForExistence(timeout: 10), "Left from the bottom row missed the sidebar")
    }

    /// Repeatable guide-only navigation, with no selection or playback.
    func testLocalGuideFocusLatency() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires the local 300-channel guide fixture")
        }
        let guide = URL(string: fixture)!.deletingLastPathComponent().appendingPathComponent("guide.xml").absoluteString
        app.launchArguments = ["-OpenStreamDebugLiveFixture", fixture, guide,
                               "-OpenStreamTrace", "YES", "-OpenStreamTiming", "YES",
                               "-openstream.settings.trailer.autoplay.v1", "NO"]
        if let date = ProcessInfo.processInfo.environment["OPENSTREAM_GUIDE_DATE"] {
            app.launchArguments += ["-OpenStreamDebugGuideDate", date]
        }
        app.launch()
        XCTAssertTrue(element("live.tv.info").waitForExistence(timeout: 30))
        try await Task.sleep(for: .seconds(3))
        // Give the external Instruments recorder a stable attach point.
        let ready = URL(string: fixture)!.deletingLastPathComponent().appendingPathComponent("ready")
        _ = try await URLSession.shared.data(from: ready)
        try await Task.sleep(for: .seconds(8))
        if !focusedElement.identifier.hasPrefix("guide.play.") { remote.press(.down) }
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."))
        let first = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        first.name = "guide-first-row"; first.lifetime = .keepAlways; add(first)
        // 100 real Down transitions and 100 Right transitions. Left moves
        // reset the horizontal route and are excluded from reported metrics.
        for _ in 0..<100 {
            remote.press(.down)
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."))
        XCTAssertTrue(focusedElement.label.contains("101"), focusedElement.label)
        let rows = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rows.name = "d4c-row-101"; rows.lifetime = .keepAlways; add(rows)
        let passes = max(1, Int(ProcessInfo.processInfo.environment["OPENSTREAM_GUIDE_PASSES"] ?? "10") ?? 10)
        for pass in 0..<passes {
            for _ in 0..<10 {
                remote.press(.right)
                try await Task.sleep(for: .milliseconds(250))
            }
            XCTAssertTrue(focusedElement.exists)
            let title = focusedElement.label.components(separatedBy: ", ").last ?? ""
            XCTAssertTrue(title.hasPrefix("Programme 101-"), focusedElement.label)
            XCTAssertTrue(element("live.tv.info").label.contains(title))
            if pass == 0 {
                let screenshot = XCUIScreen.main.screenshot()
                // The old shared-offset feedback could leave the focused cell
                // off screen. Enable this regression check for the fixed build;
                // baseline timing captures deliberately retain the old behavior.
                if ProcessInfo.processInfo.environment["OPENSTREAM_GUIDE_REQUIRE_VISIBLE"] == "1" {
                    let frame = focusedElement.frame
                    XCTAssertTrue(focusedElement.isHittable)
                    XCTAssertGreaterThan(app.frame.intersection(frame).width, frame.width * 0.9)
                    // Check the rendered info panel as well as its
                    // accessibility value and the focused cell’s geometry.
                    let image = try XCTUnwrap(screenshot.image.cgImage)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.regionOfInterest = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    let rendered = text.filter { $0.isLetter || $0.isNumber }.lowercased()
                    let expected = title.filter { $0.isLetter || $0.isNumber }.lowercased()
                    XCTAssertTrue(rendered.contains(expected), "The focused programme title was not drawn in the info panel")
                }
                let columns = XCTAttachment(screenshot: screenshot)
                columns.name = "d4c-column-10"; columns.lifetime = .keepAlways; add(columns)
                let capture = URL(string: fixture)!.deletingLastPathComponent().appendingPathComponent("capture")
                _ = try await URLSession.shared.data(from: capture)
            }
            for _ in 0..<10 {
                remote.press(.left)
                try await Task.sleep(for: .milliseconds(250))
            }
            XCTAssertTrue(focusedElement.exists)
        }
        print("Guide completed 100 Down and \(passes * 10) Right transitions")
        try await Task.sleep(for: .seconds(2))
        let capture = URL(string: fixture)!.deletingLastPathComponent().appendingPathComponent("capture")
        _ = try await URLSession.shared.data(from: capture)
    }


    func testRawTSSwipeUpArmsBeforeCaptionArrival() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_SUBTITLE_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires a localhost raw-TS fixture")
        }
        app.launchArguments = [
            "-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackURL", fixture,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamTrace", "YES",
            "-openstream.settings.captions.preference.v1", "off",
            "-openstream.settings.subtitle.languages.v1", "(en)"
        ]
        app.launch()
        try await Task.sleep(for: .milliseconds(200))
        remote.press(.up)
        let notice = app.staticTexts["Captions on"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 3))
        let armed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        armed.name = "n7-tvos-armed"; armed.lifetime = .keepAlways; add(armed)
        // The fixture holds its first TS bytes until the real remote command
        // has armed captions. This proves discovery cannot precede the swipe.
        let controlURL = try XCTUnwrap(URL(string: fixture)?.deletingLastPathComponent().appendingPathComponent("release"))
        var release = URLRequest(url: controlURL)
        release.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: release)
        let cue = app.staticTexts["N7 RAW TS CAPTIONS"].firstMatch
        let appeared = cue.waitForExistence(timeout: 45)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "n7-tvos-first-cue"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(appeared, "Armed raw-TS 608 did not render")
    }

    func testCaptionSelectionMatchesRendered608() throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["OPENSTREAM_SUBTITLE_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires a localhost 608 fixture")
        }
        let expectedCue = env["OPENSTREAM_SUBTITLE_FIXTURE_CUE"] ?? "N4 CAPTIONS WORK"
        let expectedTrack = env["OPENSTREAM_SUBTITLE_FIXTURE_TRACK"] ?? "English"
        app.launchArguments += [
            "-OpenStreamVisionPlaybackURL", fixture, "-OpenStreamVisionPlaybackIsLive", "YES",
            "-openstream.playback.engine", "engine", "-openstream.firstRunGuidanceSeen", "YES",
            "-openstream.settings.captions.preference.v1", "always",
            "-openstream.settings.subtitle.languages.v1", "(en)",
            "-openstream.sources.v1", "", "-openstream.sources.v1.pending-keychain-removals", "()",
            "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.settings.discover.enabled.v1", "NO",
            "-openstream.settings.live.enabled.v1", "NO",
            "-openstream.settings.library.enabled.v1", "NO",
            "-openstream.settings.metadata.enabled.v1", "NO"
        ]
        launch(screen: "add-files")
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
        }
        func cueVisible() throws -> Bool {
            let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return text.filter { !$0.isWhitespace }.uppercased()
                .contains(expectedCue.filter { !$0.isWhitespace }.uppercased())
        }
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if try cueVisible() { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(try cueVisible(), "Default-on 608 did not render")
        func openMenu() {
            let subtitles = app.cells.matching(NSPredicate(format: "label == 'Subtitles'")).firstMatch
            for _ in 0..<5 {
                remote.press(.down)
                if subtitles.waitForExistence(timeout: 2) { break }
            }
            capture("n6-tvos-controls")
            XCTAssertEqual(app.cells.matching(NSPredicate(format: "label == 'Subtitles'")).count, 1,
                "tvOS must expose exactly one captions transport control")
            XCTAssertFalse(app.cells["AVLegibleSettings"].exists, "AVKit captions button returned")
            remote.press(.up)
            for _ in 0..<6 {
                if subtitles.hasFocus || subtitles.descendants(matching: .any)
                    .matching(NSPredicate(format: "hasFocus == true")).count > 0 { break }
                remote.press(.right)
            }
            remote.press(.select)
            XCTAssertTrue(app.staticTexts["Off"].firstMatch.waitForExistence(timeout: 5))
        }
        openMenu()
        capture("n6-tvos-english")
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS 'selected' AND label CONTAINS %@", expectedTrack)).firstMatch.exists)
        XCTAssertTrue(try cueVisible())
        for _ in 0..<4 {
            if focusedElement.label.contains("Off") { break }
            remote.press(.up)
        }
        XCTAssertTrue(focusedElement.label.contains("Off"))
        remote.press(.select)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(try cueVisible(), "Off left a caption drawn")
        openMenu()
        capture("n6-tvos-off")
        XCTAssertTrue(app.cells.matching(NSPredicate(format: "label CONTAINS 'selected' AND label CONTAINS 'Off'")).firstMatch.exists)
        XCTAssertFalse(try cueVisible())
    }

    func testFullSubtitleMenuSelectsSpanish() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_SUBTITLE_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires a localhost three-track MKV fixture")
        }
        app.launchArguments += [
            "-OpenStreamVisionPlaybackURL", fixture, "-OpenStreamVisionPlaybackIsLive", "YES",
            "-openstream.playback.engine", "engine",
            "-openstream.firstRunGuidanceSeen", "YES",
            "-openstream.settings.captions.preference.v1", "off",
            "-openstream.settings.subtitle.languages.v1", "(en)",
            "-openstream.sources.v1", "", "-openstream.sources.v1.pending-keychain-removals", "()",
            "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.settings.discover.enabled.v1", "NO",
            "-openstream.settings.live.enabled.v1", "NO",
            "-openstream.settings.library.enabled.v1", "NO",
            "-openstream.settings.metadata.enabled.v1", "NO"
        ]
        launch(screen: "add-files")
        let subtitles = element("Subtitles")
        func subtitlesFocused() -> Bool {
            subtitles.exists && (subtitles.hasFocus || subtitles.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0)
        }
        func openSubtitlesMenu() {
            // A pick under More… returns AVKit's menu to its first level; Menu
            // closes it, leaving the captions item focused.
            if app.staticTexts["Off"].firstMatch.exists {
                remote.press(.menu)
                Thread.sleep(forTimeInterval: 1.5)
            }
            if subtitlesFocused() {
                remote.press(.select)
                XCTAssertTrue(app.staticTexts["Off"].firstMatch.waitForExistence(timeout: 5), "Subtitles menu did not open")
                return
            }
            // Reveal the transport bar, then step right to the captions item.
            for _ in 0..<15 {
                remote.press(.down)
                if subtitles.waitForExistence(timeout: 2) { break }
            }
            XCTAssertTrue(subtitles.exists)
            remote.press(.up)
            for _ in 0..<6 where !subtitlesFocused() { remote.press(.right) }
            remote.press(.select)
            XCTAssertTrue(app.staticTexts["Off"].firstMatch.waitForExistence(timeout: 5), "Subtitles menu did not open")
        }
        func focus(_ label: String) {
            for _ in 0..<6 where focusedElement.label != label { remote.press(.down) }
            XCTAssertEqual(focusedElement.label, label)
        }
        func isChecked(_ title: String) -> Bool {
            app.cells.matching(NSPredicate(format: "label CONTAINS 'selected' AND label CONTAINS %@", title))
                .firstMatch.exists
        }
        func attach(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        // The viewer's language up front, the rest under "More…" (full test
        // 2026-10-01): Off, English, English (SDH), More….
        openSubtitlesMenu()
        for title in ["Off", "English", "English (SDH)", "More…"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5), "Missing " + title)
        }
        XCTAssertFalse(app.staticTexts["Spanish"].firstMatch.exists, "Spanish belongs under More…")
        attach("n5-tvos-full-menu")
        focus("More…")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Spanish"].firstMatch.waitForExistence(timeout: 5), "More… has no Spanish")
        attach("n5-tvos-more-menu")
        focus("Spanish")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["HOLA DESDE ESPANA"].firstMatch.waitForExistence(timeout: 20))
        attach("n5-tvos-spanish-cue")

        // Reopened, the menu checks what is drawn: Spanish, not English.
        openSubtitlesMenu()
        XCTAssertFalse(isChecked("English"), "English is still checked after picking Spanish")
        focus("More…")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Spanish"].firstMatch.waitForExistence(timeout: 5))
        attach("n5-tvos-spanish-checked")
        XCTAssertTrue(isChecked("Spanish"), "Spanish is not checked after picking it")
    }

    /// Every Settings choice opened an empty page and Menu there left the app
    /// (Apple TV verification 2026-10-01). The Package choice must list its
    /// options, check the current one, and Menu must go back one level.
    func testSettingsChoicePageListsOptionsAndMenuGoesBack() throws {
        let folder = ProcessInfo.processInfo.environment["OPENSTREAM_SHOTS_DIR"].map(URL.init(fileURLWithPath:))
        func shoot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            try? screenshot.pngRepresentation.write(to: folder?.appendingPathComponent("\(name).png") ?? URL(fileURLWithPath: "/dev/null"))
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        func press(_ button: XCUIRemote.Button, wait: TimeInterval = 1.2) {
            remote.press(button)
            Thread.sleep(forTimeInterval: wait)
        }
        launch(screen: "settings")
        XCTAssertTrue(element("settings.section.channels").waitForExistence(timeout: 30), "Settings never opened")
        press(.down)
        press(.left)
        for _ in 1 ... 8 where focusedElement.identifier != "settings.section.channels" {
            press(focusedElement.identifier == "settings.section.sources" ? .down : .up)
        }
        XCTAssertEqual(focusedElement.identifier, "settings.section.channels")
        press(.right)
        for _ in 1 ... 4 where !focusedElement.label.hasPrefix("Package") { press(.down) }
        XCTAssertTrue(focusedElement.label.hasPrefix("Package"), "Package row never took focus, got '\(focusedElement.label)'")
        shoot("01-package-row")
        press(.select, wait: 2)
        shoot("02-package-page")
        for title in ["Complete Guide", "Everything", "Custom"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.waitForExistence(timeout: 5),
                          "The Package page does not list \(title)")
        }
        XCTAssertFalse(focusedElement.label.isEmpty, "Nothing on the Package page took focus")
        press(.menu, wait: 2)
        shoot("03-after-menu")
        XCTAssertEqual(app.state, .runningForeground, "Menu left the app")
        XCTAssertTrue(focusedElement.label.hasPrefix("Package"), "Menu did not return to the Package row, got '\(focusedElement.label)'")
    }

    func testFirstLiveHLSPlayOffersCaptions() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_CAPTION_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("A localhost OPENSTREAM_CAPTION_FIXTURE_URL is required")
        }
        app.launchArguments += [
            "-OpenStreamVisionPlaybackURL", fixture, "-OpenStreamVisionPlaybackIsLive", "YES",
            "-openstream.firstRunGuidanceSeen", "YES",
            "-openstream.settings.captions.preference.v1", "always",
            "-openstream.sources.v1", "", "-openstream.sources.v1.pending-keychain-removals", "()",
            "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.settings.discover.enabled.v1", "NO",
            "-openstream.settings.live.enabled.v1", "NO",
            "-openstream.settings.library.enabled.v1", "NO",
            "-openstream.settings.metadata.enabled.v1", "NO"
        ]
        launch(screen: "add-files")
        let subtitles = app.descendants(matching: .any).matching(identifier: "Subtitles").firstMatch
        for _ in 0..<12 {
            remote.press(.down)
            if subtitles.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(subtitles.exists, "Captions must be available on the first fixture open")
        let controls = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        controls.name = "first-play-hls-cc-controls"
        controls.lifetime = .keepAlways
        add(controls)
        // Down reveals the transport with focus on its timeline. Up reaches
        // the row of AVKit menu controls before moving across that row.
        remote.press(.up)
        for _ in 0..<6 {
            if subtitles.hasFocus || subtitles.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).count > 0 { break }
            remote.press(.right)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "first-play-caption-controls-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(subtitles.hasFocus || subtitles.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).count > 0,
            "The remote must reach the captions menu")
        remote.press(.select)
        let cc = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] 'CC' OR label CONTAINS[c] 'English'")).firstMatch
        XCTAssertTrue(cc.waitForExistence(timeout: 5), "The first-play menu must contain the embedded caption track")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "first-play-hls-cc-menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testChapterIntroCanBeReachedAndSkippedWithTheRemote() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_CHAPTER_FIXTURE_URL"],
              !fixture.isEmpty else {
            throw XCTSkip("OPENSTREAM_CHAPTER_FIXTURE_URL not set")
        }
        app.launchArguments += ["-OpenStreamVisionPlaybackURL", fixture]
        launch(screen: "add-files")
        let skip = element("player.skipIntro")
        XCTAssertTrue(wait(for: skip), "Chapter-backed Skip Intro never appeared")
        let surface = element("player.controls.show")
        let surfaceFocused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: surface)
        XCTAssertEqual(XCTWaiter.wait(for: [surfaceFocused], timeout: 10), .completed,
                       "The playback surface must receive initial focus before pressing Down")
        remote.press(.down)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: skip)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "The remote must reach Skip Intro from the playback surface")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "tv-chapter-before-skip"
        before.lifetime = .keepAlways
        add(before)
        remote.press(.select)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: skip)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        let sought = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "0:5[0-9]")).firstMatch
        XCTAssertTrue(sought.waitForExistence(timeout: 10), "Playback did not reach the 50-second chapter boundary")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "tv-chapter-after-skip"
        after.lifetime = .keepAlways
        add(after)
    }

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

    /// Owner 2026-09-21: "in live tv page you are unable to select favs bar
    /// back goes to the main top nav bar but there is no way to search in live
    /// or go to the favs bar". Menu from the grid lands on the category row
    /// first, a second Menu reaches the tab bar, and from the grid the
    /// Favorites chip and the search glyph are both reachable and selectable.
    func testLiveMenuReachesTheCategoryRowThenFavoritesAndSearch() {
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")

        func settle() { Thread.sleep(forTimeInterval: 1.5) }
        func snap(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }

        // (b) A few rows into the grid, Menu goes to the chip row, not the tab bar.
        remote.press(.down); settle()
        remote.press(.down); settle()
        remote.press(.down); settle()
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."),
                      "expected a channel before Menu, got '\(focusedElement.identifier)'")
        remote.press(.menu); settle()
        snap("4b-1-menu-from-grid-lands-on-chips")
        XCTAssertEqual(focusedElement.identifier, "live.category.All",
                       "Menu from the grid should land on the current chip, got '\(focusedElement.identifier)'")

        // A second Menu from the chip row is the system's: the tab bar.
        remote.press(.menu); settle()
        snap("4b-2-second-menu-reaches-tab-bar")
        XCTAssertEqual(focusedElement.label, "Live",
                       "Menu from the chip row should reach the tab bar, got '\(focusedElement.label)'")

        // (a) Into the grid, up to the chip row, right to Favorites, select.
        remote.press(.down); settle()
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."),
                      "down from the tab bar should reach a channel, got '\(focusedElement.identifier)'")
        remote.press(.up); settle()
        XCTAssertTrue(focusedElement.identifier.hasPrefix("live.category."),
                      "up from the grid should reach the chip row, got '\(focusedElement.identifier)'")
        remote.press(.right); settle()
        XCTAssertEqual(focusedElement.identifier, "live.category.Favorites")
        remote.press(.select); settle()
        snap("4b-3-favorites-selected")
        XCTAssertTrue(element("live.category.Favorites").isSelected, "Select did not choose the Favorites chip")

        // Back to All so the next launch finds the guide as it was.
        remote.press(.left); settle()
        remote.press(.select); settle()
        XCTAssertTrue(element("live.category.All").isSelected, "could not return to All")

        // (c) Right along the chip row to the search glyph, then open it.
        for _ in 0 ..< 20 where focusedElement.identifier != "live.search" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertEqual(focusedElement.identifier, "live.search", "never reached the search glyph")
        snap("4b-4-search-glyph-focused")
        remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "selecting the glyph did not open channel search")
        settle()
        snap("4b-5-channel-search-open")

        // Menu pops the search and returns to the guide.
        remote.press(.menu); settle()
        XCTAssertTrue(wait(for: element("live.search"), 10), "Menu did not return from search to the guide")
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

    /// Owner B24: the source choice, now the Quality picker (N38).
    ///
    /// On Apple TV it is not a visible control — it lives in a `contextMenu` on
    /// the Play button, so the only way to it is a long press of Select. That
    /// is worth a test precisely because nothing on screen advertises it: if
    /// the menu ever stopped opening, nothing else would reveal it.
    func testOtherSourcesIsReachableByLongPressingPlay() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        let playFocused = focused(where: NSPredicate(format: "identifier == %@", "detail.play"))
        XCTAssertTrue(playFocused.waitForExistence(timeout: 10),
                      "expected Play to hold focus on appear, got '\(focusedElement.label)'")

        remote.press(.select, forDuration: 2.0)

        let entry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Quality")).firstMatch
        let opened = entry.waitForExistence(timeout: 10)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "quality-context-menu"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(opened, "long-pressing Play did not reveal the Quality entry")
    }

    /// Owner B23: the episode list must show which episode is focused.
    ///
    /// Down from Play lands on the episode rail, through the Season picker
    /// when the show has more than one season. This walks one episode along and attaches the frame,
    /// so the thumbnails and the focused state can be looked at rather than
    /// assumed, and asserts the rail actually moves — a rail that swallows
    /// presses looks identical in a screenshot to one that works.
    ///
    /// Every step waits for focus to land instead of sleeping: Down is only
    /// meaningful once Play holds focus and the episodes have loaded, and the
    /// page used to open on Rate, from where Down reaches nothing.
    func testEpisodeRailMovesAndShowsTheFocusedEpisode() {
        launch(screen: "detail")
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        XCTAssertTrue(focused(where: NSPredicate(format: "identifier == %@", "detail.play")).waitForExistence(timeout: 10),
                      "expected Play to hold focus on appear, got '\(focusedElement.label)'")
        let isEpisode = NSPredicate(format: "label BEGINSWITH %@", "Play S")
        XCTAssertTrue(app.descendants(matching: .any).matching(isEpisode).firstMatch.waitForExistence(timeout: 30),
                      "the episode rail never loaded")

        // A show with more than one season has the Season picker between Play
        // and the rail, and Down from Play lands on it first, by design.
        let season = element("detail.season")
        if season.exists {
            remote.press(.down)
            let onSeason = season.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            XCTAssertTrue(season.hasFocus || onSeason.waitForExistence(timeout: 10),
                          "Down from Play did not reach the Season picker, got '\(focusedElement.label)'")
        }
        remote.press(.down)
        let firstEpisode = focused(where: isEpisode)
        XCTAssertTrue(firstEpisode.waitForExistence(timeout: 10),
                      "expected an episode to hold focus, got '\(focusedElement.label)'")
        let first = firstEpisode.label

        remote.press(.right)
        let moved = focused(where: NSCompoundPredicate(andPredicateWithSubpredicates: [
            isEpisode, NSPredicate(format: "label != %@", first)
        ]))
        XCTAssertTrue(moved.waitForExistence(timeout: 10),
                      "the episode rail did not move on Right; focus is on '\(focusedElement.label)'")
        let second = moved.label

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

    // MARK: - Hero artwork

    /// Owner 2026-09-20: "wordmarks not loading on (library) ap tv".
    ///
    /// The Library hero built `AppleFeaturedHero` without a `wordmark:`
    /// argument at all, so `AppleTVBillboardTitleTreatment` could only ever
    /// answer `.text`. This walks to the Library tab with the remote and keeps
    /// the frame, so the wordmark lockup is something a person can look at.
    func testLibraryHeroDrawsItsWordmarkOverTheBackdrop() {
        launch(screen: "library")
        let play = element("home.featured.play")
        XCTAssertTrue(wait(for: play, 60), "the Library billboard never appeared")
        // Give the wordmark and any textless upgrade time to land before the
        // frame is taken; neither blocks the billboard from drawing.
        Thread.sleep(forTimeInterval: 8.0)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "tvos-library-hero-wordmark"
        shot.lifetime = .keepAlways
        add(shot)

        // Focus has to reach the hero for the frame to be worth anything.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        let focusedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        focusedShot.name = "tvos-library-hero-focused"
        focusedShot.lifetime = .keepAlways
        add(focusedShot)

        print("LIBRARY HERO focused='\(focusedElement.label)'")
    }

    /// Discover's hero already worked. The textless change touches the same
    /// billboard, so this is the no-regression frame beside it.
    func testDiscoverHeroStillDrawsAfterTheTextlessChange() {
        launch(screen: "discover")
        let play = element("home.featured.play")
        XCTAssertTrue(wait(for: play, 60), "the Discover billboard never appeared")
        Thread.sleep(forTimeInterval: 8.0)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "tvos-discover-hero"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(play.exists, "Discover lost its billboard actions")
    }

    /// N12: the Discover hero after the Apple TV app. Read-only: focus moves
    /// over the buttons and pages, nothing is selected. Frames: at rest, after
    /// one cycle, focus on Play/Resume, on My List, and the page `→` turns.
    func testDiscoverHeroButtonsAndPagingKeepFocus() {
        launch(screen: "discover")
        let play = element("home.featured.play")
        XCTAssertTrue(wait(for: play, 60), "the Discover billboard never appeared")
        Thread.sleep(forTimeInterval: 6.0)
        attachScreen("n12-hero-rest")
        Thread.sleep(forTimeInterval: 13.0)
        attachScreen("n12-hero-after-cycle")

        // Down from the tab bar goes to the first row (the route as it was
        // before N12, untouched); up from there lands on the hero's first button.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        print("N12 HERO down-from-tab-bar focused='\(focusedElement.identifier)'")
        if !play.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 1.5)
            print("N12 HERO up-from-row focused='\(focusedElement.identifier)'")
        }
        // Up lands on the button nearest the card above; walk left to Play.
        for _ in 0..<2 where !play.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(play.hasFocus, "the hero's Play/Resume never took focus, got '\(focusedElement.identifier)'")
        attachScreen("n12-hero-focus-play")

        let myList = element("home.featured.my-list")
        if myList.exists {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertTrue(myList.hasFocus, "right from Play should focus My List, got '\(focusedElement.identifier)'")
            attachScreen("n12-hero-focus-mylist")
        }

        // Right past the last button turns the page and keeps focus in the hero.
        let pages = element("home.featured.pages")
        let before = pages.exists ? pages.label : ""
        for _ in 0..<3 { remote.press(.right); Thread.sleep(forTimeInterval: 0.8) }
        Thread.sleep(forTimeInterval: 2.0)
        attachScreen("n12-hero-paged-right")
        let heroIDs = ["home.featured.play", "home.featured.my-list", "home.featured.details"]
        XCTAssertTrue(heroIDs.contains(focusedElement.identifier),
                      "paging moved focus out of the hero, to '\(focusedElement.identifier)'")
        print("N12 HERO pages before='\(before)' after='\(pages.exists ? pages.label : "")' focused='\(focusedElement.identifier)'")

        // Left past Play turns back a page and keeps focus on Play.
        for _ in 0..<2 where !play.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 1.0)
        }
        let beforeLeft = pages.exists ? pages.label : ""
        remote.press(.left)
        Thread.sleep(forTimeInterval: 2.0)
        print("N12 HERO left-from-play pages before='\(beforeLeft)' after='\(pages.exists ? pages.label : "")' focused='\(focusedElement.identifier)'")
        XCTAssertTrue(play.hasFocus, "left past Play should keep focus on Play, got '\(focusedElement.identifier)'")
        XCTAssertNotEqual(beforeLeft, pages.exists ? pages.label : "", "left past Play should turn the page")

        // Down to the row and back up returns to the hero.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        print("N12 HERO down-from-hero focused='\(focusedElement.identifier)'")
        XCTAssertFalse(heroIDs.contains(focusedElement.identifier), "down from the hero should leave it for the rows")
        remote.press(.up)
        Thread.sleep(forTimeInterval: 2.0)
        print("N12 HERO up-from-row-2 focused='\(focusedElement.identifier)'")
        XCTAssertTrue(heroIDs.contains(focusedElement.identifier), "up from the first row should return to the hero")

        // Up and down leave the hero as before: the paging stops never catch them.
        remote.press(.up)
        Thread.sleep(forTimeInterval: 1.5)
        print("N12 HERO up-from-hero focused='\(focusedElement.identifier)' label='\(focusedElement.label)'")
        // After a trip to the rows the first up only scrolls the page back to
        // its top; the second reaches the tab bar. The Library hero, which N12
        // does not touch, does the same (measured 2026-09-23).
        if heroIDs.contains(focusedElement.identifier) {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 2.0)
            print("N12 HERO up-from-hero-again focused='\(focusedElement.identifier)' label='\(focusedElement.label)'")
        }
        XCTAssertFalse(heroIDs.contains(focusedElement.identifier), "up from the hero should reach the tab bar")
        attachScreen("n12-hero-up-from-hero")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        print("N12 HERO down-again focused='\(focusedElement.identifier)' label='\(focusedElement.label)'")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        print("N12 HERO down-again-2 focused='\(focusedElement.identifier)' label='\(focusedElement.label)'")
        XCTAssertFalse(heroIDs.contains(focusedElement.identifier), "down from the hero should leave it for the rows")
    }

    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Parity survey (N41)

    /// Opt-in walk through Discover, both kinds of title page, Library, Live,
    /// Search and Settings with the remote, for comparing against the Apple
    /// TV app. It logs where focus lands after every move (and its frame, for
    /// card sizes) and attaches a frame per stop. Navigation only: Select is
    /// pressed on a catalog poster and nothing else, and Play/Pause never.
    func testParitySurveyWalk() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_PARITY_SURVEY"] == "1" else {
            throw XCTSkip("Set OPENSTREAM_PARITY_SURVEY=1 to walk the screens for a parity survey.")
        }
        func log(_ step: String) {
            let f = focusedElement
            guard app.state == .runningForeground, f.exists else {
                return print("SURVEY \(step): nothing focused (app state \(app.state.rawValue))")
            }
            let frame = f.frame
            print("SURVEY \(step): id='\(f.identifier)' label='\(f.label.prefix(60))' "
                  + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        // Frames also go straight to a folder when one is given, so a run
        // whose result bundle is lost still leaves its pictures.
        let folder = ProcessInfo.processInfo.environment["OPENSTREAM_PARITY_SURVEY_DIR"].map(URL.init(fileURLWithPath:))
        var frameIndex = 0
        func shoot(_ step: String) {
            let screenshot = XCUIScreen.main.screenshot()
            if let folder {
                frameIndex += 1
                try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(String(format: "%02d-%@.png", frameIndex, step)))
            }
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
        func press(_ button: XCUIRemote.Button, _ step: String, wait: TimeInterval = 1.4, shot: Bool = true) {
            remote.press(button)
            Thread.sleep(forTimeInterval: wait)
            log(step)
            if shot { shoot(step) }
        }
        func headers(_ step: String) {
            let found = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'discover.shelf.' OR identifier BEGINSWITH 'library.shelf.'"))
                .allElementsBoundByIndex.prefix(6)
            for header in found where header.exists {
                let frame = header.frame
                print("SURVEY \(step) header: '\(header.label.prefix(40))' "
                      + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            }
        }
        func relaunch(_ screen: String, settle: TimeInterval = 14) {
            app.terminate()
            app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
            app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamTrace", "YES",
                                   "-openstream.settings.trailer.autoplay.v1", "NO"]
            app.launch()
            Thread.sleep(forTimeInterval: settle)
            log("\(screen)-open")
            shoot("\(screen)-open")
        }

        // Discover: the hero, then down through the rows (Top 10 among them).
        relaunch("discover", settle: 20)
        for step in 1 ... 8 { press(.down, "discover-down-\(step)"); if step == 2 { headers("discover") } }
        press(.right, "discover-row-right-1")
        press(.right, "discover-row-right-2")
        // Menu from deep in the rows: the Apple TV app scrolls back to the top.
        press(.menu, "discover-menu-1", wait: 2)
        press(.menu, "discover-menu-2", wait: 2)

        // A poster opened with Select: where focus lands, and where Menu returns.
        relaunch("discover", settle: 20)
        var opened = false
        for step in 1 ... 10 {
            press(.down, "open-down-\(step)", shot: false)
            if focusedElement.exists, focusedElement.identifier.hasPrefix("home.media.") { opened = true; break }
        }
        if opened {
            let poster = focusedElement.identifier
            press(.right, "open-poster")
            let target = focusedElement.identifier
            if target.hasPrefix("home.media.") {
                press(.select, "open-title-page", wait: 4)
                press(.menu, "open-back", wait: 2.5)
                print("SURVEY open-back expected='\(target)' first='\(poster)'")
            }
        }

        // The series and movie title pages, top to bottom.
        for (screen, prefix) in [("detail", "series"), ("detail-movie", "movie")] {
            relaunch(screen, settle: 24)
            for step in 1 ... 7 { press(.down, "\(prefix)-down-\(step)") }
            press(.right, "\(prefix)-right-1")
            for step in 1 ... 8 { press(.up, "\(prefix)-up-\(step)", shot: step == 8) }
            press(.menu, "\(prefix)-menu", wait: 2.5)
        }

        relaunch("library", settle: 16)
        for step in 1 ... 4 { press(.down, "library-down-\(step)"); if step == 2 { headers("library") } }
        press(.menu, "library-menu", wait: 2)

        relaunch("live", settle: 16)
        for step in 1 ... 3 { press(.down, "live-down-\(step)", wait: 0.8) }
        press(.menu, "live-menu", wait: 2)

        relaunch("discover", settle: 16)
        for _ in 0 ..< 3 { remote.press(.up); Thread.sleep(forTimeInterval: 1.0) }
        for _ in 0 ..< 5 where !(focusedElement.exists && focusedElement.label == "Search") { remote.press(.left); Thread.sleep(forTimeInterval: 1.0) }
        press(.select, "search-open", wait: 3)
        press(.down, "search-down-1")
        press(.down, "search-down-2")

        relaunch("settings", settle: 10)
        for step in 1 ... 4 { press(.down, "settings-down-\(step)", wait: 1.0) }
    }

    // MARK: - Discover Rows (N71)

    /// Opt-in: reaches Settings › Discover › Discover Rows with the remote,
    /// opens one row's Move page and backs out of it with Menu (never a move,
    /// so a viewer's order is left as it was), then shows Discover under the
    /// in-memory `-OpenStreamDebugDiscoverOrder` and moves down from the hero.
    /// Frames go to `OPENSTREAM_DISCOVER_ROWS_DIR`. Navigation only: Select is
    /// pressed on the Discover Rows link and on one row, Play/Pause never.
    func testDiscoverRowsSettingsWalk() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENSTREAM_DISCOVER_ROWS_DIR"] else {
            throw XCTSkip("Set OPENSTREAM_DISCOVER_ROWS_DIR to walk Settings › Discover › Discover Rows.")
        }
        let folder = URL(fileURLWithPath: dir)
        var frameIndex = 0
        func shoot(_ step: String) {
            let screenshot = XCUIScreen.main.screenshot()
            frameIndex += 1
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(String(format: "%02d-%@.png", frameIndex, step)))
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
        func log(_ step: String) {
            let f = focusedElement
            guard f.exists else { return print("ROWS \(step): nothing focused") }
            let frame = f.frame
            print("ROWS \(step): id='\(f.identifier)' label='\(f.label.prefix(60))' "
                  + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }
        func press(_ button: XCUIRemote.Button, _ step: String, wait: TimeInterval = 1.2) {
            remote.press(button)
            Thread.sleep(forTimeInterval: wait)
            log(step)
        }
        func rowLabels() -> [String] {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.discover.row.'"))
                .allElementsBoundByIndex.filter(\.exists)
                .map { "\($0.identifier.dropFirst("settings.discover.row.".count))=\($0.label)" }
        }

        // Settings: down the sidebar to Discover, across into its pane, down to
        // the Discover Rows link.
        app.launchArguments = ["-OpenStreamVisionScreen", "settings", "-OpenStreamTrace", "YES"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        log("settings-open")
        // Launch focus sits on the tab bar; down enters the Sources pane and
        // left crosses to the sections list.
        press(.down, "tabbar-down")
        press(.left, "sidebar-left")
        for step in 1 ... 8 where focusedElement.identifier != "settings.section.discover" {
            let sections = ["sources", "channels", "liveTV"].map { "settings.section.\($0)" }
            press(sections.contains(focusedElement.identifier) ? .down : .up, "sidebar-move-\(step)")
        }
        XCTAssertEqual(focusedElement.identifier, "settings.section.discover", "the sidebar never reached Discover")
        press(.right, "pane-right")
        // tvOS hands the focused Form row no identifier, so rows are matched
        // by their titles here.
        for step in 1 ... 5 where focusedElement.label != "Discover Rows" {
            press(.down, "pane-down-\(step)")
        }
        shoot("discover-pane-link-focused")
        XCTAssertEqual(focusedElement.label, "Discover Rows", "Discover Rows link never took focus")

        // The page itself: where focus lands, the rows by name, Reset.
        press(.select, "rows-open", wait: 2.5)
        shoot("rows-page")
        let before = rowLabels()
        print("ROWS listed (\(before.count)): \(before.joined(separator: " | "))")
        XCTAssertFalse(before.isEmpty, "Discover Rows listed no rows")
        let titles = before.map { String($0.split(separator: "=", maxSplits: 1).last ?? "") }
        XCTAssertTrue(titles.contains(focusedElement.label), "focus did not land on a row, got '\(focusedElement.label)'")
        let reset = app.buttons["Reset to Default Order"]
        print("ROWS reset exists=\(reset.exists) enabled=\(reset.exists && reset.isEnabled)")

        // One row down, pick it up with Select, carry it down one, put it
        // down with Select; then carry it back up so the order is as it was.
        press(.down, "rows-down-1")
        shoot("rows-second-focused")
        let carried = focusedElement.label
        press(.select, "carry-pick-up", wait: 1.5)
        shoot("carry-picked-up")
        press(.down, "carry-down", wait: 1.5)
        shoot("carry-moved-down")
        XCTAssertEqual(focusedElement.label, carried, "focus did not stay on the carried row")
        press(.select, "carry-put-down", wait: 1.5)
        let moved = rowLabels()
        XCTAssertEqual(moved.count, before.count)
        if before.count > 2 {
            XCTAssertEqual(moved[2], before[1], "the carried row did not move down one")
            XCTAssertEqual(moved[1], before[2], "the row below did not move up one")
        }
        press(.select, "carry-pick-up-again", wait: 1.5)
        press(.up, "carry-up", wait: 1.5)
        press(.menu, "carry-put-down-menu", wait: 1.5)
        XCTAssertTrue(titles.contains(focusedElement.label), "Menu left the page instead of putting the row down")
        let after = rowLabels()
        XCTAssertEqual(before, after, "carrying the row back did not restore the order")

        // To the bottom for Reset, then Menu back to the pane.
        for step in 1 ... 16 where focusedElement.label != "Reset to Default Order" {
            press(.down, "rows-bottom-\(step)", wait: 0.8)
        }
        print("ROWS all listed (\(rowLabels().count)): \(rowLabels().joined(separator: " | "))")
        shoot("rows-bottom")
        print("ROWS reset focused=\(focusedElement.label == "Reset to Default Order") enabled=\(reset.exists && reset.isEnabled)")
        press(.menu, "rows-back", wait: 2)
        shoot("rows-back-to-pane")

        // Discover under the in-memory order: Featured first, then Library.
        app.terminate()
        app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        let order = ProcessInfo.processInfo.environment["OPENSTREAM_DISCOVER_ROWS_ORDER"] ?? "featuredMovies,featuredShows,library"
        app.launchArguments = ["-OpenStreamVisionScreen", "discover", "-OpenStreamTrace", "YES",
                               "-openstream.settings.trailer.autoplay.v1", "NO",
                               "-OpenStreamDebugDiscoverOrder", order]
        app.launch()
        XCTAssertTrue(wait(for: element("home.featured.play"), 60), "the Discover billboard never appeared")
        Thread.sleep(forTimeInterval: 8)
        log("discover-open")
        shoot("discover-custom-order-hero")
        for step in 1 ... 3 {
            press(.down, "discover-down-\(step)", wait: 1.6)
            let headers = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'discover.shelf.' OR identifier == 'home.your-library'"))
                .allElementsBoundByIndex.prefix(6).filter(\.exists)
                .map { "'\($0.label.prefix(40))'@\(Int($0.frame.minY))" }
            print("ROWS discover-down-\(step) headers: \(headers)")
            shoot("discover-custom-order-down-\(step)")
        }
    }

    // MARK: - SharePlay source dialog (N72)

    /// Opt-in: opens Live with `-OpenStreamDebugSharedChannelChoices`, which
    /// shows the SharePlay "Choose the source for this channel" prompt (a
    /// pushed page on tvOS since N72) over the first two channels, photographs
    /// the focused choice and leaves with Menu. Nothing is chosen (a choice
    /// would start a channel), so no channel plays. Frames go to
    /// `OPENSTREAM_DIALOG_DIR`.
    func testSharePlaySourceDialogFocus() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENSTREAM_DIALOG_DIR"] else {
            throw XCTSkip("Set OPENSTREAM_DIALOG_DIR to photograph the SharePlay source dialog.")
        }
        let folder = URL(fileURLWithPath: dir)
        let prefix = ProcessInfo.processInfo.environment["OPENSTREAM_DIALOG_PREFIX"] ?? "shareplay"
        var frameIndex = 0
        func shoot(_ step: String) {
            let screenshot = XCUIScreen.main.screenshot()
            frameIndex += 1
            let name = String(format: "%@-%02d-%@.png", prefix, frameIndex, step)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name))
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
        func log(_ step: String) {
            let f = focusedElement
            guard f.exists else { return print("DIALOG \(step): nothing focused") }
            let frame = f.frame
            print("DIALOG \(step): id='\(f.identifier)' label='\(f.label.prefix(60))' "
                  + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }

        app.launchArguments = ["-OpenStreamVisionScreen", "live", "-OpenStreamTrace", "YES",
                               "-OpenStreamDebugSharedChannelChoices", "YES"]
        app.launch()
        let leave = app.buttons["Leave SharePlay"]
        XCTAssertTrue(wait(for: leave, 90), "the SharePlay source dialog never appeared")
        Thread.sleep(forTimeInterval: 2)
        log("dialog-open")
        // The page opens under the tab bar, which keeps launch focus there;
        // the dialog took focus itself. One Down reaches the first choice.
        if focusedElement.exists, focusedElement.label == "Live" {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.2)
            log("dialog-first-choice")
        }
        shoot("source-dialog-focused")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.2)
        log("dialog-down")
        shoot("source-dialog-second-focused")
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 2)
        log("dialog-dismissed")
        shoot("source-dialog-dismissed")
        for _ in 0 ..< 8 where leave.exists { Thread.sleep(forTimeInterval: 1) }
        log("dialog-dismissed-settled")
        shoot("source-dialog-dismissed-settled")
        XCTAssertFalse(leave.exists, "Menu did not close the SharePlay source dialog")
    }

    // MARK: - Download Options prompts (N73)

    /// Opt-in: opens a film's title page with `-OpenStreamDebugDownloadOptions
    /// title`, then a series' with `season`, each of which shows its download
    /// prompt with the choices of a running download but no download behind
    /// it. Photographs the focused choice and leaves with Menu; nothing is
    /// chosen and Play is never pressed. Frames go to `OPENSTREAM_DIALOG_DIR`.
    func testDownloadOptionsDialogFocus() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENSTREAM_DIALOG_DIR"] else {
            throw XCTSkip("Set OPENSTREAM_DIALOG_DIR to photograph the Download Options prompts.")
        }
        let folder = URL(fileURLWithPath: dir)
        let prefix = ProcessInfo.processInfo.environment["OPENSTREAM_DIALOG_PREFIX"] ?? "download-options"
        var frameIndex = 0
        func shoot(_ step: String) {
            let screenshot = XCUIScreen.main.screenshot()
            frameIndex += 1
            let name = String(format: "%@-%02d-%@.png", prefix, frameIndex, step)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name))
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
        func log(_ step: String) {
            let f = focusedElement
            guard f.exists else { return print("DIALOG \(step): nothing focused") }
            let frame = f.frame
            print("DIALOG \(step): id='\(f.identifier)' label='\(f.label.prefix(60))' "
                  + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
        }

        for (screen, which, cancelTitle) in [("detail-movie", "title", "Cancel Download"),
                                             ("detail", "season", "Cancel Season Download")] {
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamTrace", "YES",
                                   "-OpenStreamDebugDownloadOptions", which,
                                   "-openstream.settings.trailer.autoplay.v1", "NO"]
            app.launch()
            let cancel = app.buttons[cancelTitle]
            XCTAssertTrue(wait(for: cancel, 90), "the \(which) download prompt never appeared")
            Thread.sleep(forTimeInterval: 2)
            log("\(which)-open")
            shoot("\(which)-first-focused")
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.2)
            log("\(which)-down")
            shoot("\(which)-second-focused")
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 2)
            for _ in 0 ..< 8 where cancel.exists { Thread.sleep(forTimeInterval: 1) }
            log("\(which)-dismissed")
            shoot("\(which)-dismissed")
            XCTAssertFalse(cancel.exists, "Menu did not close the \(which) download prompt")
        }
    }

    // MARK: - Watched tick under the focus lift (N66)

    /// Opt-in: photographs the first episodes of the first series with the
    /// in-memory watched fixture on, focused and unfocused, so the tick on a
    /// watched still can be checked under the focus lift (N58 lost a bar on
    /// the art's edge there). Frames go to `OPENSTREAM_EPISODE_TICK_DIR`.
    /// Navigation only: nothing is selected, and the fixture writes nothing.
    func testEpisodeTickSurvivesFocus() throws {
        guard let dir = ProcessInfo.processInfo.environment["OPENSTREAM_EPISODE_TICK_DIR"] else {
            throw XCTSkip("Set OPENSTREAM_EPISODE_TICK_DIR to photograph the watched tick.")
        }
        let folder = URL(fileURLWithPath: dir)
        let seeds = (1...8).flatMap { season in (1...3).map { "\(season):\($0)" } }.joined(separator: ",")
        app.launchArguments += ["-OpenStreamVisionScreen", "detail", "-OpenStreamTrace", "YES",
                                "-OpenStreamDebugWatchedFixture", seeds,
                                "-openstream.settings.trailer.autoplay.v1", "NO"]
        app.launch()
        XCTAssertTrue(wait(for: element("detail.play"), 40), "the title page never appeared")
        let isEpisode = NSPredicate(format: "label BEGINSWITH %@", "Play S")
        XCTAssertTrue(app.descendants(matching: .any).matching(isEpisode).firstMatch.waitForExistence(timeout: 30),
                      "the episode rail never loaded")
        Thread.sleep(forTimeInterval: 4)
        func shoot(_ step: String) {
            let f = focusedElement
            let frame = f.frame
            print("TICK \(step): label='\(f.label.prefix(40))' value='\(f.value ?? "")' "
                  + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
            let screenshot = XCUIScreen.main.screenshot()
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(step).png"))
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = step
            shot.lifetime = .keepAlways
            add(shot)
        }
        shoot("01-play-focused")
        if element("detail.season").exists {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.5)
        }
        remote.press(.down)
        XCTAssertTrue(focused(where: isEpisode).waitForExistence(timeout: 10),
                      "expected an episode to hold focus, got '\(focusedElement.label)'")
        Thread.sleep(forTimeInterval: 1.5)
        shoot("02-episode1-focused")
        for step in 3...5 {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 1.5)
            shoot(String(format: "%02d-episode%d-focused", step, step - 1))
        }
    }

    // MARK: - Title page fill timing (speed item D2)

    /// Opens the title pages listed in `OPENSTREAM_FILL_IDS` (media-index record
    /// ids, comma separated) by deep link and holds each one, so the
    /// interaction trace records its `detail fill` timeline. Opt-in: skipped
    /// unless the variable is set. It never presses Play: Select is sent only
    /// while the system's "Open in OpenStream?" prompt has focus on Open.
    func testDetailFillTimingsByDeepLink() throws {
        let environment = ProcessInfo.processInfo.environment
        let ids = (environment["OPENSTREAM_FILL_IDS"] ?? "").split(separator: ",").map(String.init)
        guard !ids.isEmpty else { throw XCTSkip("Set OPENSTREAM_FILL_IDS to measure title page fill.") }
        let hold = TimeInterval(environment["OPENSTREAM_FILL_HOLD"] ?? "") ?? 20
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        app.launch()
        Thread.sleep(forTimeInterval: 14)
        let board = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        for (index, id) in ids.enumerated() {
            guard let url = URL(string: "openstream://media/\(id)?action=display") else { continue }
            app.open(url)
            if board.buttons["Open"].waitForExistence(timeout: 5) {
                let focusedOpen = board.buttons.matching(
                    NSPredicate(format: "hasFocus == true AND label == %@", "Open")
                ).firstMatch
                guard focusedOpen.waitForExistence(timeout: 3) else {
                    return XCTFail("the open prompt appeared without focus on Open")
                }
                remote.press(.select)
            }
            Thread.sleep(forTimeInterval: 3)
            let early = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            early.name = "fill-\(index + 1)-3s"
            early.lifetime = .keepAlways
            add(early)
            Thread.sleep(forTimeInterval: max(0, hold - 3))
        }
    }
    /// Local live fixture only: the runner supplies its playlist through the
    /// environment, so this test never needs an owner's provider credentials.
    func testMultiviewLayoutAndFullscreenRetainFourStreams() throws {
        guard let value = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"],
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" else {
            throw XCTSkip("Requires the local multiview fixture")
        }
        let origin = url.deletingLastPathComponent()
        app.launchArguments = ["-OpenStreamInlineLiveFixture", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamTrace", "YES", "-OpenStreamVisionPlaybackIsLive", "YES",
            "-OpenStreamVisionPlaybackURL", origin.appendingPathComponent("channel1.m3u8").absoluteString,
            "-OpenStreamMultiviewFixture", "YES", "-OpenStreamMultiviewCount", "4",
            "-OpenStreamMultiviewTemplate", origin.absoluteString + "channel{channel}.m3u8"]
        app.launch()
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview.tile.'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20))
        let ids = Set(tiles.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(ids.count, 4)
        Thread.sleep(forTimeInterval: 5)
        let layout = element("multiview.layout")
        for _ in 0..<8 where !layout.hasFocus { remote.press(.down) }
        XCTAssertTrue(layout.hasFocus)
        remote.press(.select)
        XCTAssertEqual(layout.label, "Grid")
        XCTAssertEqual(Set(tiles.allElementsBoundByIndex.map(\.identifier)), ids)
        remote.press(.select)
        XCTAssertEqual(layout.label, "1 Big + Smalls")
        remote.press(.up)
        XCTAssertTrue(tiles.allElementsBoundByIndex.contains(where: \.hasFocus))
        remote.press(.select)
        XCTAssertTrue(element("live.player.surface").waitForExistence(timeout: 10))
        remote.press(.menu)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(Set(tiles.allElementsBoundByIndex.map(\.identifier)), ids)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "four-retained-multiview-streams"
        shot.lifetime = .keepAlways
        add(shot)
        remote.press(.menu)
    }

    func testLiveZappingRecallAndMultiviewRemoteMapping() throws {
        let value = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"] ?? ""
        guard let url = URL(string: value), url.host == "127.0.0.1", url.scheme == "http" else {
            throw XCTSkip("Set OPENSTREAM_TEST_M3U to the local IPTV fixture")
        }
        app.launchArguments = ["-OpenStreamDebugLiveFixture", value,
            url.deletingLastPathComponent().appendingPathComponent("epg.xml").absoluteString,
            "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        app.launch()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        for _ in 0..<10 where !first.hasFocus { remote.press(.down) }
        XCTAssertTrue(first.hasFocus)
        remote.press(.select)
        let surface = element("live.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let firstName = try XCTUnwrap(surface.value as? String)
        Thread.sleep(forTimeInterval: 7)
        remote.press(.up)
        let changed = NSPredicate(format: "exists == true AND value != %@", firstName)
        expectation(for: changed, evaluatedWith: surface)
        waitForExpectations(timeout: 10)
        let secondName = try XCTUnwrap(surface.value as? String)
        let banner = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        banner.name = "zapping-up-banner"
        banner.lifetime = .keepAlways
        add(banner)
        Thread.sleep(forTimeInterval: 7)
        remote.press(.down)
        expectation(for: NSPredicate(format: "value == %@", firstName), evaluatedWith: surface)
        waitForExpectations(timeout: 10)
        // Both channels qualified. Select opens info; Up reaches Last Channel.
        for expected in [secondName, firstName] {
            XCTAssertTrue(surface.waitForExistence(timeout: 10))
            remote.press(.select)
            let last = element("live.player.lastChannel")
            XCTAssertTrue(last.waitForExistence(timeout: 3))
            for _ in 0..<4 where !last.hasFocus { remote.press(.up) }
            XCTAssertTrue(last.hasFocus)
            remote.press(.select)
            expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: surface)
            waitForExpectations(timeout: 10)
        }
        remote.press(.select, forDuration: 1)
        let multiview = element("live.player.multiview")
        XCTAssertTrue(multiview.waitForExistence(timeout: 5))
        let multiviewCell = app.cells.containing(.any, identifier: "live.player.multiview").firstMatch
        for _ in 0..<8 where !multiviewCell.hasFocus { remote.press(.down) }
        XCTAssertTrue(multiviewCell.hasFocus)
        remote.press(.select)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'multiview.tile.'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 20))
        let tileIDs = Set(tiles.allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(tileIDs.count, 2)
        remote.press(.down)
        remote.press(.up)
        XCTAssertEqual(Set(tiles.allElementsBoundByIndex.map(\.identifier)), tileIDs)
        XCTAssertFalse(surface.exists, "Multiview arrows must keep focus navigation instead of zapping")
        let grid = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        grid.name = "zapping-multiview-focus"
        grid.lifetime = .keepAlways
        add(grid)
        remote.press(.select)
        XCTAssertTrue(surface.waitForExistence(timeout: 10), "A tile did not enter fullscreen")
        remote.press(.menu)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Back did not restore the retained grid")
        XCTAssertEqual(Set(tiles.allElementsBoundByIndex.map(\.identifier)), tileIDs)
        remote.press(.menu)
    }

}
