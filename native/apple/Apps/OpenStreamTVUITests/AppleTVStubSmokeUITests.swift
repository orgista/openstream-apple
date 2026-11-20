import Network
import CryptoKit
import CoreImage
import XCTest

/// Launch → Discover row → title page → back on the Apple TV, with every
/// control-plane request answered from `Apps/TestPlans/Stubs`
/// (`-OpenStreamStubNetwork`): no network, no owner sources.
@MainActor
final class AppleTVStubSmokeUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { .shared }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = Self.stubbedLaunchArguments
    }

    override func tearDown() {
        app?.terminate()
    }

    func testDiscoverRowSizingScreenshots() throws {
        try launchHomeRowSettingsFixture(app, charts: true)
        attachScreen("r2-tvos-hero")
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.continue.'"), pressing: .down))
        attachScreen("r2-tvos-still-focus")
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.top10.'"), pressing: .down))
        attachScreen("r2-tvos-ranked-focus")
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.featured-movies.'"), pressing: .down))
        attachScreen("r2-tvos-featured-focus")
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.ms.'"), pressing: .down))
        attachScreen("r2-tvos-poster-focus")
        let poster = element(focusedElement.identifier)
        let captionInk = try focusedTitleInk(below: poster)
        XCTAssertGreaterThan(captionInk, 20, "The focused title must draw below the lifted artwork")
        remote.press(.right)
        attachScreen("r2-tvos-poster-title-moved")
        XCTAssertLessThan(try focusedTitleInk(below: poster), max(1, captionInk / 10))
        XCTAssertGreaterThan(try focusedTitleInk(below: focusedElement), 20)
    }

    private func focusedTitleInk(below tile: XCUIElement) throws -> Int {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let frame = tile.frame
        // Sample the caption inside the 44 pt row gap, below the stock lift.
        let region = CGRect(x: frame.minX, y: frame.maxY + 24, width: frame.width, height: 20)
            .applying(CGAffineTransform(scaleX: scale, y: scale))
        let caption = try XCTUnwrap(image.cropping(to: region))
        var pixels = [UInt8](repeating: 0, count: caption.width * caption.height * 4)
        return try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: caption.width, height: caption.height,
                bitsPerComponent: 8, bytesPerRow: caption.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(caption, in: CGRect(x: 0, y: 0, width: caption.width, height: caption.height))
            let bytes = storage.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] > 210 && bytes[$0 + 1] > 210 && bytes[$0 + 2] > 210
            }.count
        }
    }

    func testHomeRowsRememberFocusAndKeepTilesEnabled() throws {
        try launchHomeRowSettingsFixture(app)
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.featured-movies.'"), pressing: .down))
        let firstFeaturedID = focusedElement.identifier
        remote.press(.right)
        remote.press(.right)
        let featuredID = focusedElement.identifier
        XCTAssertNotEqual(featuredID, firstFeaturedID)
        remote.press(.down)
        XCTAssertTrue(focusedElement.identifier.hasPrefix("home.ms."))
        let firstPosterID = focusedElement.identifier
        for _ in 0..<4 { remote.press(.right) }
        let posterID = focusedElement.identifier
        XCTAssertNotEqual(posterID, firstPosterID)
        remote.press(.up)
        XCTAssertEqual(focusedElement.identifier, featuredID)
        remote.press(.down)
        XCTAssertEqual(focusedElement.identifier, posterID)
        let tiles = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'home.featured-movies.' OR identifier BEGINSWITH 'home.ms.'"))
        XCTAssertGreaterThan(tiles.count, 2)
        XCTAssertTrue(tiles.allElementsBoundByIndex.allSatisfy(\.isEnabled))
        attachScreen("r2-tvos-focus-restored")
        remote.press(.down)
        XCTAssertNotEqual(focusedElement.identifier, posterID)
        remote.press(.up)
        XCTAssertEqual(focusedElement.identifier, posterID)
        attachScreen("r2-tvos-poster-next-row")
        remote.press(.select)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        remote.press(.menu)
        XCTAssertTrue(element(posterID).waitForExistence(timeout: 10))
        XCTAssertEqual(focusedElement.identifier, posterID)
    }

    func testHomeRowsSettingsUsesStockTVControls() throws {
        try launchHomeRowSettingsFixture(app, screen: "settings")
        let row = element("settings.homeRows.continueWatching")
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        remote.press(.right)
        XCTAssertTrue(focus(NSPredicate(format: "label == %@", "Continue Watching, On"), pressing: .up))
        attachScreen("sizes-tvos-home-rows")
        remote.press(.select)
        XCTAssertTrue(element("settings.homeRows.show").waitForExistence(timeout: 10))
        XCTAssertTrue(focus(NSPredicate(format: "label BEGINSWITH %@", "Show on Home"), pressing: .up))
        remote.press(.select)
        XCTAssertTrue(element("settings.homeRows.name").exists)
        attachScreen("sizes-tvos-row-editor")
        remote.press(.menu)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Off") || (row.value as? String) == "Off")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var focusedElement: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    func testRapidScrubbingStockPlayerThenDifferentTitlePlays() throws {
        try exerciseRapidScrubbing(route: "native", fileExtension: "mp4", expectedRoute: "avPlayer")
    }

    func testRapidScrubbingCustomPlayerThenDifferentTitlePlays() throws {
        try exerciseRapidScrubbing(route: "surface", fileExtension: "mkv", expectedRoute: "surface")
    }

    private func exerciseRapidScrubbing(route: String, fileExtension: String,
                                       expectedRoute: String) throws {
        continueAfterFailure = true
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_SCRUB_FIXTURE_BASE"],
              let base = URL(string: raw), base.host == "127.0.0.1" else {
            throw XCTSkip("Requires scrub_seek_proof.py's loopback fixture")
        }
        let first = base.appendingPathComponent("\(route)-first.\(fileExtension)")
        let second = base.appendingPathComponent("\(route)-second.\(fileExtension)")
        app.launchArguments = ["-OpenStreamVisionScreen", "add-files",
            "-OpenStreamVisionPlaybackURL", first.absoluteString, "-OpenStreamVisionPlaybackIsLive", "NO",
            "-OpenStreamResetOnLaunch", "YES",
            "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES", "-OpenStreamScrubProbe", "YES",
            "-OpenStreamHoldPlayerChrome", "YES", "-openstream.playback.engine", "engine",
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO",
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        configureFixtureLaunch(app)
        app.launch()
        addTeardownBlock { @MainActor in
            let trace = XCTAttachment(string: ((try? self.currentOpenStreamTrace()) ?? []).joined(separator: "\n"))
            trace.name = "scrub-\(route)-trace"
            trace.lifetime = .keepAlways
            self.add(trace)
            let probe = self.element("player.scrub.proof")
            let reading = probe.exists ? (probe.value as? String ?? "empty") : "dismissed"
            let state = XCTAttachment(string: "probe=\(reading)\n\(self.app.debugDescription)")
            state.name = "scrub-\(route)-final-state"
            state.lifetime = .keepAlways
            self.add(state)
            self.attachScreen("scrub-\(route)-before-teardown")
        }
        let probe = element("player.scrub.proof")
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        let sampled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'duration='"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [sampled], timeout: 3), .completed)
        let initial = try scrubReading()
        XCTAssertEqual(initial["route"], expectedRoute)
        XCTAssertGreaterThanOrEqual(try scrubNumber("duration"), 1_800)
        let initialMediaID = try XCTUnwrap(initial["mediaID"])
        var timings = ["fixture: route=\(expectedRoute), duration=\(try scrubNumber("duration"))s, mediaID=\(initialMediaID)"]
        attachScreen("scrub-\(route)-before-input")

        func seekBurst(_ stage: String, presses: [XCUIRemote.Button], hold: XCUIRemote.Button? = nil,
                       movement: Int = 0, resumes: Bool = false) throws {
            if expectedRoute == "surface" {
                XCTAssertTrue(focus("player.scrubber", pressing: .down, limit: 4))
            }
            let before = try scrubNumber("presentationTime")
            var lastInput = ContinuousClock.now
            for button in presses {
                lastInput = .now
                remote.press(button)
            }
            if let hold {
                lastInput = .now.advanced(by: .seconds(1))
                remote.press(hold, forDuration: 1)
            }
            if resumes {
                lastInput = .now
                remote.press(.playPause)
            }
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let reading = try? self.scrubReading() else { return false }
                guard let position = reading["position"].flatMap(Double.init),
                      let rendered = reading["presentationTime"].flatMap(Double.init) else { return false }
                return reading["pending"] == "none" && reading["phase"] == "playing"
                    && reading["enginePhase"] == "playing" && abs(position - rendered) < 1
                    && (expectedRoute != "avPlayer" || reading["avRate"].flatMap(Double.init) == 1)
            }, object: nil)
            let spent = lastInput.duration(to: .now).components
            let used = Double(spent.seconds) + Double(spent.attoseconds) / 1e18
            let result = XCTWaiter.wait(for: [settled], timeout: max(0, 3 - used))
            let elapsed = lastInput.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let landed = try scrubNumber("presentationTime")
            let measurement = XCTAttachment(string: "last input to settled=\(seconds)s; \(try scrubReading())")
            measurement.name = "scrub-\(route)-\(stage)-settlement"
            measurement.lifetime = .keepAlways
            add(measurement)
            XCTAssertEqual(result, .completed,
                           "\(route) \(stage): playback did not settle within three seconds")
            if result != .completed {
                timings.append("\(stage): failed to resume in \(seconds)s")
                if expectedRoute == "avPlayer", stage == "paused-left-hold" {
                    try seekBurst(stage + "-diagnostic-select", presses: [.select])
                }
                return
            }
            if movement > 0 { XCTAssertGreaterThan(landed, before + 2, "\(stage) did not seek forward") }
            if movement < 0 { XCTAssertLessThan(landed, before - 2, "\(stage) did not seek backward") }
            if stage == "rapid-right" {
                XCTAssertGreaterThanOrEqual(landed - before, Double(presses.count) * 10 - 2,
                                            "Rapid Right presses lost an accumulated seek step")
            }
            let clockAdvances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                ((try? self.scrubNumber("presentationTime")) ?? landed) > landed + 0.25
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [clockAdvances], timeout: 3), .completed,
                           "\(route) \(stage): the playback clock froze after seeking")
            timings.append("\(stage): before=\(before)s settled=\(landed)s rendered=\(try scrubNumber("presentationTime"))s settle=\(seconds)s maxGap=\(try scrubNumber("maxGapMs"))ms")
            XCTAssertLessThanOrEqual(try scrubNumber("maxGapMs"), 250,
                                     "\(route) \(stage): the main actor missed the 250 ms budget")
        }

        try seekBurst("rapid-right", presses: Array(repeating: .right, count: 8), movement: 1)
        try seekBurst("direction-reversals", presses: [.left, .right, .left, .left, .right, .left, .right, .right])
        if expectedRoute == "avPlayer" { try verifyCommittedStockScrubHonorsPause() }
        remote.press(.playPause)
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.scrubReading()["phase"]) == "paused"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 3), .completed)
        try seekBurst("paused-left-hold", presses: [.left, .right, .left], hold: .left, movement: -1, resumes: true)
        try seekBurst("right-hold", presses: [.right, .left, .right], hold: .right,
                      movement: 1, resumes: expectedRoute == "avPlayer")
        attachScreen("scrub-\(route)-after-bursts")

        remote.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        guard focus(NSPredicate(format: "label == 'Direct URL'"), pressing: .down) else {
            XCTFail("Scrub proof harness could not focus Direct URL")
            return
        }
        remote.press(.select)
        let urlField = app.textFields.firstMatch
        guard urlField.waitForExistence(timeout: 5) else {
            XCTFail("Scrub proof harness could not open the Direct URL field")
            return
        }
        remote.press(.select)
        app.typeText(second.absoluteString)
        remote.press(.menu)
        let dialog = XCTAttachment(string: app.debugDescription)
        dialog.name = "scrub-\(route)-url-before-focus"
        dialog.lifetime = .keepAlways
        add(dialog)
        let urlAlert = app.alerts["Direct URL"].firstMatch
        let alertFocused = urlAlert.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let restoredFocus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.keyboards.count == 0 && alertFocused.exists
        }, object: nil)
        let alertReady = XCTWaiter.wait(for: [restoredFocus], timeout: 5) == .completed
        let canPlay = alertReady
            && focus(NSPredicate(format: "label == 'Cancel'"), pressing: .down, limit: 3)
            && focus(NSPredicate(format: "label == 'Play'"), pressing: .right, limit: 3)
        let focusedDialog = XCTAttachment(string: app.debugDescription)
        focusedDialog.name = "scrub-\(route)-url-after-focus"
        focusedDialog.lifetime = .keepAlways
        add(focusedDialog)
        XCTAssertTrue(canPlay, "Scrub proof harness could not restore alert focus and focus Play")
        guard canPlay else { return }
        remote.press(.select)
        guard element("player.playback.ready").waitForExistence(timeout: 45) else {
            XCTFail("A different title must play without relaunching the app")
            return
        }
        let nextSampled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'duration='"), object: probe)
        XCTAssertEqual(XCTWaiter.wait(for: [nextSampled], timeout: 3), .completed)
        let next = try scrubReading()
        XCTAssertEqual(next["route"], expectedRoute)
        XCTAssertNotEqual(next["mediaID"], initialMediaID)
        XCTAssertEqual(next["pending"], "none")
        XCTAssertEqual(next["enginePhase"], "playing")
        XCTAssertLessThan(try scrubNumber("presentationTime"), 10)
        let nextPosition = try scrubNumber("presentationTime")
        let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? self.scrubNumber("presentationTime")) ?? nextPosition) > nextPosition + 0.25
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 3), .completed)
        XCTAssertLessThanOrEqual(try scrubNumber("maxGapMs"), 250)
        timings.append("different-title: rendered \(nextPosition)s → \(try scrubNumber("presentationTime"))s, enginePhase=\(next["enginePhase"] ?? "missing")")
        let evidence = XCTAttachment(string: timings.joined(separator: "\n"))
        evidence.name = "scrub-\(route)-timings"
        evidence.lifetime = .keepAlways
        add(evidence)
        attachScreen("scrub-\(route)-different-title-playing")
    }

    private func verifyCommittedStockScrubHonorsPause() throws {
        func waitForPhase(_ phase: String) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (try? self.scrubReading()["phase"]) == phase
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 3), .completed)
        }
        remote.press(.playPause)
        waitForPhase("paused")
        remote.press(.right)
        remote.press(.select)
        waitForPhase("playing")
        remote.press(.playPause)
        waitForPhase("paused")
        let before = try currentOpenStreamTrace().filter { $0.contains(" attempt ") && $0.contains(" host=") }.count
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? self.scrubReading()["phase"]) == "playing"
        }, object: nil)
        resumed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 13), .completed,
                       "A stock scrub resumed against the viewer's pause")
        XCTAssertEqual(try scrubNumber("avRate"), 0)
        XCTAssertEqual(try currentOpenStreamTrace().filter { $0.contains(" attempt ") && $0.contains(" host=") }.count, before)
        let evidence = XCTAttachment(string: try scrubReading().description)
        evidence.name = "stock-committed-scrub-stays-paused-past-deadline"
        evidence.lifetime = .keepAlways
        add(evidence)
        remote.press(.playPause)
        waitForPhase("playing")
    }

    private func scrubReading() throws -> [String: String] {
        let value = try XCTUnwrap(element("player.scrub.proof").value as? String)
        return Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
    }

    private func scrubNumber(_ key: String) throws -> Double {
        let value = try XCTUnwrap(scrubReading()[key])
        return try XCTUnwrap(Double(value))
    }

    func testLiveKeepsOneStartupIndicatorUntilTheFrame() async throws {
        guard let base = ProcessInfo.processInfo.environment["OPENSTREAM_STARTUP_FIXTURE_BASE"], !base.isEmpty else {
            throw XCTSkip("Requires playback_startup_proof.py's local fixture")
        }
        for route in ["native", "surface"] {
            try await startupControl("reset-" + route)
            app.launchArguments = ["-OpenStreamDebugLiveFixture", base + "/startup/channels.m3u",
                base + "/startup/guide.xml", "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
                "-openstream.settings.trailer.autoplay.v1", "NO"]
            app.launch()
            XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"), pressing: .down))
            remote.press(.select)
            let indicator = app.activityIndicators["live.loading"].firstMatch
            XCTAssertTrue(indicator.waitForExistence(timeout: 5))
            let frame = indicator.frame
            captureStartup(app, route: "live-" + route, stage: "press", frame: frame)
            try await waitForStartupRequest("engine")
            for sample in 0..<3 {
                captureStartup(app, route: "live-" + route, stage: "engine-\(sample)", frame: frame)
                try await Task.sleep(for: .milliseconds(100))
            }
            try await startupControl("release-media")
            XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
            XCTAssertFalse(indicator.exists)
            captureStartup(app, route: "live-" + route, stage: "first-frame", frame: nil)
            app.terminate()
        }
    }

    func testLiveRebufferKeepsTheLastFrame() async throws {
        guard let base = ProcessInfo.processInfo.environment["OPENSTREAM_STARTUP_FIXTURE_BASE"], !base.isEmpty else {
            throw XCTSkip("Requires playback_startup_proof.py's local fixture")
        }
        try await startupControl("reset-native")
        try await startupControl("continuous-live")
        app.launchArguments = ["-OpenStreamDebugLiveFixture", base + "/startup/channels.m3u",
            base + "/startup/guide.xml", "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        app.launch()
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"), pressing: .down))
        remote.press(.select)
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
        let before = try pictureSamples()
        XCTAssertGreaterThan(try XCTUnwrap(before.max()), 120, "The fixture must show a picture before stalling")
        attachScreen("tv-live-before-rebuffer")
        try await startupControl("stall-media")
        XCTAssertTrue(app.activityIndicators["live.loading"].firstMatch.waitForExistence(timeout: 40))
        let stalled = try pictureSamples()
        attachScreen("tv-live-rebuffer-keeps-frame")
        XCTAssertGreaterThan(stalled.filter { $0 > 120 }.count, 4, "The video must stay visible behind the indicator")
        XCTAssertEqual(sampleLoadingIndicators("live-rebuffer", for: 0), 1)
        let held = try pictureSamples()
        // This fixture animates; compare two stalled frames, not an earlier playing frame.
        for (waiting, retained) in zip(stalled, held) {
            XCTAssertEqual(Double(waiting), Double(retained), accuracy: 16, "Rebuffer must retain the last frame")
        }
        try await startupControl("release-media")
    }

    private func pictureSamples() throws -> [UInt8] {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        var samples: [UInt8] = []
        for x in [0.15, 0.35, 0.65, 0.85] {
            let pixel = try XCTUnwrap(image.cropping(to: CGRect(
                x: Double(image.width) * x, y: Double(image.height) * 0.3, width: 4, height: 4)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            samples += [bytes[0], bytes[1], bytes[2]]
        }
        return samples
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
        func fixtureArtworkIsVisible() -> Bool {
            guard let snapshot = try? app.snapshot(), let image = XCUIScreen.main.screenshot().image.cgImage else { return false }
            let viewport = snapshot.frame
            var frames: [CGRect] = []
            func collectPictures(_ element: XCUIElementSnapshot) {
                if element.elementType == .button,
                   element.label.hasPrefix("Rill Movie ") || element.label.hasPrefix("Rill Show ") {
                    let frame = element.frame
                    let picture = CGRect(x: frame.minX + frame.width * 0.2, y: frame.minY + frame.height * 0.15,
                        width: frame.width * 0.6, height: frame.height * 0.5)
                    if viewport.insetBy(dx: 0, dy: 100).contains(picture) { frames.append(picture) }
                }
                for child in element.children { collectPictures(child) }
            }
            collectPictures(snapshot)
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
        for step in 0..<28 {
            let before = headings
            var currentTitles: [String: String] = [:]
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
                }
                for child in element.children { collect(child, in: id) }
            }
            collect(snapshot)
            if step == 0 || headings != before {
                if !currentTitles.isEmpty {
                    let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        fixtureArtworkIsVisible()
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed, "Fixture artwork must load before capture")
                }
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "home-rows-tvos-\(step)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            remote.press(.down)
        }
        XCTAssertEqual(headings, expected)
        XCTAssertGreaterThanOrEqual(rowIDs.count, 6)
        XCTAssertGreaterThanOrEqual(titleRows.count, 4)
        XCTAssertLessThanOrEqual(rowIDs.count + 1, 8, "Includes the hero")
        XCTAssertFalse(app.staticTexts["Top Picks for You"].exists)
        XCTAssertFalse(app.staticTexts["Recommended for You"].exists)
        let evidence = XCTAttachment(string: "Rows: \(rowIDs.sorted())\nHeadings: \(headings.sorted())\nRendered titles: \(titleRows.keys.sorted())")
        evidence.name = "home-rows-tvos-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testOneStartupIndicatorThroughResolutionAndBothEngines() async throws {
        for route in ["native", "surface"] {
            app.launchArguments = try startupFixtureArguments()
            app.launch()
            XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.' AND label == %@", "Stub Movie Five"), pressing: .down))
            remote.press(.select)
            XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
            XCTAssertTrue(focus("detail.play", pressing: .right))
            try await verifyStartupHandoff(app, route: route) { self.remote.press(.select) }
            app.terminate()
        }
    }

    func testLiveReconnectShowsOneLoadingIndicator() async throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        let (_, reset) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/reset"))
        XCTAssertEqual((reset as? HTTPURLResponse)?.statusCode, 200)
        app.launchArguments = ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", base.appendingPathComponent("reconnect/index.m3u8").absoluteString,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES",
            "-openstream.playback.engine", "native"]
        configureFixtureLaunch(app)
        app.launch()
        let stage = element("live.stage.player")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        await fulfillment(of: [playing], timeout: 45)
        let (_, stalled) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/stall"))
        XCTAssertEqual((stalled as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(element("live.reconnecting").waitForExistence(timeout: 90))
        let indicators = app.descendants(matching: .any).matching(identifier: "live.loading")
        XCTAssertEqual(indicators.count, 1, "Reconnect must have one loading indicator")
        XCTAssertEqual(indicators.firstMatch.label, "Reconnecting")
        XCTAssertEqual(sampleLoadingIndicators("live-reconnect", for: 0), 1,
                       "Reconnect must not leave an unnamed spinner visible")
        attachScreen("tv-live-reconnecting-indicator")
    }

    func testTitlePageSectionSwitchesKeepPlaybackAndEpisodes() {
        continueAfterFailure = false
        let sections = [("trailers", "Trailers"), ("cast", "Cast & Crew"),
                        ("information", "Information"), ("about", "About")]
        func launch(_ screen: String, reset: Bool) {
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamResetOnLaunch", reset ? "YES" : "NO",
                "-OpenStreamStubNetwork", Self.stubDirectory, "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
            configureFixtureLaunch(app)
            app.launch()
        }
        for (visit, enabled) in [true, false, true].enumerated() {
            launch("settings", reset: visit == 0)
            XCTAssertTrue(element("settings.section.general").waitForExistence(timeout: 30))
            remote.press(.down)
            remote.press(.left)
            XCTAssertTrue(focus("settings.section.general", pressing: .down))
            remote.press(.right)
            for (key, label) in sections {
                XCTAssertTrue(focus(NSPredicate(format: "label BEGINSWITH %@", label), pressing: .down))
                let toggle = element("settings.titlePage.\(key)")
                XCTAssertTrue(toggle.exists)
                let wanted = enabled ? "1" : "0"
                if toggle.value as? String != wanted { remote.press(.select) }
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", wanted), object: toggle)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            }
            attachScreen("tv-title-switches-\(visit)-\(enabled ? "on" : "off")")
            launch("detail", reset: false)
            XCTAssertTrue(element("detail.play").waitForExistence(timeout: 60))
            XCTAssertTrue(element("detail.play").isEnabled)
            XCTAssertTrue(element("detail.episodes").waitForExistence(timeout: 15))
            if !enabled {
                for identifier in ["detail.trailers", "detail.cast", "detail.information", "detail.about"] {
                    XCTAssertFalse(element(identifier).exists, "Disabled section \(identifier) remains visible")
                }
            }
            attachScreen("tv-title-sections-\(visit)-\(enabled ? "on" : "off")")
        }
    }

    func testDiscoverOmitsDuplicateOnlyGenreShelves() {
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(focus(Self.serverShelfItem("jf-series-10"), pressing: .down),
                      "The populated Latest Shows row must remain reachable")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "discover-deduplicated-genre-rows"
        shot.lifetime = .keepAlways
        add(shot)
        for genre in ["Comedy", "Drama"] {
            let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", genre)).allElementsBoundByIndex
            let visible = headings.filter {
                let frame = $0.frame
                return frame.width > 0 && frame.height > 0
                    && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            XCTAssertTrue(visible.isEmpty, "The duplicate-only \(genre) row left an empty heading")
        }
    }

    func testLoadingIndicatorsStaySingleThroughDiscoverDetailAndPlayback() {
        continueAfterFailure = true
        configureFixtureLaunch(app)
        app.launch()
        sampleLoadingIndicators("discover", for: 6)
        XCTAssertTrue(focus(Self.serverShelfItem("jf-movie-5"), pressing: .down), "Discover poster never took focus")
        remote.press(.select)
        sampleLoadingIndicators("detail", for: 6)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        XCTAssertTrue(focus("detail.play", pressing: .right))
        remote.press(.select)
        sampleLoadingIndicators("playback", for: 12)
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
    }

    func testLiveLoadingIndicatorsStaySingleOnTheSoftwareRoute() async throws {
        continueAfterFailure = true
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        var mediaURL = try XCTUnwrap(URL(string: base + "/media/mkv-vp9-opus.mkv"))
        if ProcessInfo.processInfo.environment["OPENSTREAM_PLAYER_DOTS_DEVICE"] == "1" {
            let fixture = try await PlayerDotsLoopbackFixture.download(from: mediaURL)
            addTeardownBlock { await fixture.stop() }
            mediaURL = try await fixture.start()
        }
        app.launchArguments = ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", mediaURL.absoluteString,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertGreaterThan(sampleLoadingIndicators("live-software", for: 30), 0,
            "The software fixture must exercise a visible loading indicator")
    }

    func testSeriesLoadingIndicatorsStaySingleWhileTheTitlePageLoads() {
        continueAfterFailure = true
        app.launchArguments += ["-OpenStreamVisionScreen", "detail"]
        configureFixtureLaunch(app)
        app.launch()
        sampleLoadingIndicators("series-detail", for: 12)
        XCTAssertTrue(element("detail.episodes").waitForExistence(timeout: 30))
    }

    func testLiveLoadingIndicatorsStaySingleOnTheAVPlayerRoute() throws {
        continueAfterFailure = true
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        app.launchArguments = ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", base + "/live/cbs.ts",
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        sampleLoadingIndicators("live-avplayer", for: 15)
    }

    func testDeviceLoadingIndicatorsStaySingleThroughDiscoverDetailAndPlayback() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSTREAM_PLAYER_DOTS_DEVICE"] == "1",
            "Requires a device run")
        continueAfterFailure = true
        app.launchArguments = ["-OpenStreamVisionScreen", "discover", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamTrace", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "OpenStream did not become foreground")
        sampleLoadingIndicators("device-discover", for: 6)
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.ms.'"), pressing: .down))
        remote.press(.select)
        sampleLoadingIndicators("device-detail", for: 6)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 45))
        if let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_PLAYER_DOTS_MEDIA_URL"] {
            app.terminate()
            app.launchArguments = ["-OpenStreamVisionScreen", "add-files",
                "-OpenStreamVisionPlaybackURL", fixture, "-OpenStreamVisionPlaybackIsLive", "NO",
                "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
            app.launch()
        } else {
            XCTAssertTrue(focus("detail.play", pressing: .right))
            remote.press(.select)
        }
        sampleLoadingIndicators("device-playback", for: 20)
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 60))
        remote.press(.menu)
    }

    @discardableResult
    private func sampleLoadingIndicators(_ phase: String, for seconds: TimeInterval) -> Int {
        let start = Date()
        var sample = 0
        var maximum = 0
        var attachedDuplicateHierarchy = false
        repeat {
            // tvOS exposes a circular ProgressView and its UIKit spinner as nested indicators.
            // On screen by frame: `isHittable` fails the test for an indicator with no activation point.
            let screen = app.frame
            let indicators = app.activityIndicators.allElementsBoundByAccessibilityElement.filter {
                guard let frame = (try? $0.snapshot())?.frame, !frame.isEmpty, screen.intersects(frame) else { return false }
                return $0.descendants(matching: .activityIndicator).count == 0
            }
            maximum = max(maximum, indicators.count)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
            shot.name = "player-dots-\(phase)-\(sample)-\(elapsed)ms-\(indicators.count)-indicators"
            shot.lifetime = .keepAlways
            add(shot)
            if indicators.count > 1, !attachedDuplicateHierarchy {
                let hierarchy = app.debugDescription.replacingOccurrences(
                    of: #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#, with: "<URL>", options: .regularExpression)
                let detail = XCTAttachment(string: hierarchy)
                detail.name = "player-dots-\(phase)-duplicate-hierarchy"
                detail.lifetime = .keepAlways
                add(detail)
                attachedDuplicateHierarchy = true
            }
            sample += 1
            let delay = start.addingTimeInterval(Double(sample) * 0.25).timeIntervalSinceNow
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        } while Date().timeIntervalSince(start) < seconds
        XCTAssertLessThanOrEqual(maximum, 1, "\(phase) showed multiple loading indicators")
        return maximum
    }

    func testServerHostedTrailerReachesPlaying() {
        app.launchArguments += ["-openstream.settings.trailer.autoplay.v1", "NO"]
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60))
        XCTAssertTrue(focus(Self.serverShelfItem("jf-movie-5"), pressing: .down), "The fixture poster never took focus")
        remote.press(.select)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        let trailer = NSPredicate(format: "identifier == 'detail.icon-row' AND label == 'Play Trailer'")
        XCTAssertTrue(app.buttons.matching(trailer).firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(focus(trailer, pressing: .right))
        remote.press(.select)
        let playing = element("trailer.player.playing")
        XCTAssertTrue(playing.waitForExistence(timeout: 30), "The server-hosted trailer clock never advanced")
        XCTAssertEqual(playing.label, "")
        XCTAssertEqual(playing.frame.size, .zero)
    }

    func testDiscoverRowOpensATitleFromStubsAndComesBack() {
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))

        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60), "Discover never took focus")
        // Stub Movie Five leads the fixture server's Latest row: Six, the newest,
        // is in Continue Watching, and Discover shows a title once.
        let posterMatch = Self.serverShelfItem("jf-movie-5")
        let poster = app.descendants(matching: .any).matching(posterMatch).firstMatch

        // Walk focus down from the hero until the poster holds it (the shelf
        // is lazy and only enters the hierarchy as focus reaches it), then open.
        let focusedPoster = app.descendants(matching: .any).matching(NSCompoundPredicate(
            andPredicateWithSubpredicates: [NSPredicate(format: "hasFocus == true"), posterMatch])).firstMatch
        for _ in 0 ..< 10 where !focusedPoster.exists {
            remote.press(.down)
            _ = focusedPoster.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(focusedPoster.exists, "focus never reached the fixture server's poster; sits on '\(focusedElement.identifier)'")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "discover-stub-movies-tv"
        shot.lifetime = .keepAlways
        add(shot)
        remote.press(.select)

        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(app.staticTexts["Stub Movie Five"].firstMatch.waitForExistence(timeout: 10))

        remote.press(.menu)
        XCTAssertTrue(poster.waitForExistence(timeout: 30), "Discover did not come back")
    }

    /// Build 20 B4: nothing under the title row took focus, so Down from Play
    /// stayed on Play and the synopsis sat below the screen. Down now lands on
    /// the synopsis and the page scrolls it into view.
    func testDownFromPlayScrollsTheSynopsisIntoView() {
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60), "Discover never took focus")
        XCTAssertTrue(focus(Self.serverShelfItem("jf-movie-5"), pressing: .down), "The fixture poster never took focus")
        remote.press(.select)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(focus("detail.play", pressing: .right))

        XCTAssertTrue(focus("detail.synopsis", pressing: .down, limit: 3),
                      "Down from Play never reached the synopsis; focus sits on '\(focusedElement.identifier)'")
        let synopsis = element("detail.synopsis")
        let screen = app.windows.firstMatch.frame
        let settled = NSPredicate { _, _ in screen.contains(synopsis.frame) }
        let onScreen = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [onScreen], timeout: 5), .completed,
                       "the synopsis took focus but stayed off screen at \(synopsis.frame)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "title-page-synopsis-focused"
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertTrue(focus("detail.play", pressing: .up, limit: 3), "Up from the synopsis did not return to Play")
    }

    /// Settings › Title Page › About off (owner 2026-10-28): the synopsis
    /// stays as the hero's short text but is no focus stop, so Down from Play
    /// skips it and lands on Cast & Crew.
    func testDownFromPlaySkipsAHiddenAboutSection() throws {
        try openStubMovieOne(turningOff: ["about"])
        XCTAssertTrue(element("detail.synopsis").exists, "About off removed the hero's synopsis")

        remote.press(.down)
        XCTAssertTrue(focusInside("detail.cast").waitForExistence(timeout: 3),
                      "Down from Play did not land on Cast & Crew; focus sits on '\(focusedElement.identifier)'")
        attachScreen("title-page-about-off-down-from-play")
    }

    /// Settings › Title Page › Cast & Crew off: the row goes, and the synopsis
    /// is the page's last focus stop.
    func testDownFromTheSynopsisStopsWithCastHidden() throws {
        try openStubMovieOne(turningOff: ["cast"])
        XCTAssertTrue(focus("detail.synopsis", pressing: .down, limit: 3),
                      "Down from Play did not reach the synopsis; focus sits on '\(focusedElement.identifier)'")
        remote.press(.down)
        XCTAssertEqual(focusedElement.identifier, "detail.synopsis",
                       "Down from the synopsis moved to '\(focusedElement.identifier)' with Cast & Crew off")
        XCTAssertFalse(element("detail.cast").exists, "Cast & Crew shows with its switch off")
        attachScreen("title-page-cast-off-last-stop")
    }

    /// The library fixture's Stub Movie One, matched to the TMDB stub that
    /// carries a cast (`api.themoviedb.org/3/movie/1.json`), with focus on
    /// Play and the given Title Page switches off. A server title has no
    /// cast and a library page has no More Like This, so Cast & Crew is the
    /// row under the synopsis.
    private func openStubMovieOne(turningOff switches: [String]) throws {
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture"] + Self.stubbedLaunchArguments
            + (try tmdbFixtureKeyLaunchArguments())
        // A plain "NO" stays a string in the argument domain and reads as unset.
        for name in switches { app.launchArguments += ["-openstream.settings.titlePage.\(name).v1", "<false/>"] }
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = Self.stubDirectory + "/library"
        app.launch()
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60), "the Library never took focus")
        XCTAssertTrue(focus("library.title.Stub Movie One", pressing: .down),
                      "the fixture title never took focus; sits on '\(focusedElement.identifier)'")
        remote.press(.select)
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(focus("detail.play", pressing: .right))
    }

    private func focusInside(_ identifier: String) -> XCUIElement {
        element(identifier).descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
    }

    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// A series page keeps the owner's 2026-09-14 order: Down from Play goes
    /// to Episodes, with no stop on the synopsis.
    func testDownFromPlayOnASeriesGoesStraightToEpisodes() {
        app.launchArguments += ["-OpenStreamVisionScreen", "detail"]
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(element("detail.episodes").waitForExistence(timeout: 30), "the series page never showed Episodes")
        XCTAssertTrue(focus("detail.play", pressing: .right))
        remote.press(.down)
        let inEpisodes = element("detail.episodes").descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(inEpisodes.waitForExistence(timeout: 3),
                      "Down from Play did not reach Episodes; focus sits on '\(focusedElement.identifier)'")
    }

    /// Moves focus one way until `identifier` holds it.
    @discardableResult
    private func focus(_ identifier: String, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        focus(NSPredicate(format: "identifier == %@", identifier), pressing: direction, limit: limit)
    }

    /// Form rows take focus as a cell that carries the row's label, not the
    /// identifier of the button inside it.
    @discardableResult
    private func focus(_ predicate: NSPredicate, pressing direction: XCUIRemote.Button, limit: Int = 12) -> Bool {
        let target = app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "hasFocus == true"), predicate])).firstMatch
        for _ in 0 ..< limit where !target.exists {
            remote.press(direction)
            _ = target.waitForExistence(timeout: 1.5)
        }
        return target.exists
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

        // The Library is lazy: Unmatched enters the hierarchy as focus reaches it.
        let tileID = "library.unmatched.Quiet Harbor Home Video"
        XCTAssertTrue(focusedElement.waitForExistence(timeout: 60), "the Library never took focus")
        // The shelf is A–Z, so focus lands on Lantern Street first.
        let firstID = "library.unmatched.Lantern Street Rehearsal"
        XCTAssertTrue(focus(firstID, pressing: .down), "focus never reached Unmatched; sits on '\(focusedElement.identifier)'")
        XCTAssertTrue(focus(tileID, pressing: .right, limit: 3))
        shot("unmatched-shelf-tv")
        remote.press(.select)

        let query = element("detail.fixMatch.query")
        XCTAssertTrue(query.waitForExistence(timeout: 10), "Match did not open")
        XCTAssertTrue(focus("detail.fixMatch.query", pressing: .up))
        remote.press(.select)
        sleep(2)
        app.typeText("Stub Movie Two")
        remote.press(.menu)
        XCTAssertTrue(focus(NSPredicate(format: "label == 'Search'"), pressing: .down), "Search never took focus")
        remote.press(.select)
        let resultID = "detail.fixMatch.result.tt0000002"
        XCTAssertTrue(element(resultID).waitForExistence(timeout: 20), "no search result")
        XCTAssertTrue(focus(NSPredicate(format: "label CONTAINS '2024'"), pressing: .down), "the result never took focus")
        shot("unmatched-match-results-tv")
        remote.press(.select)
        XCTAssertTrue(element(tileID).waitForNonExistence(timeout: 10), "the matched title stayed on the Unmatched shelf")
        shot("unmatched-after-match-tv")

        XCTAssertTrue(focus("library.title.Quiet Harbor Home Video", pressing: .up), "the matched title never took focus")
        remote.press(.select)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the title page never opened")
        XCTAssertTrue(focus("detail.play", pressing: .right))
        remote.press(.select, forDuration: 1.5)
        XCTAssertTrue(element("detail.fixMatch").waitForExistence(timeout: 5))
        XCTAssertEqual(element("detail.fixMatch").label, "Change Metadata")
        // Menu items take focus as an unlabelled cell around the item.
        let automatic = app.cells.containing(.any, identifier: "detail.automaticMatch").firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 5), "a manual match offers no way back")
        for _ in 0 ..< 6 where !automatic.hasFocus { remote.press(.down) }
        XCTAssertTrue(automatic.hasFocus, "Use Automatic Match never took focus")
        shot("unmatched-title-menu-tv")
        remote.press(.select)

        remote.press(.menu)
        // Focus may come back to any Unmatched tile, the reverted one included.
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'library.unmatched.'"), pressing: .down),
                      "Unmatched did not come back")
        XCTAssertTrue(element(tileID).hasFocus || focus(tileID, pressing: .right, limit: 3),
                      "Use Automatic Match did not return the title to Unmatched")
    }
}

private actor PlayerDotsLoopbackFixture {
    private let media: Data
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]

    private init(media: Data) { self.media = media }

    static func download(from url: URL) async throws -> PlayerDotsLoopbackFixture {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let media: Data
        let response: URLResponse
        do {
            (media, response) = try await URLSession.shared.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw Failure.downloadUnavailable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, !media.isEmpty else {
            throw Failure.invalidDownload
        }
        return PlayerDotsLoopbackFixture(media: media)
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        let port: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        if let port = listener.port {
                            continuation.resume(returning: port.rawValue)
                        } else {
                            continuation.resume(throwing: Failure.listenerUnavailable)
                        }
                    case let .failed(error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                listener.start(queue: DispatchQueue(label: "player-dots.loopback.listener"))
            }
        } onCancel: {
            listener.cancel()
        }
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/fixture.mkv"))
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        let pending = Array(requests.values)
        for request in pending { request.cancel() }
        for connection in connections.values { connection.cancel() }
        for request in pending { await request.value }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        requests[id] = Task { await serve(connection, id: id) }
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        defer { connection.cancel(); connections[id] = nil; requests[id] = nil }
        connection.start(queue: DispatchQueue(label: "player-dots.loopback.request"))
        do {
            var header = Data()
            while header.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                guard !chunk.isEmpty else { return }
                header.append(chunk)
                guard header.count <= 16_384 else { return }
            }
            let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD",
                  request[1] == "/fixture.mkv" else { return }
            let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
                .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            let range = byteRange(rangeHeader)
            let status: String
            if range == nil { status = "416 Range Not Satisfiable" }
            else if rangeHeader == nil { status = "200 OK" }
            else { status = "206 Partial Content" }
            var response = "HTTP/1.1 \(status)\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            response += "Content-Length: \(range?.count ?? 0)\r\n"
            if let range, rangeHeader != nil {
                response += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(media.count)\r\n"
            } else if range == nil {
                response += "Content-Range: bytes */\(media.count)\r\n"
            }
            var packet = Data((response + "\r\n").utf8)
            if request[0] == "GET", let range { packet.append(media.subdata(in: range)) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: packet, isComplete: true, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } catch {
            // Media probes can close a range request before consuming its body.
            return
        }
    }

    private func byteRange(_ header: String?) -> Range<Int>? {
        guard let header else { return 0..<media.count }
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, media.count - suffix)..<media.count
        }
        guard let start = Int(bounds[0]), start >= 0, start < media.count else { return nil }
        if bounds[1].isEmpty { return start..<media.count }
        guard let end = Int(bounds[1]), end >= start else { return nil }
        return start..<(min(end, media.count - 1) + 1)
    }

    private enum Failure: LocalizedError {
        case downloadUnavailable, invalidDownload, listenerUnavailable

        var errorDescription: String? {
            switch self {
            case .downloadUnavailable:
                "Device fixture download failed; check Mini LAN transport and test-runner local-network permission."
            case .invalidDownload:
                "The Mini fixture server did not return video data."
            case .listenerUnavailable:
                "The test runner could not open its loopback fixture listener."
            }
        }
    }
}


@MainActor
final class AppleTVLineupImportUITests: OpenStreamUITestCase {
    private let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")

    override func tearDown() { app.terminate() }

    func testSealedSetupReceivesTheLineupAndKeepsItAfterRelaunch() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENSTREAM_LINEUP_FILE"], !path.isEmpty else {
            throw XCTSkip("Requires the lineup setup-transfer run.")
        }
        continueAfterFailure = false
        app.launchArguments = ["-OpenStreamVisionScreen", "channels", "-OpenStreamTrace", "YES",
            "-OpenStreamMuteAudio", "YES", "-OpenStreamDebugSetupReceive", "YES"]
        app.launch()
        let qr = app.descendants(matching: .any)["setup.receive.qr"].firstMatch
        XCTAssertTrue(qr.waitForExistence(timeout: 30))
        let image = try XCTUnwrap(qr.screenshot().image.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codeImage = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }.first
        let encodedLink = try XCTUnwrap(codeImage?.messageString)
        let components = try XCTUnwrap(URLComponents(string: encodedLink))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let sessionID = try XCTUnwrap(fields["s"])
        let code = try XCTUnwrap(fields["c"])
        let receiverText = try XCTUnwrap(fields["k"])
        let receiverBytes = try XCTUnwrap(Data(base64Encoded: receiverText
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="))
        let receiver = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: receiverBytes)
        let sender = Curve25519.KeyAgreement.PrivateKey()
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let senderText = base64URL(sender.publicKey.rawRepresentation)
        let label = "openstream-setup-v1"
        let shared = try sender.sharedSecretFromKeyAgreement(with: receiver)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(label.utf8),
            sharedInfo: Data([label, sessionID, code, senderText, receiverText].joined(separator: "|").utf8), outputByteCount: 32)
        let lineup = try Data(contentsOf: URL(fileURLWithPath: path))
        let snapshot: [String: Any] = ["formatVersion": 1, "savedAt": Date.now.timeIntervalSinceReferenceDate,
            "sources": [String](), "settings": [String: String](), "playbackProgress": [String: String](),
            "watchlist": [String](), "ratings": [String: Int](),
            "lineup": lineup.base64EncodedString()]
        let secrets: [String: Any] = ["sourceCredentials": [String](), "sourceAddresses": [String](),
            "guideAddresses": [String](), "settingsCredentials": [String: String](), "privateSettings": [String: String]()]
        let payload: [String: Any] = ["v": 1, "sender": "Lineup Test", "snapshot": snapshot, "secrets": secrets]
        let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload), using: key,
            authenticating: Data((label + "|" + sessionID).utf8))
        let requestBody: [String: Any] = ["v": 1, "senderKey": senderText, "sealed": base64URL(try XCTUnwrap(box.combined))]
        let address = try XCTUnwrap(fields["h"])
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://" + address + "/setup/" + sessionID)))
        request.httpMethod = "POST"
        request.setValue(code, forHTTPHeaderField: "X-Setup-Code")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let (_, response) = try await client.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let confirm = app.buttons["setup.receive.import"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        if !confirm.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(confirm.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["setup.receive.done"].waitForExistence(timeout: 30))
        app.terminate()
        app.launchArguments = ["-OpenStreamVisionScreen", "channels", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        let name = app.staticTexts["lineup.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        XCTAssertEqual(name.label, "Complete US")
        XCTAssertFalse(app.buttons["lineup.import.file"].exists)
        XCTAssertFalse(app.textFields["lineup.url"].exists)
    }
}
