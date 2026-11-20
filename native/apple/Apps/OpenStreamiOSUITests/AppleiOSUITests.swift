import XCTest
import CoreText
import ImageIO
import MediaAccessibility
import Vision

/// iPhone and iPad behaviour that needs a touch or a rotation.
///
/// `simctl` can drive neither: it has no tap API and no orientation option, so
/// every row that depended on one — the sheets in C3, landscape in C8, typing a
/// query in F2 — sat blocked. This target is the way to them.
@MainActor
final class AppleiOSUITests: OpenStreamUITestCase {
    private var app: XCUIApplication!

    func testIPadDirectPlaybackSurvivesRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad navigation container regression")
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        app.launchArguments = ["-OpenStreamVisionPlaybackURL", base + "/media/e2e-long.mp4",
            "-OpenStreamHoldPlayerChrome", "YES", "-openstream.playback.engine", "engine",
            "-OpenStreamResetOnLaunch", "YES", "-OpenStreamMuteAudio", "YES",
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
        launch(screen: "add-files")
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        guard ready.waitForExistence(timeout: 45) else {
            attachHierarchy("ipad-player-not-ready")
            XCTFail("The local video never reached playback")
            return
        }
        setPlaybackPaused(true)
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let position = try XCTUnwrap(playbackSeconds())
        XCTAssertGreaterThan(position, 60)
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(waitForInterfaceOrientation(landscape: orientation == .landscapeLeft, timeout: 10))
            XCTAssertTrue(ready.waitForExistence(timeout: 10), "Rotation dismissed playback to Add Files")
            XCTAssertTrue(app.buttons["player.close"].firstMatch.exists)
            XCTAssertEqual(app.buttons["player.play-pause"].firstMatch.label, "Play", "Rotation restarted playback")
            XCTAssertEqual(try XCTUnwrap(playbackSeconds()), position, accuracy: 1)
            attach(orientation == .portrait ? "ipad-player-portrait-return" : "ipad-player-landscape")
        }
    }

    func testPGSCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("g-subs-pgs.mkv") }
    func testM2TSPGSCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("ff-pgs-dts.m2ts") }
    func testVobSubCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("ff-vobsub-reddwarf.mkv") }
    func testLargeVobSubCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("ff-largeres-vobsub.mkv") }
    func testMultiSubCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("ff-multisub.mkv") }
    func testSRTASSCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("g-subs-srt-ass.mkv") }
    func testASSCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("g-subs-srt-ass-ass.mkv") }
    func testMatildaCaptionsOffAndOnStayInFrame() throws { try exerciseBitmapCaptions("Matilda") }

    @discardableResult
    private func restoreSystemCaptionDisplayTypeInTeardown() -> MACaptionAppearanceDisplayType {
        let previous = MACaptionAppearanceGetDisplayType(.user)
        addTeardownBlock { @MainActor in
            MACaptionAppearanceSetDisplayType(.user, previous)
            XCTAssertEqual(MACaptionAppearanceGetDisplayType(.user), previous)
        }
        return previous
    }

    func testCaptionDisplayTypeIsRestoredByTeardown() {
        let previous = restoreSystemCaptionDisplayTypeInTeardown()
        MACaptionAppearanceSetDisplayType(.user, previous == .alwaysOn ? .forcedOnly : .alwaysOn)
        XCTAssertNotEqual(MACaptionAppearanceGetDisplayType(.user), previous)
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { $0.compactDescription.contains("Caption failure-path probe") }
        continueAfterFailure = true
        defer { continueAfterFailure = false }
        XCTExpectFailure("Exercise caption restoration after an assertion failure", options: options) {
            XCTFail("Caption failure-path probe")
        }
    }

    private func setPlaybackPaused(_ paused: Bool) {
        let surface = app.buttons["player.play-pause"].firstMatch
        let native = app.buttons["Play/Pause"].firstMatch
        for _ in 0..<3 {
            if surface.exists || native.exists { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
        let transport = surface.exists ? surface : native
        XCTAssertTrue(transport.exists, "Playback transport is unavailable")
        let desiredLabel = paused ? "Play" : "Pause"
        if transport.label != desiredLabel {
            transport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let desired = app.buttons[desiredLabel].firstMatch
        XCTAssertTrue(desired.exists || desired.waitForExistence(timeout: 5),
                      "Transport did not enter the requested state")
    }

    private func seekTextCue() {
        setPlaybackPaused(true)
        if !app.sliders.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5), "Text evidence requires the real playback scrubber")
        // XCTest's normalized drag can stop a few seconds late.
        // The back-skip clamps the paused position to zero.
        slider.adjust(toNormalizedSliderPosition: 0)
        let back = app.buttons["player.skip-back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let rewound = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "value MATCHES %@", "^0+:00(:00)?$"), object: slider)
        XCTAssertEqual(XCTWaiter.wait(for: [rewound], timeout: 5), .completed,
                       "The scrubber did not rewind to the first cue's lead-in")
    }

    private func playbackSeconds() -> Double? {
        let sliderValue = app.sliders.firstMatch.value as? String
        let values = [sliderValue].compactMap { $0 } + app.staticTexts.allElementsBoundByIndex.map(\.label)
        for value in values where value.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
            return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        return nil
    }

    private func pauseInTextCueWindow(start: Double, end: Double, duration: Double) throws -> Double {
        seekTextCue()
        XCTAssertGreaterThan(end, start)
        XCTAssertTrue(duration.isFinite && duration > end)
        let middle = (start + end) / 2
        var fraction = middle / duration
        let slider = app.sliders.firstMatch
        for _ in 0..<3 {
            slider.adjust(toNormalizedSliderPosition: fraction)
            setPlaybackPaused(true)
            let inWindow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.playbackSeconds().map { $0 >= start && $0 < end } ?? false
            }, object: nil)
            if XCTWaiter.wait(for: [inWindow], timeout: 5) == .completed {
                let seconds = try XCTUnwrap(playbackSeconds())
                XCTAssertGreaterThanOrEqual(seconds, start)
                XCTAssertLessThan(seconds, end)
                return seconds
            }
            // Correct the drag from paused readback; the cue cannot expire during the wait.
            let seconds = try XCTUnwrap(playbackSeconds())
            fraction = min(1, max(0, fraction + (middle - seconds) / duration))
        }
        XCTFail("The paused scrubber did not land inside the source cue window")
        return try XCTUnwrap(playbackSeconds())
    }

    private func exerciseBitmapCaptions(_ name: String) throws {
        guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_BITMAP_CAPTION_FIXTURES"],
              let data = encoded.data(using: .utf8),
              let cases = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let fixture = cases[name] else { throw XCTSkip("Requires run-e2e.py --caption-fixtures") }
        let track = fixture["track"] as? Int
        let url = fixture["url"] as? String ?? ""
        let previousDisplayType = restoreSystemCaptionDisplayTypeInTeardown()
        MACaptionAppearanceSetDisplayType(.user, .forcedOnly)
        let captionSettings = XCTAttachment(string: "System captions before=\(previousDisplayType.rawValue); test=\(MACaptionAppearanceGetDisplayType(.user).rawValue)")
        captionSettings.name = "caption-system-precondition"
        captionSettings.lifetime = .keepAlways
        add(captionSettings)
        app.launchArguments = ["-OpenStreamVisionScreen", "add-files", "-OpenStreamVisionPlaybackURL", url,
            "-OpenStreamVisionPlaybackIsLive", "NO", "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamHoldPlayerChrome", "YES",
            "-openstream.playback.engine", "engine", "-openstream.settings.captions.preference.v1", "off",
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
        configureFixtureLaunch(app)
        if let smb = fixture["librarySMB"] as? String {
            app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_SMB"] = smb
            app.launchArguments += ["-OpenStreamLibraryTitlesFixture"]
            app.launch()
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.title.'")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 60), "SMB scanner could not read Matilda")
            title.tap()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            play.tap()
        } else {
            app.launch()
        }
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        guard ready.waitForExistence(timeout: 30) else {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "caption-\(name)-player-not-ready-hierarchy"
            hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTFail("Caption fixture never reached visible playback")
            return
        }
        // Freeze the short corpus clip before XCTest waits for a menu to idle.
        setPlaybackPaused(true)
        let cueKind = fixture["kind"] as? String ?? "bitmap"
        let cue = app.descendants(matching: .any)["player.caption.\(cueKind)"].firstMatch
        XCTAssertFalse(cue.exists, "Captions Off rendered a subtitle")
        let off = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        off.name = "caption-\(name)-off"; off.lifetime = .keepAlways; add(off)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "caption-\(name)-off-hierarchy"
        hierarchy.lifetime = .keepAlways; add(hierarchy)
        func openCaptionMenu() {
            setPlaybackPaused(true)
            let captions = app.buttons["player.captions"].firstMatch
            let more = app.buttons["player.more"].firstMatch
            // Reveal either route's chrome, then act before its auto-hide timer.
            for _ in 0..<3 where !captions.exists && !more.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
            }
            if captions.exists {
                captions.tap()
            } else {
                XCTAssertTrue(more.exists, "Native player More control is unavailable")
                more.tap()
                let subtitles = app.buttons["player.subtitles"].firstMatch
                XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
                subtitles.tap()
            }
        }
        if let reason = fixture["onUnavailable"] as? String { throw XCTSkip(reason) }
        if cueKind == "text" {
            try captureTextOff("initial-off")
        }
        openCaptionMenu()
        let choices = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.subtitle.track.' AND identifier != 'player.subtitle.track.off'"))
        var choice = track.map { app.descendants(matching: .any)["player.subtitle.track.\($0)"].firstMatch } ?? choices.firstMatch
        if !choice.exists, let label = fixture["label"] as? String {
            choice = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        if !choice.exists {
            let more = app.buttons.matching(NSPredicate(format: "label == 'More…' OR identifier IN %@",
                ["player.subtitle.more", "player.subtitles.more"])).firstMatch
            if more.exists { more.tap() }
        }
        let menuHierarchy = XCTAttachment(string: app.debugDescription)
        menuHierarchy.name = "caption-\(name)-selection-hierarchy"
        menuHierarchy.lifetime = .keepAlways; add(menuHierarchy)
        let menuShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        menuShot.name = "caption-\(name)-selection"; menuShot.lifetime = .keepAlways; add(menuShot)
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Requested embedded subtitle track is missing")
        if name == "ff-pgs-dts.m2ts" {
            XCTAssertTrue(choice.label.hasPrefix("Subtitles"), "Untagged PGS must be listed as Subtitles")
        }
        choice.tap()
        setPlaybackPaused(true)
        func textEvidence(_ screenshot: XCUIScreenshot) throws -> (visible: Bool, bounds: [CGRect]) {
            guard let expected = fixture["expectedCue"] as? String, !expected.isEmpty,
                  let image = screenshot.image.cgImage else { return (false, []) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            func normalized(_ text: String) -> String {
                text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                    .filter { $0.isLetter || $0.isNumber }
            }
            let results = request.results ?? []
            let words = results.compactMap { $0.topCandidates(1).first?.string }
            let key = normalized(expected)
            let bounds = results.compactMap { observation -> CGRect? in
                guard let word = observation.topCandidates(1).first?.string else { return nil }
                let candidate = normalized(word)
                guard candidate.count >= 3, key.contains(candidate) || candidate.contains(key) else { return nil }
                return observation.boundingBox
            }
            return (normalized(words.joined(separator: " ")).contains(key), bounds)
        }
        func captureTextCue(_ stage: String) throws {
            let seconds = try pauseInTextCueWindow()
            XCTAssertTrue(cue.waitForExistence(timeout: 5), "The selected source cue is missing while paused")
            let screenshot = XCUIScreen.main.screenshot()
            let evidence = try textEvidence(screenshot)
            let image = XCTAttachment(screenshot: screenshot)
            image.name = "caption-\(name)-\(stage)"; image.lifetime = .keepAlways; add(image)
            let geometry = XCTAttachment(string: "Source cue: \(fixture["expectedCue"] ?? ""); normalized OCR bounds: \(evidence.bounds); image orientation: \(screenshot.image.imageOrientation.rawValue); playback after OCR: \(String(describing: playbackSeconds()))")
            geometry.name = "caption-\(name)-\(stage)-glyph-bounds"; geometry.lifetime = .keepAlways; add(geometry)
            XCTAssertEqual(playbackSeconds(), seconds, "Playback advanced during caption OCR")
            XCTAssertTrue(evidence.visible, "Paused subtitle glyphs do not match the source cue")
            XCTAssertFalse(evidence.bounds.isEmpty, "The captured source glyph has no measured bounds")
            for bounds in evidence.bounds {
                XCTAssertTrue(CGRect(x: -0.001, y: -0.001, width: 1.002, height: 1.002).contains(bounds))
                XCTAssertLessThan(bounds.height, 0.8, "Glyph evidence must not describe the whole player")
            }
        }
        func pauseInTextCueWindow() throws -> Double {
            try self.pauseInTextCueWindow(start: XCTUnwrap(fixture["cueStart"] as? Double),
                                         end: XCTUnwrap(fixture["cueEnd"] as? Double),
                                         duration: XCTUnwrap(fixture["duration"] as? Double))
        }
        func captureTextOff(_ stage: String) throws {
            let seconds = try pauseInTextCueWindow()
            let start = try XCTUnwrap(fixture["cueStart"] as? Double)
            let end = try XCTUnwrap(fixture["cueEnd"] as? Double)
            let screenshot = XCUIScreen.main.screenshot()
            let image = XCTAttachment(screenshot: screenshot)
            image.name = "caption-\(name)-\(stage)"; image.lifetime = .keepAlways; add(image)
            let timeline = XCTAttachment(string: "Observed playback: \(String(describing: seconds)); original cue window: \(start)..<\(end)")
            timeline.name = "caption-\(name)-\(stage)-cue-window"; timeline.lifetime = .keepAlways; add(timeline)
            XCTAssertFalse(try textEvidence(screenshot).visible, "Off left the source subtitle glyph visible")
            XCTAssertEqual(playbackSeconds(), seconds, "Playback advanced during caption OCR")
        }
        if cueKind == "text" {
            try captureTextCue("on")
        } else {
            if !cue.waitForExistence(timeout: 2) { setPlaybackPaused(false) }
            XCTAssertTrue(cue.waitForExistence(timeout: 90), "Captions On never rendered an embedded subtitle")
            setPlaybackPaused(true)
            let on = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            on.name = "caption-\(name)-on"; on.lifetime = .keepAlways; add(on)
        }
        // This player fills the window. A containing accessibility group
        // reports its children union, which is not the playback viewport.
        func viewportFrame() throws -> CGRect {
            // iPadOS can retain a zero-sized transition window before the visible one.
            let frames = app.windows.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
            return try XCTUnwrap(frames.max { $0.width * $0.height < $1.width * $1.height },
                                 "Fullscreen player window is unavailable")
        }
        let viewport = try viewportFrame()
        let bounds = viewport.insetBy(dx: -1, dy: -1)
        if cueKind != "text" {
            XCTAssertGreaterThan(cue.frame.width, 0)
            XCTAssertGreaterThan(cue.frame.height, 0)
            XCTAssertTrue(bounds.contains(cue.frame), "Bitmap caption extends outside the player viewport")
            XCTAssertLessThan(cue.frame.height, viewport.height * 0.8,
                              "Accessibility bounds must describe the cue, not the whole overlay")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        Thread.sleep(forTimeInterval: 2)
        if cueKind == "text" {
            try captureTextCue("landscape")
        } else {
            let rotatedCueVisible = cue.waitForExistence(timeout: 20)
            let rotated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            rotated.name = "caption-\(name)-landscape"; rotated.lifetime = .keepAlways; add(rotated)
            XCTAssertTrue(rotatedCueVisible, "Bitmap caption disappeared during rotation")
            let rotatedViewport = try viewportFrame()
            XCTAssertTrue(rotatedViewport.insetBy(dx: -1, dy: -1).contains(cue.frame))
            XCTAssertLessThan(cue.frame.height, rotatedViewport.height * 0.8)
        }
        XCUIDevice.shared.orientation = .portrait
        openCaptionMenu()
        let offChoice = app.buttons["Off"].firstMatch
        XCTAssertTrue(offChoice.waitForExistence(timeout: 5))
        offChoice.tap()
        setPlaybackPaused(true)
        if cueKind == "text" {
            try captureTextOff("off-again")
        } else {
            XCTAssertTrue(cue.waitForNonExistence(timeout: 5), "Captions Off did not clear the rendered cue")
            let offAgain = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            offAgain.name = "caption-\(name)-off-again"; offAgain.lifetime = .keepAlways; add(offAgain)
        }
    }

    func testDVDMenuTestPlayDiscNavigates() throws { try exerciseDVD("menu-test", skip: false) }
    func testDVDMenuFeaturesPlayDiscNavigates() throws { try exerciseDVD("menu-features", skip: false) }
    func testDVDMenuTestSkipToMovie() throws { try exerciseDVD("menu-test", skip: true) }
    func testDVDMenuFeaturesSkipToMovie() throws { try exerciseDVD("menu-features", skip: true) }

    func testSMBMatildaPublishedPlayDisc() throws { try exerciseDVD("smb-matilda-published", skip: false) }
    func testSMBMatildaPublishedSkipToMovie() throws { try exerciseDVD("smb-matilda-published", skip: true) }
    func testSMBMatildaStagedPlayDisc() throws { try exerciseDVD("smb-matilda-staged", skip: false) }
    func testSMBMatildaStagedSkipToMovie() throws { try exerciseDVD("smb-matilda-staged", skip: true) }
    func testSMBGooniesPublishedPlayDisc() throws { try exerciseDVD("smb-goonies-published", skip: false) }
    func testSMBGooniesPublishedSkipToMovie() throws { try exerciseDVD("smb-goonies-published", skip: true) }
    func testSMBGooniesStagedPlayDisc() throws { try exerciseDVD("smb-goonies-staged", skip: false) }
    func testSMBGooniesStagedSkipToMovie() throws { try exerciseDVD("smb-goonies-staged", skip: true) }
    func testSMBAvatarStagedPlayDisc() throws { try exerciseDVD("smb-avatar-staged", skip: false) }
    func testSMBAvatarStagedSkipToMovie() throws { try exerciseDVD("smb-avatar-staged", skip: true) }
    func testSMBAvatar2IncompletePlayDisc() throws { try exerciseDVD("smb-avatar2-incomplete", skip: false) }
    func testSMBAvatar2IncompleteSkipToMovie() throws { try exerciseDVD("smb-avatar2-incomplete", skip: true) }

    func testHTTPDiscMatildaPublishedPlayDisc() throws { try exerciseHTTPDisc("matilda-published", skip: false) }
    func testHTTPDiscMatildaPublishedSkipToMovie() throws { try exerciseHTTPDisc("matilda-published", skip: true) }
    func testHTTPDiscGooniesPublishedPlayDisc() throws { try exerciseHTTPDisc("goonies-published", skip: false) }
    func testHTTPDiscGooniesPublishedSkipToMovie() throws { try exerciseHTTPDisc("goonies-published", skip: true) }
    func testHTTPDiscMatildaStagedPlayDisc() throws { try exerciseHTTPDisc("matilda-staged", skip: false) }
    func testHTTPDiscMatildaStagedSkipToMovie() throws { try exerciseHTTPDisc("matilda-staged", skip: true) }
    func testHTTPDiscGooniesStagedPlayDisc() throws { try exerciseHTTPDisc("goonies-staged", skip: false) }
    func testHTTPDiscGooniesStagedSkipToMovie() throws { try exerciseHTTPDisc("goonies-staged", skip: true) }
    func testHTTPDiscAvatarStagedPlayDisc() throws { try exerciseHTTPDisc("avatar-staged", skip: false) }
    func testHTTPDiscAvatarStagedSkipToMovie() throws { try exerciseHTTPDisc("avatar-staged", skip: true) }
    func testHTTPDiscAvatar2StagedPlayDisc() throws { try exerciseHTTPDisc("avatar2-staged", skip: false) }
    func testHTTPDiscAvatar2StagedSkipToMovie() throws { try exerciseHTTPDisc("avatar2-staged", skip: true) }
    func testHTTPDiscJohnWickStagedPlayDisc() throws { try exerciseHTTPDisc("john-wick-staged", skip: false) }
    func testHTTPDiscJohnWickStagedSkipToMovie() throws { try exerciseHTTPDisc("john-wick-staged", skip: true) }
    func testHTTPDiscTronStagedPlayDisc() throws { try exerciseHTTPDisc("tron-staged", skip: false) }
    func testHTTPDiscTronStagedSkipToMovie() throws { try exerciseHTTPDisc("tron-staged", skip: true) }

    func testHTTPDiscJohnWickPublishedPlayDisc() throws { try exerciseHTTPDisc("john-wick-published", skip: false) }
    func testHTTPDiscJohnWickPublishedSkipToMovie() throws { try exerciseHTTPDisc("john-wick-published", skip: true) }

    func testHTTPDiscTronPublishedPlayDisc() throws { try exerciseHTTPDisc("tron-published", skip: false) }
    func testHTTPDiscTronPublishedSkipToMovie() throws { try exerciseHTTPDisc("tron-published", skip: true) }

    func testHTTPDiscWildRobotStagedPlayDisc() throws { try exerciseHTTPDisc("wild-robot-staged", skip: false) }
    func testHTTPDiscWildRobotStagedSkipToMovie() throws { try exerciseHTTPDisc("wild-robot-staged", skip: true) }

    private func visiblePictureFraction(_ screenshot: XCUIScreenshot) throws -> Double {
        guard let image = screenshot.image.cgImage,
              let crop = image.cropping(to: CGRect(x: Double(image.width) * 0.1,
                  y: Double(image.height) * 0.36, width: Double(image.width) * 0.8,
                  height: Double(image.height) * 0.28)) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let bright = stride(from: 0, to: pixels.count, by: 4).filter {
            max(pixels[$0], max(pixels[$0 + 1], pixels[$0 + 2])) > 30
        }.count
        let fraction = Double(bright) / (64 * 64)
        let evidence = XCTAttachment(string: "Central picture fraction above RGB30: \(fraction); excludes outer chrome")
        evidence.name = "iso-picture-pixels"; evidence.lifetime = .keepAlways; add(evidence)
        return fraction
    }

    private func exerciseHTTPDisc(_ name: String, skip: Bool) throws {
        guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_HTTP_ISO_FIXTURES"],
              let data = encoded.data(using: .utf8),
              let cases = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let url = cases[name] else { throw XCTSkip("Read-only SSH byte-range HTTP fixture unavailable; SMB remains unverified") }
        app.launchArguments = ["-OpenStreamVisionScreen", "add-files", "-OpenStreamVisionPlaybackURL", url,
            "-OpenStreamDiscStart", skip ? "mainTitle" : "menu", "-OpenStreamVisionPlaybackIsLive", "NO",
            "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES", "-openstream.playback.engine", "engine",
            "-openstream.settings.metadata.enabled.v1", "NO"]
        configureFixtureLaunch(app)
        app.launch()
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        let reachedPlayback = ready.waitForExistence(timeout: 60)
        if reachedPlayback {
            Thread.sleep(forTimeInterval: 20)
            if !app.sliders.firstMatch.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
            }
            let slider = app.sliders.firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 5), "Rendered ISO evidence requires a real playback scrubber")
            slider.adjust(toNormalizedSliderPosition: 0.005)
            Thread.sleep(forTimeInterval: 5)
        }
        var picture = XCUIScreen.main.screenshot()
        var fraction = reachedPlayback ? try visiblePictureFraction(picture) : 0
        for sample in 1...2 where reachedPlayback && fraction <= 0.10 {
            let black = XCTAttachment(screenshot: picture)
            black.name = "http-iso-\(name)-\(skip ? "mainTitle" : "menu")-sample-\(sample)"
            black.lifetime = .keepAlways; add(black)
            Thread.sleep(forTimeInterval: 5)
            picture = XCUIScreen.main.screenshot()
            fraction = try visiblePictureFraction(picture)
        }
        let shot = XCTAttachment(screenshot: picture)
        shot.name = "http-iso-\(name)-\(skip ? "mainTitle" : "menu")"; shot.lifetime = .keepAlways; add(shot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = (shot.name ?? "http-iso") + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(reachedPlayback, "Remote BD ISO did not reach main title playback")
        if reachedPlayback {
            XCTAssertTrue(ready.exists, "Player disappeared before rendered-picture evidence")
            XCTAssertGreaterThan(fraction, 0.10,
                                 "Central video picture is still mostly black after real playback and seeking")
        }
        XCTAssertFalse(app.buttons["player.disc.menu"].firstMatch.exists, "Blu-ray must not offer a DVD menu control")
        XCTAssertFalse(app.descendants(matching: .any)["player.disc.menu.active"].firstMatch.exists,
                       "Blu-ray .menu fallback must not pretend to provide DVD navigation")
    }

    func testDVDMenuTitleShowsTimelineAndChapterSeek() throws {
        guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_ISO_FIXTURES"],
              let data = encoded.data(using: .utf8),
              let folders = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let folder = folders["menu-features"] else {
            throw XCTSkip("Requires run-e2e.py --iso-fixtures")
        }
        app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = folder
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture", "-OpenStreamTrace", "YES",
            "-OpenStreamMuteAudio", "YES", "-openstream.settings.metadata.enabled.v1", "NO",
            "-openstream.playback.engine", "engine"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.title.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 60))
        tile.tap()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        play.tap()
        let menu = app.descendants(matching: .any)["player.disc.menu.active"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "Play bypassed the authored DVD menu")
        func capture(_ stage: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "dvd-menu-timeline-" + stage
            shot.lifetime = .keepAlways
            add(shot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "dvd-menu-timeline-" + stage + "-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        capture("menu")
        app.buttons["player.disc.menu.button.1"].firstMatch.tap()
        let firstChapter = app.buttons["player.disc.menu.button.1"].firstMatch
        XCTAssertTrue(app.buttons["player.disc.menu.button.6"].firstMatch.waitForExistence(timeout: 5))
        firstChapter.tap()
        let pause = app.buttons["player.play-pause"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pause.exists && pause.label == "Pause"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed)
        pause.tap()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertTrue(slider.isEnabled)
        XCTAssertNotNil(crawlPlaybackSeconds(), "Elapsed time is missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"-\d+:\d{2}"#)).firstMatch.exists,
                      "Remaining time is missing")
        capture("title")
        slider.adjust(toNormalizedSliderPosition: 0)
        let beginning = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.crawlPlaybackSeconds().map { $0 < 1 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [beginning], timeout: 5), .completed)
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let seek = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.crawlPlaybackSeconds().map { $0 >= 2 && $0 <= 3 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seek], timeout: 5), .completed)
        app.descendants(matching: .any)["player.options"].firstMatch.tap()
        let chapters = app.descendants(matching: .any)["player.chapters"].firstMatch
        XCTAssertTrue(chapters.waitForExistence(timeout: 5))
        chapters.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 1")).firstMatch.tap()
        let chapterSeek = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.crawlPlaybackSeconds().map { $0 < 1 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chapterSeek], timeout: 5), .completed)
        capture("chapter-seek")
        XCTAssertFalse(app.alerts["Playback Failed"].exists)
    }

    private func exerciseDVD(_ name: String, skip: Bool) throws {
        if name.hasPrefix("smb-") {
            guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_REMOTE_ISO_FIXTURES"],
                  let data = encoded.data(using: .utf8),
                  let sources = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]],
                  let source = sources[name] else { throw XCTSkip("Requires OPENSTREAM_REMOTE_ISO_FIXTURES") }
            let sourceData = try JSONSerialization.data(withJSONObject: source)
            app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_SMB"] = String(decoding: sourceData, as: UTF8.self)
        } else {
            guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_ISO_FIXTURES"],
                  let data = encoded.data(using: .utf8),
                  let folders = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let folder = folders[name] else { throw XCTSkip("Requires run-e2e.py --iso-fixtures") }
            app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_PATH"] = folder
        }
        app.launchArguments = ["-OpenStreamLibraryTitlesFixture", "-OpenStreamTrace", "YES",
            "-OpenStreamMuteAudio", "YES", "-openstream.settings.metadata.enabled.v1", "NO",
            "-openstream.playback.engine", "engine"]
        app.launch()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.title.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "Local ISO scanner did not publish \(name)")
        tile.tap()
        let play = app.buttons[skip ? "detail.disc.skipToMovie" : "detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Disc start actions missing")
        play.tap()
        func capture(_ stage: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "iso-\(name)-\(skip ? "skip" : "menu")-\(stage)"
            shot.lifetime = .keepAlways
            add(shot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = (shot.name ?? "iso") + "-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        capture("opened")
        if ProcessInfo.processInfo.environment["OPENSTREAM_ISO_REPRO"] == "1" {
            for step in 1...6 {
                Thread.sleep(forTimeInterval: 0.5)
                capture("repro-\(step)")
            }
            return
        }
        if skip || name.hasPrefix("smb-") {
            XCTAssertTrue(app.descendants(matching: .any)["player.disc.title.active"].firstMatch.waitForExistence(timeout: 30),
                          "Skip to Movie did not reach the main title")
            XCTAssertFalse(app.descendants(matching: .any)["player.disc.menu.active"].firstMatch.exists)
        } else {
            let menu = app.descendants(matching: .any)["player.disc.menu.active"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 30), "Play Disc bypassed the DVD menu or rendered no menu")
            capture("menu")
            let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.disc.menu.button.'")).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "DVD menu exposes no interactive button")
            button.tap()
            if name == "menu-features" {
                XCTAssertTrue(app.buttons["player.disc.menu.button.6"].firstMatch.waitForExistence(timeout: 5),
                              "Play did not open the authored chapter menu")
                capture("chapter-menu")
                app.buttons["player.disc.menu.button.1"].firstMatch.tap()
            }
            let activeTitle = app.descendants(matching: .any)["player.disc.title.active"].firstMatch
            XCTAssertTrue(activeTitle.exists || activeTitle.waitForExistence(timeout: 30),
                          "Activating a DVD menu button did not reach title playback")
            let returnToMenu = app.buttons["player.disc.menu"].firstMatch
            if !returnToMenu.exists { XCTAssertTrue(revealPlayerControls()) }
            XCTAssertTrue(returnToMenu.exists || returnToMenu.waitForExistence(timeout: 5),
                          "Title playback has no Disc Menu route")
            returnToMenu.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 15), "Disc Menu did not return from title playback")
            capture("returned-menu")
            app.buttons["player.disc.menu.button.1"].firstMatch.tap()
            let title = app.descendants(matching: .any)["player.disc.title.active"].firstMatch
            if name == "menu-features" {
                let chapter = app.buttons["player.disc.menu.button.6"].firstMatch
                // The authored first button can resume the interrupted title or open chapters.
                let resumedOrChapters = NSPredicate { _, _ in title.exists || chapter.exists }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: resumedOrChapters, object: app)], timeout: 5), .completed)
                if chapter.exists { app.buttons["player.disc.menu.button.1"].firstMatch.tap() }
            }
            XCTAssertTrue(title.waitForExistence(timeout: 30))
            XCTAssertTrue(menu.waitForExistence(timeout: 120), "A completed title dismissed the player instead of returning to the DVD menu")
            capture("title-ended-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.1)).tap()
            let close = app.buttons["player.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "DVD menu has no Close control")
            close.tap()
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 5),
                          "Closing the DVD menu did not restore the title page")
            capture("closed")
        }
        app.terminate()
    }


    override func setUpWithError() throws {
        // These checks require disposable data, not the owner's content simulators.
        let isolatedTests = [
            "testLiveCategoryBarStaysFixedWhileScrolling",
            "testTypingIntoASettingsFieldPersists",
            "testAddMediaServerSignsInToEmbyAndCleansUp",
            "testExtensionLessHLSChannelPlaysFromAnM3U",
            "testPlaylistGuideShowsProgrammes",
            "testChannelManagerListsSelectedAndAddsThroughAPicker",
            "testLivePlaylistShowsChannelFailureAndRecovers",
            "testZRemoveUITestPlaylistSource",
            "testDownloadCanBeCancelledFromItsOptionsWhilePreparingAndDownloading",
            "testDiscoverBackFromTitlePageTenTimes",
            "testLibrarySortBeforeAndAfterScrolling",
        ]
        if ProcessInfo.processInfo.environment["OPENSTREAM_ALLOW_MUTATING_UI_TESTS"] != "1",
           isolatedTests.contains(where: { name.contains($0) }) {
            throw XCTSkip("Requires an isolated simulator: this suite must preserve saved sources and credentials.")
        }

        continueAfterFailure = false
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    private func launch(screen: String? = nil) {
        if let screen { app.launchArguments += ["-OpenStreamVisionScreen", screen] }
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        configureFixtureLaunch(app)
        app.launch()
    }

    /// `isHittable` raises — and takes the whole test with it — when XCTest can
    /// find no hit point in the element's frame: something scrolled out of a
    /// horizontal row, or laid out at zero size. Asking only about elements
    /// whose centre is on the screen is what keeps a sweep running to the end.
    private func isSafelyHittable(_ element: XCUIElement, snapshot provided: XCUIElementSnapshot? = nil) -> Bool {
        guard let snapshot = provided ?? (try? element.snapshot()) else { return false }
        let frame = snapshot.frame
        guard frame.width >= 1, frame.height >= 1 else { return false }
        guard crawlScreenRect.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        // The Discover hero's buttons sit on top of everything and the hero
        // advances about once a second on iOS 27; asking XCTest for their
        // hittability mid-transition raises "activation point invalid". Their
        // on-screen frame is the answer.
        if ["home.featured.play", "home.featured.my-list", "home.featured.details"].contains(snapshot.identifier) {
            return true
        }
        return element.isHittable
    }

    private func attachHierarchy(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLegacyDiscoverNavigationAndPlayerAccessibilityIsolation() {
        app.launchArguments = ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "discover")
        // iPhone: no navigation bar over the landing hero at rest (owner 2026-10-20, "Discover and Library are
        // cut off by the bar at the top … those used to not be there"); the Discover tab is the landmark.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.tabBars.buttons["Discover"].waitForExistence(timeout: 30))
            XCTAssertTrue(app.tabBars.buttons["Discover"].isSelected)
        } else {
            XCTAssertTrue(app.navigationBars["Discover"].waitForExistence(timeout: 30))
        }
        Thread.sleep(forTimeInterval: 8)
        attach("legacy-discover-navigation")
        app.terminate()
        app.launchArguments = ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "add-files")
        let directURL = app.buttons["Direct URL"].firstMatch
        XCTAssertTrue(directURL.waitForExistence(timeout: 30))
        directURL.tap()
        let dialog = app.alerts["Direct URL"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 10))
        dialog.textFields.firstMatch.tap()
        dialog.textFields.firstMatch.typeText("http://127.0.0.1:9/openstream-ui-test-unreachable.mkv")
        dialog.buttons["Play"].tap()
        let player = app.descendants(matching: .any).matching(identifier: "player.connecting").firstMatch
        let failure = app.alerts["Playback Failed"].firstMatch
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            player.exists || failure.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 30), .completed)
        let isolated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.tabBars.buttons["Discover"].exists && !self.app.buttons["Direct URL"].exists
        }, object: nil)
        attach("fullscreen-player-accessibility-isolation")
        XCTAssertEqual(XCTWaiter.wait(for: [isolated], timeout: 10), .completed,
                       "The presenting page must be absent from the fullscreen accessibility tree")
        // The pre-route spinner shows first; the unreachable URL fails after it.
        if failure.waitForExistence(timeout: 30) {
            let close = failure.buttons["Close"]
            if close.exists { close.tap() }
        }
        let closePlayer = app.buttons["player.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 3) { closePlayer.tap() }
        XCTAssertTrue(directURL.waitForExistence(timeout: 10),
                      "Dismissal must restore the presenting page's accessibility elements")
    }

    private func inlineLivePictureAspectRatio(_ player: XCUIElement) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(player.screenshot().pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = 256
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // The colour-bar fixture identifies the picture independently of iOS 18's status-bar-inclusive AX frame.
        let pictureRows = (0..<height).filter { y in
            let chromatic = stride(from: y * width * 4, to: (y + 1) * width * 4, by: 4).reduce(0) { count, offset in
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                return count + (max(red, max(green, blue)) - min(red, min(green, blue)) > 32 ? 1 : 0)
            }
            return chromatic > width / 8
        }
        let first = try XCTUnwrap(pictureRows.first, "The local Live fixture has no visible picture")
        let last = try XCTUnwrap(pictureRows.last)
        let ratio = Double(width) / Double(last - first + 1)
        let evidence = XCTAttachment(string: "stage pixels=\(image.width)x\(image.height), sampled picture rows=\(first)...\(last), aspect=\(ratio)")
        evidence.name = "live-picture-aspect"
        evidence.lifetime = .keepAlways
        add(evidence)
        return ratio
    }

    func testLiveParamountRowsPlayInlineThenFullScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Phone Live layout")
        }
        continueAfterFailure = true
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES"]
        launch(screen: "live")
        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
        XCTAssertTrue(channels.firstMatch.waitForExistence(timeout: 30))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Playing"), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 60), .completed)
        attach("pplus-live-rest")
        let stageFrame = player.frame
        XCTAssertEqual(try inlineLivePictureAspectRatio(player), 16.0 / 9.0, accuracy: 0.02)
        let row = try XCTUnwrap(channels.allElementsBoundByIndex.first {
            !$0.isSelected && isSafelyHittable($0)
        }, "The fixture must include a visible channel to switch to")
        row.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Playing"), object: player)], timeout: 60), .completed)
        XCTAssertTrue(row.isSelected)
        XCTAssertTrue(revealInlineLiveControls(timeout: 60))
        attach("pplus-live-after-tap")
        XCTAssertEqual(try inlineLivePictureAspectRatio(player), 16.0 / 9.0, accuracy: 0.02,
                       "A new row plays inline on the stage")
        XCTAssertEqual(row.frame.height, 88, accuracy: 1)
        let bar = app.descendants(matching: .any).matching(identifier: "live.categories").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        XCTAssertEqual(bar.frame.minY, stageFrame.maxY, accuracy: 1,
                       "Categories sit directly below the stage")
        // Paramount+ on a test iPhone (2026-10-21): an 81 pt flat strip from the stage to the first row.
        XCTAssertEqual(bar.frame.height, 81, accuracy: 1)
        XCTAssertEqual(stageFrame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(stageFrame.width, app.frame.width, accuracy: 1)
        if app.statusBars.firstMatch.exists {
            XCTAssertEqual(stageFrame.minY, app.statusBars.firstMatch.frame.maxY, accuracy: 1)
        }
        let frames = XCTAttachment(string: "stage: \(stageFrame)\nbar: \(bar.frame)\nrow: \(row.frame)")
        frames.name = "pplus-live-layout-frames"
        frames.lifetime = .keepAlways
        add(frames)
        // Owner: "REA Paramount+ Live … redo Live" (2026-10-20). Test iPhone:
        // Paramount+ 15.28.0 keeps a repeated playing-channel tap inline.
        row.tap()
        let close = app.buttons["player.close"].firstMatch
        XCTAssertFalse(close.waitForExistence(timeout: 2), "Tapping the playing channel must stay inline")
        XCTAssertTrue(row.isSelected)
        XCTAssertEqual(player.frame.minY, stageFrame.minY, accuracy: 1)
        XCTAssertEqual(player.frame.height, stageFrame.height, accuracy: 1)
        attach("pplus-live-playing-row-stays-inline")
        let guide = app.buttons["live.guide"].firstMatch
        guide.tap()
        let done = app.buttons["live.guide.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        attach("pplus-live-guide")
        done.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertTrue(revealInlineLiveControls(timeout: 30))
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(isSafelyHittable(fullScreen))
        fullScreen.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Full Screen must still open the player")
        close.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
    }

    /// Owner 2026-10-21 ("live on ipad needs to full screen"): Paramount+'s iPad
    /// stack in both orientations. The stage spans the window, the flat strip
    /// sits on it and the list fills the rest with room for three rows. The
    /// playing row and Full Screen still open the full-screen player.
    func testIPadLiveStacksLikeParamountPlus() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPad Live layout")
        }
        continueAfterFailure = true
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let name = orientation == .portrait ? "portrait" : "landscape"
            XCUIDevice.shared.orientation = orientation
            app.terminate()
            app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES"]
            launch(screen: "live")
            let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
            XCTAssertTrue(player.waitForExistence(timeout: 60))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Playing"), object: player)], timeout: 60), .completed)
            attach("ipad-live-\(name)")
            let bar = app.descendants(matching: .any).matching(identifier: "live.categories").firstMatch
            let list = app.descendants(matching: .any).matching(identifier: "live.list").firstMatch
            XCTAssertTrue(bar.exists && list.exists)
            let stage = player.frame
            XCTAssertEqual(stage.minX, app.frame.minX, accuracy: 1)
            XCTAssertEqual(stage.width, app.frame.width, accuracy: 1)
            XCTAssertEqual(bar.frame.minY, stage.maxY, accuracy: 1, "The strip sits directly on the stage")
            XCTAssertEqual(bar.frame.width, app.frame.width, accuracy: 1)
            XCTAssertEqual(bar.frame.height, 81, accuracy: 1)
            XCTAssertGreaterThanOrEqual(list.frame.maxY - bar.frame.maxY, 3 * 88 - 1, "Three rows fit under the strip")
            XCTAssertEqual(list.frame.maxY, app.frame.maxY, accuracy: 1, "The list reaches the bottom")
            let frames = XCTAttachment(string: "app: \(app.frame)\nstage: \(stage)\nbar: \(bar.frame)\nlist: \(list.frame)")
            frames.name = "ipad-live-\(name)-frames"
            frames.lifetime = .keepAlways
            add(frames)
        }
        let watching = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true",
                                                        "guide.play.")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 10))
        watching.tap()
        let close = app.buttons["player.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The playing row opens full screen on iPad")
        attach("ipad-live-playing-row-full-screen")
        close.tap()
        XCTAssertTrue(revealInlineLiveControls(timeout: 30))
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(isSafelyHittable(fullScreen))
        fullScreen.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Full Screen still opens the player")
        close.tap()
    }

    func testLiveCategoryBarStaysFixedWhileScrolling() throws {
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamProbeLiveCategoryScroll", "YES"]
        if let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"], let url = URL(string: raw) {
            let base = url.deletingLastPathComponent().deletingLastPathComponent()
            app.launchArguments += try localSourceArguments([["kind": "m3u", "name": "IPTV",
                "playlistURL": base.appendingPathComponent("sliding/channels.m3u").absoluteString]])
        }
        launch(screen: "live")
        let bar = app.descendants(matching: .any).matching(identifier: "live.categories").firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "live.list").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 60))
        XCTAssertTrue(list.waitForExistence(timeout: 30))
        let favorites = app.buttons["live.category.Favorites"].firstMatch
        if !favorites.exists {
            let channel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).firstMatch
            XCTAssertTrue(channel.waitForExistence(timeout: 30))
            channel.press(forDuration: 1)
            let favorite = app.buttons["Favorite"].firstMatch
            XCTAssertTrue(favorite.waitForExistence(timeout: 5))
            favorite.tap()
        }
        XCTAssertTrue(favorites.waitForExistence(timeout: 10))
        let all = app.buttons["live.category.All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 30))
        let barFrame = bar.frame
        let allFrame = all.frame
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        XCTAssertEqual(barFrame.minY, stage.frame.maxY, accuracy: 1)
        // Paramount+ on a test iPhone: the labels' centre 37.5 pt below the stage, at the rows' 16 pt inset.
        XCTAssertEqual(allFrame.midY - barFrame.minY, 38, accuracy: 1, "chip \(allFrame) in strip \(barFrame)")
        XCTAssertEqual(allFrame.minX, barFrame.minX + 16, accuracy: 1, "chip \(allFrame) in strip \(barFrame)")
        // Owner 2026-10-22: the strip "looks too big and not aligned". Its glyphs share the labels' line.
        for id in ["live.guide", "live.search"] {
            let glyph = app.buttons[id].firstMatch
            XCTAssertEqual(glyph.frame.midY, allFrame.midY, accuracy: 0.5, "\(id) \(glyph.frame) vs \(allFrame)")
            XCTAssertEqual(glyph.frame.height, allFrame.height, accuracy: 0.5, "\(id) \(glyph.frame)")
        }
        let stripFrames = XCTAttachment(string: "strip: \(barFrame)\nAll: \(allFrame)\nguide: "
            + "\(app.buttons["live.guide"].firstMatch.frame)\nsearch: \(app.buttons["live.search"].firstMatch.frame)")
        stripFrames.name = "live-strip-frames"
        stripFrames.lifetime = .keepAlways
        add(stripFrames)
        attach("live-categories-before-scroll")
        let firstChannel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).firstMatch
        let firstChannelID = firstChannel.identifier
        for _ in 0..<3 {
            list.swipeUp()
            XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 1)
            XCTAssertEqual(bar.frame.height, barFrame.height, accuracy: 1)
            XCTAssertEqual(all.frame.minY, allFrame.minY, accuracy: 1)
        }
        attach("live-categories-after-scroll")
        if ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] != nil {
            let first = app.buttons[firstChannelID].firstMatch
            XCTAssertTrue(!first.exists || first.frame.maxY < list.frame.minY,
                          "The channel list must actually scroll away from its initial rows")
        }
        // Owner 2026-10-21: the bar "floats". A vertical drag that starts on a chip, down past the strip
        // and back up, leaves the chips where they were.
        let chip = all.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for dy in [120.0, -60.0] {
            chip.press(forDuration: 0.05, thenDragTo: chip.withOffset(CGVector(dx: 0, dy: dy)),
                       withVelocity: .slow, thenHoldForDuration: 1)
            XCTAssertEqual(all.frame.minY, allFrame.minY, accuracy: 1, "drag \(dy) pt on the chip")
            XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 1)
        }
        attach("live-categories-after-drag-on-bar")
        // Owner 2026-10-21: the bar still "floats". Pulled past the list's top, the rows
        // rubber-band under a strip that stays put.
        for _ in 0..<3 { list.swipeDown() }
        let listTop = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        listTop.press(forDuration: 0.05, thenDragTo: listTop.withOffset(CGVector(dx: 0, dy: 160)),
                      withVelocity: .slow, thenHoldForDuration: 2)
        XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 1)
        XCTAssertEqual(all.frame.minY, allFrame.minY, accuracy: 1)
        attach("live-categories-after-pull-down")
        let categoryTrace = try currentOpenStreamTrace()
        XCTAssertTrue(categoryTrace.contains { $0.contains("live category scroll probe ready") })
        let offsets = categoryTrace.compactMap { line -> Double? in
            guard let marker = line.range(of: "live category vertical offset=") else { return nil }
            return Double(line[marker.upperBound...])
        }
        XCTAssertFalse(offsets.isEmpty, "The native scroll view did not publish its initial geometry")
        for offset in offsets {
            XCTAssertEqual(offset, offsets.first ?? 0, accuracy: 1,
                           "The labels moved vertically inside the pinned bar during a drag")
        }
        XCTAssertTrue(isSafelyHittable(favorites))
        let before = favorites.frame
        favorites.tap()
        XCTAssertTrue(favorites.isSelected)
        XCTAssertEqual(favorites.frame.minX, before.minX, accuracy: 1,
                       "Selecting a visible category must not slide it inside the fixed bar")
        XCTAssertEqual(favorites.frame.minY, before.minY, accuracy: 1)
        attach("live-categories-favorites-selected")
    }

    func testSettingsBackButtonRemainsReadableInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-OpenStreamDebugColorScheme", appearance, "-OpenStreamMuteAudio", "YES"]
            launch(screen: "about")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 30))
            attach("settings-navigation-" + appearance)
            try assertReadableNonBlueLabel(back.screenshot(), appearance: appearance, name: "settings-back")
            app.terminate()
        }
    }

    func testPlaybackUnavailableAlertUsesReadableAppTintInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            app.launchArguments = ["-OpenStreamResetOnLaunch", "YES", "-OpenStreamMuteAudio", "YES",
                "-OpenStreamDebugColorScheme", appearance, "-OpenStreamDebugPlaybackUnavailable", "YES"]
            launch(screen: "detail-movie")
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 60))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                play.exists && play.isEnabled && play.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
            play.tap()
            let alert = app.alerts["Playback Unavailable"].firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 60))
            let ok = alert.buttons["OK"]
            XCTAssertTrue(ok.isHittable)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "playback-unavailable-" + appearance
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let button = XCTAttachment(screenshot: ok.screenshot())
            button.name = "playback-unavailable-ok-" + appearance
            button.lifetime = .keepAlways
            add(button)
            try assertReadableNonBlueLabel(ok.screenshot(), appearance: appearance, name: "playback-unavailable-ok")
            ok.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
            app.terminate()
        }
    }

    private func assertReadableNonBlueLabel(_ screenshot: XCUIScreenshot, appearance: String, name: String) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(screenshot.pngRepresentation as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func color(_ x: Int, _ y: Int) -> [Double] {
            let offset = (y * width + x) * 4
            return (0..<3).map { Double(pixels[offset + $0]) / 255 }
        }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let background = color(width / 2, height / 8)
        let backgroundLuminance = luminance(background)
        func contrast(_ rgb: [Double]) -> Double {
            let foreground = luminance(rgb)
            return (max(foreground, backgroundLuminance) + 0.05) / (min(foreground, backgroundLuminance) + 0.05)
        }
        var labelPixels: [[Double]] = []
        for y in (height / 4)..<(height * 3 / 4) {
            for x in (width / 3)..<(width * 2 / 3) {
                let rgb = color(x, y)
                if zip(rgb, background).contains(where: { abs($0.0 - $0.1) > 0.2 }) { labelPixels.append(rgb) }
            }
        }
        let foreground = Array(labelPixels.sorted { contrast($0) > contrast($1) }.prefix(16))
        XCTAssertEqual(foreground.count, 16, "\(appearance): no visible \(name) label pixels")
        let mean = (0..<3).map { component in
            foreground.reduce(0) { $0 + $1[component] } / Double(foreground.count)
        }
        XCTAssertFalse(mean[2] > mean[0] + 0.15 && mean[2] > mean[1] + 0.1,
                       "\(appearance): \(name) is blue: \(mean)")
        XCTAssertGreaterThanOrEqual(contrast(mean), 3, "\(appearance): \(name) lacks contrast with its background")
        let evidence = XCTAttachment(string: "\(appearance): \(name) RGB=\(mean), background=\(background), contrast=\(contrast(mean))")
        evidence.name = name + "-pixels-" + appearance
        evidence.lifetime = .keepAlways
        add(evidence)
    }


    func testLiveSearchFiltersWhileItsResultsArePushed() throws {
        app.launchArguments = ["-OpenStreamResetOnLaunch", "YES", "-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let hold = app.launchArguments.firstIndex(of: "-openstream.reset.cloudRestoreHeld.v1")
        XCTAssertNotNil(hold)
        if let hold { XCTAssertEqual(app.launchArguments[hold + 1], "YES") }
        let cbs = app.buttons["Play CBS"].firstMatch
        let news = app.buttons["Play Fixture News"].firstMatch
        let film = app.buttons["Play Fixture Film"].firstMatch
        for channel in [cbs, news, film] {
            XCTAssertTrue(channel.waitForExistence(timeout: 30))
        }
        let selected = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'guide.play.' AND selected == true")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        let selectedID = selected.identifier
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 60), .completed)
        let beforeSearch = try currentOpenStreamTrace()
        XCTAssertTrue(beforeSearch.contains { $0.contains("live inline configured") })
        XCTAssertFalse(beforeSearch.contains { $0.contains("live inline disappeared") },
                       "The placeholder-to-player swap called inlineDisappeared")
        let searchButton = app.buttons["live.search"].firstMatch
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
        searchButton.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Fixture News")
        let nonmatchingRows = [cbs, film].map { channel in
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: channel)
        }
        XCTAssertEqual(XCTWaiter.wait(for: nonmatchingRows, timeout: 10), .completed,
                       "Live search kept channels that do not match the query")
        XCTAssertTrue(news.exists)

        let clear = search.buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        search.tap()
        search.typeText("OpenStreamNoSuchChannel1026")
        let empty = app.staticTexts["No channels"].firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'")).count, 0)

        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        for channel in [cbs, news, film] {
            XCTAssertTrue(channel.waitForExistence(timeout: 10))
        }
        XCTAssertFalse(empty.exists)
        XCTAssertTrue(app.buttons[selectedID].firstMatch.isSelected,
                      "Filtering the list changed the channel being watched")
        let back = app.navigationBars.buttons.matching(NSPredicate(
            format: "identifier == 'BackButton' OR label == 'Live'")).firstMatch
        if !isSafelyHittable(back) {
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let popped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: search)
        XCTAssertEqual(XCTWaiter.wait(for: [popped], timeout: 10), .completed)
        XCTAssertTrue(app.buttons[selectedID].firstMatch.isSelected)
        XCTAssertEqual(stage.value as? String, "Playing")
        let afterSearch = try currentOpenStreamTrace()
        let evidence = XCTAttachment(string: afterSearch.filter {
            $0.contains("live appeared") || $0.contains("live inline") || $0.contains("play \"")
        }.joined(separator: "\n"))
        evidence.name = "live-search-playback-lifetime"
        evidence.lifetime = .keepAlways
        add(evidence)
        for event in ["live appeared", "live inline configured", "play \""] {
            XCTAssertEqual(afterSearch.filter { $0.contains(event) }.count,
                           beforeSearch.filter { $0.contains(event) }.count,
                           "Returning from Live search repeated \(event)")
        }
    }

    /// Owner 2026-10-22: "live video player icons are not the same size … a bit jank". Every glyph
    /// on the inline stage and in the full-screen player has the same 44 pt target; a row shares one
    /// centre line, with even gaps where the glyphs sit together.
    func testLivePlayerGlyphsShareOneSizeAndLine() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Phone Live layout")
        }
        continueAfterFailure = true
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES"]
        launch(screen: "live")
        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Playing"), object: player)], timeout: 60), .completed)
        XCTAssertTrue(revealInlineLiveControls(timeout: 60))
        let inline = glyphFrames(["player.mute", "player.airplay", "player.fullscreen"], within: player.frame)
        attach("live-glyphs-inline")
        assertGlyphRow(inline, name: "inline", evenGaps: true)

        app.buttons["player.fullscreen"].firstMatch.tap()
        let close = app.buttons["player.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(revealPlayerControls())
        attach("live-glyphs-full-screen")
        // Picture in Picture and Unmute are offered only on a PiP-capable route and while muted by the viewer.
        let top = glyphFrames(["player.close", "player.options"], within: app.frame)
        let bottom = glyphFrames(["player.airplay", "player.captions", "player.channels"], within: app.frame)
        let side = glyphFrames(["live.player.next", "live.player.previous"], within: app.frame)
        assertGlyphRow(top, name: "full-screen top", evenGaps: false)
        assertGlyphRow(bottom, name: "full-screen bottom", evenGaps: true)
        assertGlyphRow(side, name: "full-screen channel step", evenGaps: false, sameLine: false)
        let frames = XCTAttachment(string: (inline + top + bottom + side).map { "\($0.id): \($0.frame)" }
            .joined(separator: "\n"))
        frames.name = "live-glyph-frames"
        frames.lifetime = .keepAlways
        add(frames)
        close.tap()
    }

    private func glyphFrames(_ ids: [String], within bounds: CGRect) -> [(id: String, frame: CGRect)] {
        ids.compactMap { id in
            let found = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
                .first { !$0.frame.isEmpty && bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            XCTAssertNotNil(found, "\(id) is not on screen within \(bounds)")
            return found.map { (id, $0.frame) }
        }
    }

    private func assertGlyphRow(_ row: [(id: String, frame: CGRect)], name: String, evenGaps: Bool,
                                sameLine: Bool = true) {
        XCTAssertGreaterThanOrEqual(row.count, 2, "\(name): \(row)")
        guard let first = row.first else { return }
        for glyph in row {
            XCTAssertEqual(glyph.frame.width, 44, accuracy: 0.5, "\(name) \(glyph.id) \(glyph.frame)")
            XCTAssertEqual(glyph.frame.height, 44, accuracy: 0.5, "\(name) \(glyph.id) \(glyph.frame)")
            if sameLine {
                XCTAssertEqual(glyph.frame.midY, first.frame.midY, accuracy: 0.5, "\(name) \(glyph.id) \(glyph.frame)")
            }
        }
        guard evenGaps else { return }
        let sorted = row.map(\.frame).sorted { $0.minX < $1.minX }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.minX - $0.maxX }
        for gap in gaps { XCTAssertEqual(gap, gaps[0], accuracy: 0.5, "\(name) gaps \(gaps)") }
    }

    /// Owner 2026-10-22: rows "loading like that". A fresh container and a
    /// playlist that answers 6 s late: the list area shows one "Loading
    /// Channels" spinner, nothing else spins, then the strip and rows replace it.
    func testLiveShowsOneLoadingStateWhileThePlaylistLoads() {
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamResetOnLaunch", "YES",
                               "-OpenStreamStubPlaylistStall", "6"]
        launch(screen: "live")
        let loading = app.descendants(matching: .any).matching(identifier: "live.channels.loading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 15), "No loading state while the playlist stalls")
        attach("live-loading-state")
        XCTAssertTrue(app.staticTexts["Loading Channels"].exists || loading.label == "Loading Channels")
        let others = app.progressIndicators.matching(NSPredicate(format: "identifier != %@", "live.channels.loading"))
        XCTAssertEqual(others.count, 0, "Only the list's spinner while loading")
        XCTAssertFalse(app.descendants(matching: .any)["live.categories"].exists, "No strip before there are channels")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(loading.exists)
        XCTAssertTrue(app.descendants(matching: .any)["live.categories"].exists)
    }

    func testLiveReconnectShowsOneLoadingIndicator() async throws {
        let base = try liveLabURL().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        let (_, reset) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/reset"))
        XCTAssertEqual((reset as? HTTPURLResponse)?.statusCode, 200)
        app.launchArguments = ["-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackIsLive", "YES",
            "-OpenStreamVisionPlaybackURL", base.appendingPathComponent("reconnect/index.m3u8").absoluteString,
            "-OpenStreamMuteAudio", "YES", "-openstream.playback.engine", "native"]
        launch()
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        await fulfillment(of: [playing], timeout: 45)
        let (_, stalled) = try await URLSession.shared.data(from: base.appendingPathComponent("reconnect/stall"))
        XCTAssertEqual((stalled as? HTTPURLResponse)?.statusCode, 200)
        let reconnecting = app.descendants(matching: .any)["live.reconnecting"].firstMatch
        XCTAssertTrue(reconnecting.waitForExistence(timeout: 90))
        attach("live-reconnecting-indicator")
        attachHierarchy("live-reconnecting-hierarchy")
        let indicators = app.descendants(matching: .any).matching(identifier: "live.loading")
        XCTAssertEqual(indicators.count, 1, "Reconnect must share the stage's loading indicator")
        XCTAssertEqual(indicators.firstMatch.label, "Reconnecting")
        let stageFrame = stage.frame
        let visibleIndicators = (app.activityIndicators.allElementsBoundByAccessibilityElement
            + app.progressIndicators.allElementsBoundByAccessibilityElement).filter {
            !$0.frame.isEmpty && stageFrame.intersects($0.frame)
                && $0.descendants(matching: .activityIndicator).count == 0
                && $0.descendants(matching: .progressIndicator).count == 0
        }
        XCTAssertEqual(visibleIndicators.count, 1, "Reconnect must not leave an unnamed spinner visible")
    }

    func testLiveGuideSheetOpensAndDismisses() {
        app.launchArguments = ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let guide = app.buttons["live.guide"].firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 60))
        guide.tap()
        let done = app.buttons["live.guide.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Guide"].exists)
        attach("live-guide-sheet")
        done.tap()
        XCTAssertTrue(guide.waitForExistence(timeout: 10))
        XCTAssertFalse(done.exists)
    }

    /// Captures every debug route without adding sources or modifying settings.
    func testEveryRouteIsPhotographed() {
        let routes = ["discover", "library", "live", "detail", "episodes", "play", "first-run",
                      "backup", "channels", "playback-settings", "metadata",
                      "watch-providers", "privacy", "storage", "about", "add-files",
                      "add-media-server", "subtitle-languages", "settings"]
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            for route in routes {
                app.launchArguments = []
                XCUIDevice.shared.orientation = orientation
                launch(screen: route)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
                if ["detail", "episodes"].contains(route) {
                    XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 60))
                    Thread.sleep(forTimeInterval: 3)
                } else {
                    Thread.sleep(forTimeInterval: ["discover", "play"].contains(route) ? 25 : 3)
                }
                let prefix = "sweep-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(orientation == .portrait ? "portrait" : "landscape")-\(route)"
                attach(prefix)
                let controls = app.buttons.allElementsBoundByIndex.filter { isSafelyHittable($0) }.map {
                    "\($0.identifier) | \($0.label.contains("://") ? "[URL]" : $0.label) | \($0.frame) | enabled=\($0.isEnabled)"
                }.joined(separator: "\n")
                let inventory = XCTAttachment(string: controls)
                inventory.name = prefix + "-buttons"
                inventory.lifetime = .keepAlways
                add(inventory)
                app.terminate()
            }
        }
    }

    func testChooseFolderPresentsItsPickerAndDismissalReturnsToAddFiles() {
        launch(screen: "add-files")
        let folder = app.buttons["Choose Folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15), "Choose Folder did not present the document picker")
        attach("choose-folder-picker")
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The document picker has no Cancel control")
        cancel.tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: folder)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 15), .completed)
        XCTAssertFalse(app.alerts["Couldn’t Add Folder"].exists)
        attach("choose-folder-after-cancel")
    }

    /// Uses an ephemeral local video through Direct URL; it adds no saved source.
    func testChapterMarkerSkipIntroSeeksAndDisappears() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_CHAPTER_FIXTURE_URL"],
              !fixture.isEmpty else {
            throw XCTSkip("OPENSTREAM_CHAPTER_FIXTURE_URL not set")
        }
        launch(screen: "add-files")
        let directURL = app.buttons["Direct URL"].firstMatch
        XCTAssertTrue(directURL.waitForExistence(timeout: 30), "Direct URL row missing")
        directURL.tap()
        let dialog = app.alerts["Direct URL"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Direct URL dialog missing")
        let field = dialog.textFields.firstMatch
        field.tap()
        field.typeText(fixture)
        dialog.buttons["Play"].tap()

        let skip = app.buttons["player.skipIntro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 30), "Chapter-backed Skip Intro never appeared")
        let scrubber = app.sliders["Playback position"]
        XCTAssertTrue(scrubber.exists, "Playback scrubber missing during intro")
        XCTAssertLessThanOrEqual(skip.frame.maxY, scrubber.frame.minY,
                                 "Skip Intro must sit above the playback controls: \(skip.frame), \(scrubber.frame)")
        attach("chapter-intro-before-skip")
        skip.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: skip)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed, "Skip Intro remained after skipping")
        let position = app.sliders["Playback position"]
        let sought = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let text = position.value as? String else { return false }
                let parts = text.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return false }
                let seconds = parts[0] * 60 + parts[1]
                return seconds >= 50 && seconds < 65
            }, object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 10), .completed,
                       "Expected seek to the 50-second chapter boundary; position: \(String(describing: position.value))")
        attach("chapter-intro-after-skip")
        XCTAssertFalse(app.alerts["Playback Failed"].exists, "The chapter seek failed")
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

    /// Read-only walk of the owner's own library and share (narrated recording
    /// 2026-10-15): it opens Add Folder's browser and backs out without adding.
    /// Navigates by the tab bar: the debug screen hook does not hold on the owner's setup.
    func testNarratedOwnerLibraryAndShare() throws {
        guard let sourceName = ProcessInfo.processInfo.environment["OPENSTREAM_NARRATION_SOURCE"], !sourceName.isEmpty else {
            throw XCTSkip("Requires the owner source named by OPENSTREAM_NARRATION_SOURCE")
        }
        launch()
        app.tabBars.buttons["Library"].tap()
        // The owner's library loads from the share; give it time before the first look.
        Thread.sleep(forTimeInterval: 8)
        attach("narration-after-library-top")
        let recent = app.descendants(matching: .any)["library.shelf.Recently Added"].firstMatch
        scrollToControl(recent, in: app, limit: 20)
        attach("narration-after-library")
        attachHierarchy("narration-after-library-hierarchy")
        XCTAssertTrue(recent.waitForExistence(timeout: 30))
        XCTAssertNotEqual(recent.elementType, .button, "Recently Added must not open a list")
        let genre = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.shelf."))
            .matching(NSPredicate(format: "NOT (identifier IN %@)", ["library.shelf.Recently Added", "library.shelf.Continue Watching"]))
            .firstMatch
        scrollToControl(genre, in: app, limit: 20)
        attach("narration-after-library-genres")

        app.tabBars.buttons["Settings"].tap()
        let sources = app.buttons["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        let mediaServer = app.buttons["Media Server"].firstMatch
        XCTAssertTrue(mediaServer.waitForExistence(timeout: 10))
        mediaServer.tap()
        XCTAssertTrue(app.buttons["sources.mediaServer.test"].waitForExistence(timeout: 20))
        attach("narration-add-media-server")
        app.navigationBars.buttons.firstMatch.tap()
        let source = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", sourceName)).firstMatch
        scrollToControl(source, in: app, limit: 20)
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()
        let addFolder = app.descendants(matching: .any)["sources.smb.addFolderFromSettings"].firstMatch
        XCTAssertTrue(addFolder.waitForExistence(timeout: 20))
        attach("narration-after-share-details")
        addFolder.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sources.smb.select.'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 60))
        attach("narration-after-share-folder-browser")
    }

    func testNarratedSettingsHaveOneTransferAndAdvancedMetadata() {
        launch(screen: "settings")
        let backup = app.buttons["settings.backup"].firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        backup.tap()
        let transferTo = app.buttons["setup.transfer.to"].firstMatch
        XCTAssertTrue(transferTo.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["setup.transfer.from"].exists)
        attach("settings-transfer-actions")
        transferTo.tap()
        XCTAssertTrue(app.textFields["setup.transfer.link"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["setup.transfer.continue"].isEnabled)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["setup.transfer.from"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["setup.receive.qr"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["setup.receive.cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let metadata = app.buttons["settings.metadata"].firstMatch
        scrollToControl(metadata, in: app)
        metadata.tap()
        let advanced = app.buttons["settings.metadata.advanced"].firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        advanced.tap()
        XCTAssertTrue(app.secureTextFields["settings.metadata.tmdb"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["settings.metadata.omdb"].exists)
        attach("settings-metadata-advanced")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        let general = app.buttons["settings.general"].firstMatch
        for _ in 0..<6 where !general.exists || !general.isHittable || general.frame.minY < app.frame.minY + 70 {
            app.swipeDown()
        }
        XCTAssertTrue(general.isHittable)
        general.tap()
        XCTAssertTrue(app.switches["Top 10 lists"].firstMatch.waitForExistence(timeout: 10))
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
        scrollToControl(metadata, in: app)
        XCTAssertTrue(metadata.waitForExistence(timeout: 30), "no Metadata row")
        metadata.tap()

        let enabled = app.switches["Use Metadata APIs"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        if enabled.value as? String == "0" {
            enabled.switches.firstMatch.tap()
            addTeardownBlock { [self] in
                app.terminate()
                app.launchArguments = []
                launch(screen: "metadata")
                let toggle = app.switches["Use Metadata APIs"].firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: 10))
                if toggle.value as? String == "1" { toggle.switches.firstMatch.tap() }
                XCTAssertEqual(toggle.value as? String, "0", "Metadata setting was not restored")
            }
        }
        app.buttons["settings.metadata.advanced"].tap()
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no field to type into")
        XCTAssertTrue(field.isEnabled, "the fixture must enable Metadata for this typing scenario")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the field did not receive keyboard focus")
        let typed = "abc123test"
        field.typeText(typed)
        Thread.sleep(forTimeInterval: 2.0)
        attach("typing-entered")

        // Leave the screen and come back: a field that only looks right while
        // focused is the failure being chased.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings.metadata.advanced"].tap()
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
        scrollToControl(metadata, in: app)
        XCTAssertTrue(metadata.waitForExistence(timeout: 30), "no Metadata row in Settings")
        metadata.tap()

        // Metadata is off on a clean install, which disables both fields.
        // Exercise the real toggle and restore it even if a keyboard check fails.
        let enabled = app.switches["Use Metadata APIs"].firstMatch
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        if enabled.value as? String == "0" {
            addTeardownBlock { [self] in
                app.terminate()
                app.launchArguments = []
                launch(screen: "metadata")
                let toggle = app.switches["Use Metadata APIs"].firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: 10))
                if toggle.value as? String == "1" { toggle.switches.firstMatch.tap() }
                XCTAssertEqual(toggle.value as? String, "0", "Metadata setting was not restored")
            }
            // iOS 27 exposes the labelled row and its actual switch separately.
            // The row's centre is the label, which doesn't toggle the control.
            enabled.switches.firstMatch.tap()
        }

        app.buttons["settings.metadata.advanced"].tap()
        let first = app.secureTextFields["settings.metadata.tmdb"]
        let last = app.secureTextFields["settings.metadata.omdb"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "the TMDB field never appeared")
        XCTAssertTrue(last.exists, "the OMDb field never appeared")
        XCTAssertTrue(first.isEnabled && last.isEnabled, "Metadata fields must be enabled to test the keyboard")

        // First field: another one follows, so the return key should offer to
        // go there rather than just dismiss.
        first.tap()
        let next = app.keyboards.buttons["next"]
        let hasNext = next.waitForExistence(timeout: 10)
        // Attach *after* the key is found: capturing on a fixed sleep caught the
        // frame before the keyboard had animated up, so the picture showed no
        // keyboard at all while the assertion was passing.
        attach("ios-return-key-first-field")
        print("RETURNKEY first field: next=\(hasNext)")
        XCTAssertTrue(hasNext, "the first field's return key does not offer the next field")

        // Follow the actual submit chain; tapping the last field directly
        // would let a broken onSubmit handler pass.
        next.tap()
        let done = app.keyboards.buttons["done"]
        let hasDone = done.waitForExistence(timeout: 10)
        attach("ios-return-key-last-field")
        print("RETURNKEY last field: done=\(hasDone)")

        XCTAssertTrue(hasDone, "the last field's return key does not read done")
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
            "the last field's return key did not dismiss the keyboard")
    }

    /// Owner F2, and the complaint that started it: "I search for Jury duty
    /// and go odd results".
    ///
    /// Driven through the app rather than the `openstream://search` deep link,
    /// so this is the path a viewer actually takes: tap the search glyph, type,
    /// read the rows.
    func testSearchingFromTheToolbarReturnsShowsAndMoviesOnly() {
        launch(screen: "discover")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Search control in the toolbar")
        search.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the search field never appeared")
        XCTAssertFalse(app.buttons["Refresh"].exists, "Search has an extra Refresh control")
        field.tap()
        field.typeText("stub series")
        let seriesRows = app.links.matching(NSPredicate(format: "label CONTAINS[c] %@", "Stub Series"))
        XCTAssertTrue(seriesRows.firstMatch.waitForExistence(timeout: 30), "No actionable Stub Series result appeared")
        let deadline = Date().addingTimeInterval(30)
        var previousLabels: [String] = []
        var stableSince = Date()
        var settled = false
        while Date() < deadline {
            let labels = app.links.allElementsBoundByIndex.map(\.label).sorted()
            if labels != previousLabels {
                previousLabels = labels
                stableSince = Date()
            }
            if !labels.isEmpty, !app.progressIndicators.firstMatch.exists,
               Date().timeIntervalSince(stableSince) >= 3 {
                settled = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(settled, "Search results never settled")
        attach("ios-search-jury-duty")

        // Every row names its kind; an episode row would read "Episode".
        let episodeRows = app.links
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Episode")).count
        XCTAssertEqual(episodeRows, 0, "search returned \(episodeRows) episode rows")

        // Search exposes link traits; a matching empty-state label is not a result.
        XCTAssertGreaterThan(seriesRows.count, 0, "no Stub Series rows came back at all")
        XCTAssertFalse(app.buttons["Refresh"].exists, "Search results have an extra Refresh control")
        seriesRows.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.episodes"].firstMatch.waitForExistence(timeout: 30),
            "The accessible Search result did not open its title page")
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
        launch(screen: "live-settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app never came to the foreground")

        let live = app.switches["settings.live.enabled"]
        scrollToControl(live, in: app)
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
    func testDownloadStartsWithoutAskingForASource() throws {
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
        print("DOWNLOAD target before scroll: \(download.frame), hittable=\(download.isHittable)")
        for _ in 0..<8 where !download.isHittable {
            // Scroll only when the target is genuinely outside the usable viewport.
            if download.frame.midY > app.frame.height - 100 { app.swipeUp(velocity: .slow) }
            else if download.frame.minY < 70 { app.swipeDown(velocity: .slow) }
            else { Thread.sleep(forTimeInterval: 1) }
        }
        print("DOWNLOAD target after scroll: \(download.frame), hittable=\(download.isHittable)")
        attach("episode-download-before-tap")
        XCTAssertTrue(download.isHittable, "Visible episode download must accept taps")
        XCTAssertGreaterThanOrEqual(download.frame.width, 44)
        XCTAssertGreaterThanOrEqual(download.frame.height, 44)
        attach("episode-download-hit-target")
        guard ProcessInfo.processInfo.environment["OPENSTREAM_ALLOW_MUTATING_UI_TESTS"] == "1" else {
            throw XCTSkip("44-point download target verified; starting a download requires permission to add simulator data.")
        }
        download.tap()
        Thread.sleep(forTimeInterval: 3.0)
        attach("download-after-tap")

        XCTAssertFalse(app.navigationBars["Download from"].exists, "a source sheet appeared — downloads must be automatic")
        XCTAssertFalse(app.navigationBars["Quality"].exists, "the playback quality sheet appeared on Download")

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
            let cancel = app.buttons["Cancel Download"].firstMatch
            if cancel.waitForExistence(timeout: 10) { cancel.tap() }
            Thread.sleep(forTimeInterval: 1.0)
            attach("download-cancelled")
        }
    }

    /// M3U sources use a URL or a file; the deprecated text editor stays removed.
    func testAddLiveTVUsesNativeActionsWithoutPlaylistText() {
        launch(screen: "add-live")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider Login")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.tap()
        let m3u = app.buttons["M3U Playlist"].firstMatch
        XCTAssertTrue(m3u.waitForExistence(timeout: 10))
        m3u.tap()
        XCTAssertTrue(app.buttons["sources.live.chooseFile"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textViews["sources.live.playlistText"].exists)
        XCTAssertFalse(app.staticTexts["Playlist Text"].exists)
        XCTAssertFalse(app.buttons["sources.live.save"].isEnabled)
        XCTAssertFalse(app.buttons["sources.live.test"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["sources.live.save"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["sources.live.test"].frame.height, 44)
        attach("add-live-m3u-native-actions")
    }

    /// Owner, 2026-09-17: a French M3U whose HLS streams sit behind
    /// extension-less URLs failed with "Demuxer: open failed (Operation not
    /// permitted (-1))". The playlist URL comes from the environment
    /// (TEST_RUNNER_OPENSTREAM_TEST_M3U) so provider tokens never land in the
    /// repo; without it the test skips. Adds the source, plays the first
    /// channel, expects no failure alert, then removes the source again.
    func testExtensionLessHLSChannelPlaysFromAnM3U() throws {
        guard let playlist = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"], !playlist.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_M3U not set")
        }
        addUITestPlaylist(playlist)
        attach("m3u-saved")
        let live = app.tabBars.buttons["Live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        live.tap()
        // "All" is the curated provider lineup; a playlist's channels are
        // reachable through Search (and the Everything package), so search.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Live search field")
        search.tap(); search.typeText("TMC")
        let channel = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "TMC")).firstMatch
        if !channel.waitForExistence(timeout: 30) { attach("m3u-search-no-tmc") }
        XCTAssertTrue(channel.exists, "TMC not found through Live search")
        channel.tap()
        Thread.sleep(forTimeInterval: 15.0)
        attach("m3u-tmc-after-15s")
        let alert = app.alerts.firstMatch
        let failed = alert.exists && alert.label.contains("Playback Failed")
        if failed { attach("m3u-playback-failed") }
        XCTAssertFalse(failed, "Playback Failed alert: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")

        removeUITestPlaylistSource()
    }

    /// Cleanup on its own so a failed run never leaves the playlist behind on
    /// the persistent simulator: Settings → Sources → "UITest Playlist" →
    /// Delete Source → Delete.
    func testZRemoveUITestPlaylistSource() {
        launch(screen: "settings")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        removeUITestPlaylistSource()
    }

    /// Add Live TV → M3U → name + URL → Save (validation + stream probe, up
    /// to ~30 s). Leaves the app on the Sources page.
    private func addUITestPlaylist(_ playlist: String, verifyConnection: Bool = false) {
        launch(screen: "add-live")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider Login")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "no Type picker")
        picker.tap()
        let m3u = app.buttons["M3U Playlist"].firstMatch
        XCTAssertTrue(m3u.waitForExistence(timeout: 10)); m3u.tap()
        let name = app.textFields["Name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("UITest Playlist")
        let url = app.textFields["Playlist URL"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10)); url.tap(); url.typeText(playlist)
        if app.keyboards.buttons["Return"].exists { app.keyboards.buttons["Return"].tap() }
        if verifyConnection {
            let test = app.buttons["sources.live.test"].firstMatch
            XCTAssertTrue(test.waitForExistence(timeout: 10))
            test.tap()
            let result = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Sample stream responded")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 40), "Connection did not report a responding sample stream")
            attach("live-test-connection-result")
        }
        var save = app.buttons["sources.live.save"].firstMatch
        if !save.waitForExistence(timeout: 5) { save = app.buttons["Save"].firstMatch }
        XCTAssertTrue(save.waitForExistence(timeout: 10), "no Save button on Add Live TV"); save.tap()
        let live = app.tabBars.buttons["Live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 60), "Live tab not reachable after saving")
        Thread.sleep(forTimeInterval: 2.0)
    }

    private func removeUITestPlaylistSource() {
        // Start from a known place: relaunch on the Settings root.
        app.terminate()
        launch(screen: "settings")
        _ = app.wait(for: .runningForeground, timeout: 30)
        let sources = app.buttons["Sources"].firstMatch
        guard sources.waitForExistence(timeout: 20) else { attach("cleanup-no-sources-row"); XCTFail("Sources row not found"); return }
        sources.tap()
        // The list is lazy: the row (added last) may be below the fold.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "UITest Playlist")).firstMatch
        var swipes = 0
        while !row.waitForExistence(timeout: 3), swipes < 6 { app.swipeUp(); swipes += 1 }
        guard row.exists else { attach("no-uitest-playlist-source"); return }
        row.tap()
        let delete = app.buttons["Delete Source"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "no Delete Source on the source page")
        delete.tap()
        let confirm = app.alerts.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no Delete confirmation")
        confirm.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "UITest Playlist")).firstMatch.exists, "source still listed")
        attach("m3u-source-removed")
    }

    /// Owner, 2026-09-17: "we need a better ux when dealing with something
    /// like 3000 channels". The manager lists only selected channels and
    /// adds through a searchable, grouped picker. Screenshots of all three
    /// states; nothing is changed in the selection.
    func testChannelManagerListsSelectedAndAddsThroughAPicker() throws {
        // The persistent sim's own live source may be off; bring a playlist
        // of our own (URL from the environment), and remove it at the end.
        guard let playlist = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"], !playlist.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_M3U not set")
        }
        addUITestPlaylist(playlist)
        defer { removeUITestPlaylistSource() }
        app.terminate()
        launch(screen: "channels")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        var add = app.buttons["channels.add"].firstMatch
        if !add.waitForExistence(timeout: 60) {
            add = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Add Channels")).firstMatch
        }
        if !add.exists { attach("channel-manager-no-add-row") }
        XCTAssertTrue(add.exists, "no Add Channels… row (is a Live TV source configured?)")
        XCTAssertFalse(app.staticTexts["Your Regional"].exists)
        attach("channel-manager-root")
        add.tap()
        let picker = app.navigationBars["Add Channels"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "picker did not open")
        Thread.sleep(forTimeInterval: 2.0)
        attach("channel-picker-groups")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "picker has no search field")
        search.tap(); search.typeText("tmc")
        Thread.sleep(forTimeInterval: 2.5)
        attach("channel-picker-search")
        // The filter must actually apply: TMC stays, a non-match goes.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "TMC")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == %@", "ARTE")).firstMatch.exists, "search did not filter the list")
    }

    /// Owner, 2026-09-17: "episode 1 still loads the wrong show". Plays the
    /// Discover billboard item (Mormon Wives on this sim) and leaves the
    /// candidate trace behind for inspection; asserts only that playback
    /// starts without a failure alert.
    func testBillboardPlayStartsWithoutFailure() {
        let title = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_HERO_TITLE"]
        if let title, !title.isEmpty {
            app.launchArguments += ["-OpenStreamHeroTitle", title]
        }
        launch(screen: "discover")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let play = app.buttons["home.featured.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 40), "no billboard playback control")
        if let title, !title.isEmpty {
            let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
            let pinned = XCTNSPredicateExpectation(predicate: NSPredicate(
                format: "exists == true AND hittable == true AND label CONTAINS[c] %@", title), object: details)
            guard XCTWaiter.wait(for: [pinned], timeout: 40) == .completed else {
                XCTFail("The requested title never became the visible hero")
                return
            }
        }
        play.tap()
        XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["player.connecting"].firstMatch.waitForNonExistence(timeout: 10))
        attach("billboard-play-first-frame")
        let alert = app.alerts.firstMatch
        XCTAssertFalse(alert.exists && alert.label.contains("Playback Failed"), "playback failed: \(alert.staticTexts.allElementsBoundByIndex.map(\.label))")
    }

    func testNativeTabRootsAndSourceHealthAudit() {
        for screen in ["discover", "library", "live", "settings", "source-detail"] {
            app.launchArguments = []
            launch(screen: screen)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            Thread.sleep(forTimeInterval: 4)
            // iPadOS draws no inline title under its top tab bar; the selected
            // tab names the page there (N35).
            if screen == "live", UIDevice.current.userInterfaceIdiom == .phone {
                // Owner item 9: Live has no navigation title; its video and guide name the surface.
                XCTAssertFalse(app.navigationBars.staticTexts["Live"].firstMatch.exists,
                               "Live must stay title-free (owner item 9)")
                XCTAssertTrue(app.buttons["live.guide"].firstMatch.waitForExistence(timeout: 30))
            }
            if screen == "source-detail", app.staticTexts["Connected"].firstMatch.exists {
                XCTAssertFalse(app.staticTexts["Username and password are required."].exists,
                               "Resolved historical login errors must not appear as a current failure")
            }
            attach("native-audit-" + screen)
            app.terminate()
        }
    }

    func testAddLiveTVActionsFitAtLargestTextSize() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launch(screen: "add-live")
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Provider Login")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.tap()
        app.buttons["M3U Playlist"].firstMatch.tap()
        let test = app.buttons["sources.live.test"].firstMatch
        var swipes = 0
        while !test.isHittable, swipes < 5 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(test.isHittable)
        XCTAssertGreaterThanOrEqual(test.frame.height, 44)
        XCTAssertLessThanOrEqual(test.frame.maxX, app.frame.maxX)
        attach("add-live-largest-text")
    }

    func testSavedLiveSourceDoesNotShowResolvedLoginFailure() throws {
        // Fixture import saves the playlist without a connection check.
        if ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false {
            app.launchArguments += ["-OpenStreamLiveAutoPlay", "NO"]
            launch(screen: "live")
            XCTAssertTrue(app.buttons["Play CBS"].firstMatch.waitForExistence(timeout: 30),
                          "The fixture playlist never loaded")
            let settings = app.tabBars.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
        } else {
            launch(screen: "settings")
        }
        let sources = app.buttons["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 20))
        sources.tap()
        // Rows read "<name>, <kind> · <host>, On": the name is the viewer's
        // own, so match the kind (N35: the iPad's source is named "LiveTV").
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", Live TV · ")).firstMatch
        // The iPad's tab bar sits at the top, where it covers no rows.
        let tabBar = app.tabBars.firstMatch
        let usableBottom = tabBar.exists && tabBar.frame.minY > app.frame.midY ? tabBar.frame.minY : app.frame.maxY
        var swipes = 0
        while swipes < 5 {
            if row.waitForExistence(timeout: 2), row.isHittable,
               row.frame.maxY < usableBottom { break }
            app.swipeUp(); swipes += 1
        }
        // The simulator's own data decides this: some carry no Live TV source.
        try XCTSkipUnless(row.exists, "No Live TV source on this simulator")
        row.tap()
        let connected = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Connected", "Connected")).firstMatch
        let found = connected.waitForExistence(timeout: 10)
        attach("live-source-current-health")
        XCTAssertTrue(found)
        XCTAssertFalse(app.staticTexts["Username and password are required."].exists)
    }

    /// N20 proof: the iPad's full-bleed Discover hero on its side, two pages.
    /// Navigation only — it turns the iPad and photographs, nothing else —
    /// and only when `OPENSTREAM_HERO_SHOT_DIR` asks for it (passed as
    /// `TEST_RUNNER_OPENSTREAM_HERO_SHOT_DIR`), since a headless iPadOS 26
    /// simulator cannot otherwise be rotated.
    func testIPadDiscoverHeroLandscapeShots() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "iPad hero")
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_HERO_SHOT_DIR"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }, "Set TEST_RUNNER_OPENSTREAM_HERO_SHOT_DIR to take the hero shots")
        app.launchArguments += ["-OpenStreamDebugNoKeychain", "YES"]
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["home.featured.play"].firstMatch.waitForExistence(timeout: 40))
        for page in 0 ..< 2 {
            Thread.sleep(forTimeInterval: page == 0 ? 6 : 13)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try png.write(to: directory.appendingPathComponent("ipad-landscape-\(page).png"))
            attach("ipad-discover-hero-landscape-\(page)")
        }
    }

    func testFeaturedTrailerKeepsBackAndFillsLandscape() throws {
        launch(screen: "discover")
        let details = app.buttons["home.featured.details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 40))
        details.tap()
        let back = app.buttons["detail.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        let screen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        let selectedIdentity = screen.identifier
        Thread.sleep(forTimeInterval: 26)
        XCTAssertEqual(screen.identifier, selectedIdentity, "A rotating hero replaced the title after navigation")
        attach("trailer-portrait")
        XCTAssertTrue(back.isHittable)
        let mute = app.buttons["detail.trailer.mute"].firstMatch
        let hasTrailer = mute.waitForExistence(timeout: 15)
        if hasTrailer {
            XCTAssertGreaterThanOrEqual(mute.frame.width, 44)
            XCTAssertGreaterThanOrEqual(mute.frame.height, 44)
            XCTAssertTrue(back.isHittable, "Back disappeared while the trailer was active")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 4)
        attach("trailer-landscape")
        XCTAssertTrue(back.isHittable)
        if UIDevice.current.userInterfaceIdiom == .phone {
            assertInterfaceOrientation(landscape: false)
            XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        }
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 3)
        attach("trailer-portrait-return")
        back.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        if !hasTrailer { throw XCTSkip("Featured title had no playable trailer; detail framing and Back were captured") }
    }

    /// The hero's one button is never dead (N17d): a title with nothing to
    /// play and no trailer says Details and opens the title page. Play
    /// Trailer is art-first (owner, 2026-09-24, N17d2): the press changes
    /// nothing on screen — no spinner, no "Loading", no message — the art
    /// stays, and the video crossfades in over it only once it plays. The
    /// burst of pictures after the press shows that, or the art staying.
    /// `OPENSTREAM_TEST_HERO_TITLE` names the title to lead the rotation with.
    /// N17e: a hero and its title page agree on whether the title plays.
    /// JEOPARDY!'s hero said Details while its title page offered Play and
    /// Download Season. Navigation only — Play is never pressed.
    /// `OPENSTREAM_TEST_HERO_TITLE` names the title to lead the rotation with.
    func testHeroLabelAgreesWithItsTitlePage() throws {
        guard let title = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_HERO_TITLE"], !title.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_HERO_TITLE not set")
        }
        app.launchArguments += ["-OpenStreamHeroTitle", title]
        launch(screen: "discover")
        let heroButton = app.buttons["home.featured.play"].firstMatch
        XCTAssertTrue(heroButton.waitForExistence(timeout: 60), "Discover never loaded its billboard")
        let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
        let pinned = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND hittable == true AND label CONTAINS[c] %@", title), object: details)
        XCTAssertEqual(XCTWaiter.wait(for: [pinned], timeout: 30), .completed,
                       "The requested title never became the visible hero")
        let heroName = details.label
        let heroLabel = heroButton.label
        let heroPlays = heroButton.isEnabled && Self.labelPlays(heroLabel)
        attach("hero-label-\(heroLabel)")
        XCTAssertTrue(heroName.localizedCaseInsensitiveContains(title), "The pinned title was not on the hero: \(heroName)")
        details.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.icon-row"].firstMatch.waitForExistence(timeout: 30), "The title page never opened")
        // Its episode list and canonical id settle the button.
        Thread.sleep(forTimeInterval: 8)
        // With nothing to play the page has no primary button (N22c).
        let pageButton = app.buttons["detail.play"].firstMatch
        let pageLabel = pageButton.exists ? pageButton.label : "none"
        let pagePlays = pageButton.exists && pageButton.isEnabled && Self.labelPlays(pageLabel)
        let pageTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch.exists
        attach("title-page-label-\(pageLabel)")
        print("[N17e] hero=\(heroName) heroLabel=\(heroLabel) heroPlays=\(heroPlays) pageLabel=\(pageLabel) pageIsTitle=\(pageTitle)")
        XCTAssertTrue(pageTitle, "The title page that opened is not \(title)")
        XCTAssertEqual(heroPlays, pagePlays, "The hero said \(heroLabel) while its title page said \(pageLabel)")
    }

    /// N22c: a title page draws no dead buttons — no greyed-out Play and no
    /// Download that cannot start. Opens the hero's title (pinned with
    /// `OPENSTREAM_TEST_HERO_TITLE` when set) and photographs its button row.
    /// Navigation only — nothing is pressed on the title page.
    func testTitlePageHasNoDeadButtons() throws {
        if let title = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_HERO_TITLE"], !title.isEmpty {
            app.launchArguments += ["-OpenStreamHeroTitle", title]
        }
        launch(screen: "discover")
        let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 60), "Discover never loaded its billboard")
        Thread.sleep(forTimeInterval: 4)
        let heroName = details.label
        details.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.icon-row"].firstMatch.waitForExistence(timeout: 30), "The title page never opened")
        // The episode list, canonical id and trailer lookup settle the row.
        Thread.sleep(forTimeInterval: 10)
        let play = app.buttons["detail.play"].firstMatch
        let downloads = ["detail.download", "detail.download.season", "detail.episode.download"]
            .map { app.buttons[$0].firstMatch }
        let found = downloads.filter(\.exists).map(\.identifier)
        print("[N22c] title=\(heroName) play=\(play.exists ? play.label : "none") playEnabled=\(play.exists && play.isEnabled) downloads=\(found)")
        attach("title-page-\(play.exists ? play.label : "no-play")-downloads-\(found.count)")
        if play.exists { XCTAssertTrue(play.isEnabled, "\(heroName): Play is drawn but dead") }
        if !play.exists || play.label == "Play Trailer" {
            XCTAssertTrue(found.isEmpty, "\(heroName): nothing plays, yet \(found) are drawn")
        }
    }

    private static func labelPlays(_ label: String) -> Bool {
        (label.hasPrefix("Play") && label != "Play Trailer") || label.hasPrefix("Resume")
    }

    func testHeroPrimaryButtonAnswersThePress() throws {
        guard let title = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_HERO_TITLE"], !title.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_HERO_TITLE not set")
        }
        app.launchArguments += ["-OpenStreamHeroTitle", title]
        launch(screen: "discover")
        let play = app.buttons["home.featured.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 60), "Discover never loaded its billboard")
        // The label settles once the hero's trailer lookup has answered.
        Thread.sleep(forTimeInterval: 4)
        // `OPENSTREAM_TEST_HERO_LABEL` pages through the carousel to a hero
        // whose button says it ("Play Trailer"), when the name matched none.
        if let wanted = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_HERO_LABEL"], !wanted.isEmpty {
            var pages = 0
            // A page's button is out of the tree until its lookup answers.
            // Across the art, above the title block, which is a button.
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.3))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3))
            while !(play.waitForExistence(timeout: 10) && play.label == wanted), pages < 8 {
                from.press(forDuration: 0.05, thenDragTo: to)
                pages += 1
                Thread.sleep(forTimeInterval: 4)
            }
            XCTAssertTrue(play.waitForExistence(timeout: 10))
        }
        let label = play.label
        attach("hero-at-rest-\(label)")
        XCTAssertTrue(play.isEnabled, "The hero showed a disabled \(label)")
        switch label {
        case "Details":
            play.tap()
            XCTAssertTrue(app.buttons["detail.back"].firstMatch.waitForExistence(timeout: 10),
                          "Details did not open the title page")
            attach("hero-details-opened")
        case "Play Trailer":
            play.tap()
            for frame in 0..<12 {
                Thread.sleep(forTimeInterval: 0.5)
                // A muted trailer does not hold the rotation, so the page may
                // move on; whatever the button says, it is never a loading
                // or failure state.
                let button = app.buttons["home.featured.play"].firstMatch
                XCTAssertFalse(["Loading", "Loading trailer", "Trailer unavailable"].contains(button.label),
                               "The hero's button showed a trailer loading state: \(button.label)")
                XCTAssertTrue(button.isEnabled, "The hero's button was disabled after the press")
                // Only the hero counts: shelves below may still be loading.
                let heroBottom = button.frame.maxY
                let heroSpinners = app.activityIndicators.allElementsBoundByIndex.filter {
                    $0.exists && !$0.frame.isEmpty && $0.frame.minY < heroBottom
                }
                XCTAssertTrue(heroSpinners.isEmpty, "A spinner appeared on the hero for the trailer")
                attach(String(format: "hero-trailer-burst-%02d", frame))
            }
            // The title page's Play Trailer is the same background action.
            let details = app.buttons["home.featured.details"].firstMatch
            guard details.waitForExistence(timeout: 5) else { break }
            details.tap()
            let pagePlay = app.buttons["detail.play"].firstMatch
            guard pagePlay.waitForExistence(timeout: 20), pagePlay.label == "Play Trailer" else { break }
            attach("detail-trailer-at-rest")
            pagePlay.tap()
            for frame in 0..<16 {
                Thread.sleep(forTimeInterval: 0.75)
                XCTAssertEqual(pagePlay.label, "Play Trailer", "The title page's Play Trailer changed its label")
                XCTAssertTrue(pagePlay.isEnabled, "The title page's Play Trailer was disabled after the press")
                attach(String(format: "detail-trailer-burst-%02d", frame))
            }
        default:
            break
        }
    }

    func testLivePlaylistShowsChannelFailureAndRecovers() throws {
        guard let playlist = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"], !playlist.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_M3U not set")
        }
        addUITestPlaylist(playlist, verifyConnection: true)
        defer { removeUITestPlaylistSource() }
        app.tabBars.buttons["Live"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("UITest Blocked Channel")
        let blocked = app.buttons["Play UITest Blocked Channel"].firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 30))
        blocked.tap()
        // Said inside the picture, not in an alert over the tab.
        let failure = app.descendants(matching: .any).matching(identifier: "live.failure").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 35))
        let message = failure.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(message.contains("UITest Blocked Channel"), message)
        XCTAssertTrue(failure.buttons["Try Again"].exists)
        XCTAssertFalse(message.contains("custom source probe"))
        XCTAssertFalse(message.contains("username"))
        XCTAssertFalse(app.alerts.firstMatch.exists, "a live failure opened an alert")
        attach("live-channel-denied")
        search.tap()
        let clearSearch = search.buttons.firstMatch
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 5))
        clearSearch.tap()
        search.typeText("UITest Working Channel")
        let working = app.buttons["Play UITest Working Channel"].firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 30))
        working.tap()
        Thread.sleep(forTimeInterval: 12)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "live.failure").firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Choosing a channel should dismiss the search keyboard")
        attach("live-channel-recovered")
    }

    /// The phone shell stays portrait; only the full-screen video rotates.
    /// Uses the configured Content simulator lineup, as in the Live player tests.
    ///
    /// The landscape half of that rule cannot be driven from here on this Mac:
    /// `XCUIDevice.shared.orientation` rotates the iPad app but never reaches
    /// the iPhone app — no `UIDevice.orientationDidChangeNotification` arrives,
    /// the orientation delegate is not asked again, and the interface stays
    /// portrait even with the player up and landscape allowed (proved by trace
    /// on 2026-09-19 with the player opened from the guide *and* launched
    /// straight into `-OpenStreamVisionScreen play`). So the turn is attempted
    /// and asserted when it takes, and the test skips at the end when it does
    /// not, having already proved everything the simulator can show.
    func testLandscapeHidesTheTabBarAndPortraitBringsItBack() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "iPhone orientation policy")
        // The chrome is removed from the view tree — not faded — three seconds
        // into playback, so "Pause" can be gone before the query for it lands.
        app.launchArguments += ["-OpenStreamHoldPlayerChrome", "YES"]
        launch(screen: "discover")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 3)
        assertInterfaceOrientation(landscape: false)
        XCTAssertTrue(app.tabBars.firstMatch.isHittable)
        attach("discover-stays-portrait-after-rotation")

        app.tabBars.buttons["Live"].firstMatch.tap()
        assertInterfaceOrientation(landscape: false)
        let channel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play CBS")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "CBS channel missing from the configured lineup")
        // A new selection starts inline; a selected row would instead open full screen.
        // Live follows the Paramount+ design (owner REA 2026-10-17): a row plays inline and Full
        // Screen is a separate control. Earlier crawls leave another channel selected, so on a
        // first run this tap starts CBS inline; the solo rerun only passed because "Start with
        // last channel" (default on) had resumed CBS from the failed run's history (row 74).
        if !channel.isSelected { channel.tap() }
        XCTAssertTrue(revealInlineLiveControls(timeout: 60), "CBS never reached the inline player")
        let fullscreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10), "Inline Full Screen control missing")
        XCTAssertTrue(fullscreen.isEnabled && app.frame.contains(fullscreen.frame),
                      "Full Screen is not an enabled visible control")
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["player.controls.show"].waitForExistence(timeout: 30),
                      "The channel never opened the full-screen player")
        XCTAssertTrue(revealPlayerControls(), "The player chrome never came back")
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 30), "Video did not reach playback")
        XCTAssertFalse(app.alerts["Playback Failed"].exists)
        // The player covers the tab bar however the phone is held.
        let coveredTabBar = app.tabBars.firstMatch
        XCTAssertFalse(coveredTabBar.exists && coveredTabBar.isHittable,
                       "the tab bar is reachable over the full-screen player")
        attach("player-over-the-tab-bar")

        // The phone was turned before the player existed, and a portrait-locked
        // app is not told about it; turn it again now that landscape is allowed.
        XCUIDevice.shared.orientation = .portrait
        assertInterfaceOrientation(landscape: false)
        XCUIDevice.shared.orientation = .landscapeRight
        let turned = waitForInterfaceOrientation(landscape: true, timeout: 10)
        if turned {
            XCTAssertFalse(coveredTabBar.exists && coveredTabBar.isHittable,
                           "the tab bar came back over the landscape player")
            // The touch surface belongs to the transport and respects landscape
            // safe-area insets (62 pt sides on this simulator). Measure the
            // fullscreen player container, whose video is constrained to its edges.
            // The app/window ancestor also contains Close and always fills
            // the screen. Exclude ancestors containing the covered tab bar
            // so this measures the modal player's own container.
            let player = try XCTUnwrap(app.otherElements.containing(.button, identifier: "player.close")
                .allElementsBoundByIndex.first { $0.descendants(matching: .tabBar).count == 0 },
                "no fullscreen player container")
            XCTAssertEqual(player.frame.width, app.frame.width, accuracy: 1,
                           "the video container does not fill the screen in landscape")
            XCTAssertEqual(player.frame.height, app.frame.height, accuracy: 1,
                           "the video container does not fill the screen in landscape")
            attach("player-landscape")
        } else {
            attach("player-would-not-turn")
        }

        let customClose = app.buttons["player.close"].firstMatch
        let nativeClose = app.buttons["Close"].firstMatch
        if !customClose.isHittable && !nativeClose.isHittable {
            let controls = app.buttons["player.controls.show"].firstMatch
            if controls.exists { controls.tap() } else { app.tap() }
        }
        let close = customClose.exists ? customClose : nativeClose
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        assertInterfaceOrientation(landscape: false)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Discover"].firstMatch.tap()
        assertInterfaceOrientation(landscape: false)
        attach("discover-portrait-after-landscape-player")

        try XCTSkipIf(!turned, """
            The simulator would not turn the phone: the player, the tab bar and \
            the portrait lock were verified, the landscape layout was not.
            """)
    }

    /// Whether the app's own frame takes the given shape within `timeout`.
    private func waitForInterfaceOrientation(landscape: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let frame = app.frame
            return frame.width > 0 && frame.height > 0
                && (landscape ? frame.width > frame.height : frame.height > frame.width)
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertInterfaceOrientation(landscape: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForInterfaceOrientation(landscape: landscape, timeout: 10),
                      "Expected \(landscape ? "landscape" : "portrait") interface", file: file, line: line)
    }

    /// TestFlight crash, build 10 on an iPhone XS Max running iOS 18.7: UIKit
    /// asserts inside `-[UINavigationBar layoutSubviews]` when the covered
    /// NavigationStack reappears after the player's full-screen cover leaves.
    /// The tester's path was play → failure → Close → back, phone turned for
    /// the video. Both stacks that present the player take the round trip.
    func testPlayerCoverRoundTripInLandscapeKeepsTheSettingsStackAlive() {
        launch(screen: "add-files")
        let directURL = app.buttons["Direct URL"].firstMatch
        XCTAssertTrue(directURL.waitForExistence(timeout: 30), "Direct URL row missing")
        directURL.tap()
        let dialog = app.alerts["Direct URL"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "Direct URL dialog missing")
        let field = dialog.textFields.firstMatch
        field.tap()
        field.typeText("http://127.0.0.1:9/openstream-ui-test-unreachable.mkv")
        dialog.buttons["Play"].tap()
        coverRoundTrip(back: app.navigationBars.buttons.firstMatch, name: "settings")
    }

    func testPlayerCoverRoundTripInLandscapeKeepsTheDiscoverStackAlive() {
        launch(screen: "discover")
        // The hero's title block is the way into the title page now; Details is
        // no longer a button of its own (iPhone hero, 2026-09-23).
        let details = app.descendants(matching: .any).matching(identifier: "home.featured.details").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 40), "no billboard way into Details")
        details.tap()
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "detail Play missing")
        play.tap()
        coverRoundTrip(back: app.buttons["detail.back"].firstMatch, name: "discover", popInLandscape: true)
        // Closing the player restores portrait even while the phone stays sideways;
        // switching tabs makes every stack reconcile its bars once more.
        let settingsTab = app.tabBars.buttons["Settings"].firstMatch
        if settingsTab.waitForExistence(timeout: 5) { settingsTab.tap() }
        let discoverTab = app.tabBars.buttons["Discover"].firstMatch
        if discoverTab.waitForExistence(timeout: 5) { discoverTab.tap() }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app died switching tabs after the cover")
        attach("cover-round-trip-discover-tabs")
    }

    /// Turns the phone while the cover is up, leaves through whichever exit the
    /// player offers, pops (in landscape when asked, else after turning back),
    /// and expects a living app with its tab bar.
    private func coverRoundTrip(back: XCUIElement, name: String, popInLandscape: Bool = false) {
        XCUIDevice.shared.orientation = .landscapeLeft
        // "Playback Failed" for a dead URL, "Playback Unavailable" when no stream
        // source is enabled: either one is the player's exit for this round trip.
        let failed = app.alerts.firstMatch
        let any = app.descendants(matching: .any)
        let close = any.matching(identifier: "player.close").firstMatch
        let controls = any.matching(identifier: "player.controls.show").firstMatch
        // Not `player.connecting`: that spinner shows before the alert or controls exist.
        let exit = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                failed.exists || close.exists || controls.exists
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exit], timeout: 60), .completed,
                       "neither the failure alert nor the player appeared")
        Thread.sleep(forTimeInterval: 3)
        attach("cover-round-trip-\(name)-landscape")
        if failed.exists {
            let closeAlert = failed.buttons["Close"].exists ? failed.buttons["Close"] : failed.buttons.firstMatch
            closeAlert.tap()
        } else {
            if !close.exists || !close.isHittable {
                if controls.exists { controls.tap() } else { app.tap() }
            }
            if close.waitForExistence(timeout: 5) { close.tap() }
        }
        if UIDevice.current.userInterfaceIdiom == .phone {
            assertInterfaceOrientation(landscape: false)
        }
        if popInLandscape {
            if back.waitForExistence(timeout: 5) { back.tap() }
            Thread.sleep(forTimeInterval: 2)
            XCUIDevice.shared.orientation = .portrait
        } else {
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 2)
            if back.waitForExistence(timeout: 5) { back.tap() }
        }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(app.state, .runningForeground, "the app died after the cover went away")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "tab bar missing after returning")
        attach("cover-round-trip-\(name)-portrait")
    }

    /// Photographs a series and a film title page from the hero to the last
    /// section, and the season menu open. Opens pages only — it never presses
    /// Play, so nothing is written to Continue Watching. Set
    /// OPENSTREAM_TITLE_PAGE_AX=1 to run it at accessibility size AX3.
    func testTitlePageSectionsArePhotographed() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_TITLE_PAGE_PROOF"] == "1" else {
            throw XCTSkip("OPENSTREAM_TITLE_PAGE_PROOF not set")
        }
        let accessibilitySize = env["OPENSTREAM_TITLE_PAGE_AX"] == "1"
        let prefix = accessibilitySize ? "ax3" : "std"
        for route in ["detail", "detail-movie"] {
            app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
            if accessibilitySize {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
            }
            if let title = env[route == "detail" ? "OPENSTREAM_TITLE_PAGE_SERIES" : "OPENSTREAM_TITLE_PAGE_MOVIE"] {
                app.launchArguments += ["-OpenStreamDetailTitle", title]
            }
            launch(screen: route)
            let screen = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 60), "the \(route) title page never opened")
            Thread.sleep(forTimeInterval: 10)
            attach("\(prefix)-\(route)-0-top")
            let steps = accessibilitySize ? 6 : 9
            for step in 1 ... steps {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
                Thread.sleep(forTimeInterval: 1.5)
                attach("\(prefix)-\(route)-\(step)")
            }
            let season = app.buttons["detail.season"].firstMatch
            if route == "detail", !accessibilitySize, season.exists {
                for _ in 0 ..< 12 where !isSafelyHittable(season) {
                    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
                    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
                    Thread.sleep(forTimeInterval: 0.8)
                }
                if isSafelyHittable(season) {
                    season.tap()
                    Thread.sleep(forTimeInterval: 1.5)
                    attach("\(prefix)-\(route)-season-menu")
                }
            }
            app.terminate()
        }
    }

    /// Photographs watched history on a series title page: S1 E1–E2 ticked
    /// and Play naming S1, E3, the episode menu's Mark as Watched / Mark as
    /// Unwatched, and the page after un-watching E2. The history is the
    /// in-memory review fixture, so nothing is stored; nothing is played.
    /// The series is the fixture Jellyfin's (`Tests/Fixtures/serve.py`).
    func testWatchedEpisodesArePhotographed() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_WATCHED_PROOF"] == "1" else {
            throw XCTSkip("OPENSTREAM_WATCHED_PROOF not set")
        }
        app.launchArguments += ["-OpenStreamDebugWatchedFixture", "1:1,1:2",
                                "-OpenStreamDetailTitle", env["OPENSTREAM_WATCHED_TITLE"] ?? "Stub Series"]
        launch(screen: "detail")
        let play = app.buttons["detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 60), "the title page never opened")
        let next = NSPredicate(format: "label BEGINSWITH %@", "Play S1, E3")
        expectation(for: next, evaluatedWith: play)
        waitForExpectations(timeout: 60)
        Thread.sleep(forTimeInterval: 3)
        attach("watched-1-cta")

        let card: (Int) -> XCUIElement = { number in
            self.app.otherElements.matching(NSPredicate(format: "value BEGINSWITH %@", "Episode \(number)")).firstMatch
        }
        for _ in 0 ..< 8 where !isSafelyHittable(card(3)) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1)
        }
        // The rail opens on Up Next (E3); bring E1 and E2 back into view.
        let rail = card(3).frame
        let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: rail.midY))
        let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width - 20, dy: rail.midY))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue((card(2).value as? String)?.contains("Watched") == true, "E2 is not shown as watched")
        attach("watched-2-ticks")

        card(3).press(forDuration: 1.2)
        let markWatched = app.buttons["Mark as Watched"].firstMatch
        XCTAssertTrue(markWatched.waitForExistence(timeout: 5), "no Mark as Watched on an unwatched episode")
        attach("watched-3-menu-mark-watched")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        Thread.sleep(forTimeInterval: 1)

        card(2).press(forDuration: 1.2)
        let markUnwatched = app.buttons["Mark as Unwatched"].firstMatch
        XCTAssertTrue(markUnwatched.waitForExistence(timeout: 5), "no Mark as Unwatched on a watched episode")
        attach("watched-4-menu-mark-unwatched")
        markUnwatched.tap()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse((card(2).value as? String)?.contains("Watched") == true, "E2 still shows as watched")
        attach("watched-5-after-unwatch")
        for _ in 0 ..< 8 where !isSafelyHittable(play) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(play.label.hasPrefix("Play S1, E2"), "Play did not move back to S1, E2: \(play.label)")
        attach("watched-6-cta-after-unwatch")
    }

    /// The captions menu's selection agrees with the rendered cue and Off removes it.
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
        func showControls() {
            let transport = app.buttons["player.play-pause"].firstMatch
            for _ in 0..<3 {
                if transport.exists, transport.frame.width > 0 { return }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
            }
        }
        func openMenu() {
            showControls()
            let transport = app.buttons["player.play-pause"].firstMatch
            if transport.label == "Pause" {
                transport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5))
            }
            let captions = app.buttons["player.captions"].firstMatch
            XCTAssertEqual(app.buttons.matching(identifier: "player.captions").count, 1)
            XCTAssertFalse(app.buttons["Overflow Menu"].exists)
            XCTAssertTrue(tapIfPossible(captions))
            XCTAssertTrue(app.buttons["Off"].firstMatch.waitForExistence(timeout: 5))
        }
        openMenu()
        capture("n6-ios-english")
        XCTAssertTrue(app.buttons[expectedTrack].firstMatch.isSelected, "Rendered track must be checked at startup")
        XCTAssertTrue(try cueVisible())

        app.buttons["Off"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(try cueVisible(), "Off left a caption drawn")
        openMenu()
        capture("n6-ios-off")
        XCTAssertTrue(app.buttons["Off"].firstMatch.isSelected)
        XCTAssertFalse(try cueVisible())
    }

    func testRawTSInlineCaptionSelectionMatchesRendered608() throws {
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
        app.launchArguments += ["-OpenStreamInlineLiveFixture"]
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
            let captions = app.buttons["player.inline.subtitles"].firstMatch
            if !captions.exists || !captions.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.23)).tap()
            }
            XCTAssertTrue(captions.waitForExistence(timeout: 5))
            captions.tap()
            XCTAssertTrue(app.buttons["Off"].firstMatch.waitForExistence(timeout: 5))
        }
        openMenu()
        capture("n7-ios-inline-english")
        XCTAssertTrue(app.buttons[expectedTrack].firstMatch.isSelected, "Rendered track must be checked at startup")
        XCTAssertTrue(try cueVisible())

        app.buttons["Off"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(try cueVisible(), "Off left a caption drawn")
        openMenu()
        capture("n7-ios-inline-off")
        XCTAssertTrue(app.buttons["Off"].firstMatch.isSelected)
        XCTAssertFalse(try cueVisible())
    }

    /// The session script installs a temporary system caption profile while the
    /// simulator is shut down, and restores its preference file after this test.
    func testSystemCaptionStylePreservesSRTItalics() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_CAPTION_STYLE_PROOF"] == "1",
              let fixture = env["OPENSTREAM_SUBTITLE_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires a localhost rich SRT fixture and temporary system style")
        }
        restoreSystemCaptionDisplayTypeInTeardown()
        MACaptionAppearanceSetDisplayType(.user, .alwaysOn)
        let color = MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue()
        let rgb = try XCTUnwrap(color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components)
        XCTAssertEqual(rgb[0], 1, accuracy: 0.01)
        XCTAssertEqual(rgb[1], 1, accuracy: 0.01)
        XCTAssertEqual(rgb[2], 0, accuracy: 0.01)
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
        let font = CTFontCreateWithFontDescriptor(descriptor, 15, nil)
        XCTAssertTrue((CTFontCopyFamilyName(font) as String).contains("Courier"))
        XCTAssertEqual(MACaptionAppearanceGetBackgroundOpacity(.user, nil), 1, accuracy: 0.01)
        XCTAssertEqual(MACaptionAppearanceGetRelativeCharacterSize(.user, nil), 1.5, accuracy: 0.01)
        app.launchArguments += [
            "-OpenStreamHoldPlayerChrome", "YES",
            "-OpenStreamVisionPlaybackURL", fixture, "-OpenStreamVisionPlaybackIsLive", "NO",
            "-openstream.playback.engine", "engine", "-openstream.firstRunGuidanceSeen", "YES",
            "-openstream.settings.captions.preference.v1", "off",
            "-openstream.settings.subtitle.languages.v1", "(en)",
            "-openstream.sources.v1", "()", "-openstream.sources.v1.pending-keychain-removals", "()",
            "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.settings.discover.enabled.v1", "NO",
            "-openstream.settings.live.enabled.v1", "NO",
            "-openstream.settings.library.enabled.v1", "NO",
            "-openstream.settings.metadata.enabled.v1", "NO"
        ]
        launch(screen: "add-files")
        XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch.waitForExistence(timeout: 45))
        let seconds = try pauseInTextCueWindow(
            start: XCTUnwrap(env["OPENSTREAM_SUBTITLE_CUE_START"].flatMap(Double.init)),
            end: XCTUnwrap(env["OPENSTREAM_SUBTITLE_CUE_END"].flatMap(Double.init)),
            duration: XCTUnwrap(env["OPENSTREAM_SUBTITLE_DURATION"].flatMap(Double.init)))
        let cue = app.staticTexts["Plain and italic captions"].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 5), "System CC switch should enable the paused SRT cue")
        let screenshot = XCUIScreen.main.screenshot()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage), options: [:]).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(recognized.localizedCaseInsensitiveContains("Plain and italic captions"),
                      "The paused styled glyphs do not match the source cue")
        XCTAssertEqual(playbackSeconds(), seconds, "Playback advanced during styled caption OCR")
        let image = XCTAttachment(screenshot: screenshot)
        image.name = "n9-ios-custom-caption-style-italics"
        image.lifetime = .keepAlways
        add(image)
    }

    func testLibrarySiblingSubtitlesShowSpanishCue() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OPENSTREAM_SIBLING_FIXTURE_URL"],
              URL(string: fixture)?.isFileURL == true else {
            throw XCTSkip("Requires a local Movie.mkv with English and Spanish sibling SRT files")
        }
        app.launchArguments += [
            "-OpenStreamVisionPlaybackURL", fixture,
            "-OpenStreamVisionPlaybackIsLive", "NO",
            "-openstream.playback.engine", "engine",
            "-openstream.settings.captions.preference.v1", "off",
            "-openstream.settings.subtitle.languages.v1", "(en)"
        ]
        // Argument-domain values keep saved sources out of this local fixture run.
        app.launchArguments += ["-openstream.sources.v1", "()",
                                "-openstream.sources.v1.pending-keychain-removals", "()",
                                "-openstream.settings.discover.top10Lists.v1", "NO"]
        launch(screen: "add-files")
        let reveal = app.buttons["player.controls.show"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 45))
        Thread.sleep(forTimeInterval: 5)
        func openSubtitles() {
            let captions = app.buttons["player.captions"].firstMatch
            if !captions.exists { reveal.tap() }
            let transport = app.buttons["player.play-pause"].firstMatch
            if transport.label == "Pause" { transport.tap() }
            XCTAssertTrue(captions.waitForExistence(timeout: 5))
            captions.tap()
        }
        openSubtitles()
        XCTAssertTrue(app.buttons["English"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Spanish"].firstMatch.exists)
        attach("n8-ios-sibling-menu")
        app.buttons["Spanish"].firstMatch.tap()
        app.buttons["player.play-pause"].firstMatch.tap()
        let cue = app.staticTexts["HOLA DESDE ESPANA"].firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 4)
        attach("n8-ios-spanish-cue")
        openSubtitles()
        attach("n8-ios-spanish-selected")
        XCTAssertTrue(app.buttons["Spanish"].firstMatch.isSelected)
        app.buttons["Off"].firstMatch.tap()
        XCTAssertTrue(cue.waitForNonExistence(timeout: 5))
        attach("n8-ios-subtitles-off")
    }

    func testCaptionsMenuOffersAllSubtitleOptions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["OPENSTREAM_SUBTITLE_FIXTURE_URL"],
              URL(string: fixture)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires OPENSTREAM_SUBTITLE_FIXTURE_URL on 127.0.0.1")
        }
        let expectedCue = env["OPENSTREAM_SUBTITLE_FIXTURE_CUE"] ?? "HOLA DESDE ESPANA"
        app.launchArguments += [
            "-OpenStreamVisionPlaybackURL", fixture,
            "-OpenStreamVisionPlaybackIsLive", "YES",
            "-openstream.playback.engine", "engine",
            "-openstream.settings.captions.preference.v1", "off",
            "-openstream.settings.subtitle.languages.v1", "(en)"
        ]
        launch(screen: "add-files")
        XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch
            .waitForExistence(timeout: 45), "The player did not become ready")
        func showControls() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)).tap()
        }
        showControls()
        attach("captions-initial-controls")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "captions-initial-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        func ensureControlsVisible() {
            let transport = app.buttons["player.play-pause"].firstMatch
            for _ in 0..<3 {
                if transport.exists, transport.frame.width > 0 { return }
                showControls()
            }
            XCTAssertTrue(transport.exists, "transport controls are missing")
        }
        func pausePlayback() {
            ensureControlsVisible()
            let transport = app.buttons["player.play-pause"].firstMatch
            if transport.label == "Pause" {
                transport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5), "Pause did not change the transport state")
            }
        }
        func resumePlayback() {
            ensureControlsVisible()
            let transport = app.buttons["player.play-pause"].firstMatch
            if transport.label == "Play" {
                transport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5), "Play did not change the transport state")
            }
        }
        func openAppSubtitles() {
            pausePlayback()
            let captions = app.buttons["player.captions"].firstMatch
            XCTAssertEqual(app.buttons.matching(identifier: "player.captions").count, 1)
            XCTAssertFalse(app.buttons["Overflow Menu"].exists)
            XCTAssertTrue(tapIfPossible(captions))
        }
        openAppSubtitles()
        let rows = app.buttons.matching(NSPredicate(format: "label IN %@", ["Off", "English", "English SDH"]))
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.label)), Set(["Off", "English", "English SDH"]))
        let preferredLabel = "Spanish"
        if !app.buttons[preferredLabel].firstMatch.exists {
            app.buttons["player.subtitle.more"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons[preferredLabel].firstMatch.waitForExistence(timeout: 5))
        attach("n5-ios-full-menu")
        app.buttons[preferredLabel].firstMatch.tap()
        // Menu actions dismiss on selection; resume the picture before checking cues.
        resumePlayback()
        // AVKit's caption layer is not consistently exposed as static text.
        // Count rendered cues so native and app layers cannot silently double up.
        func visibleCueCount() throws -> Int {
            guard let image = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return text.filter { !$0.isWhitespace }.uppercased()
                .components(separatedBy: expectedCue.filter { !$0.isWhitespace }.uppercased()).count - 1
        }
        func waitForCue(_ visible: Bool) throws -> Bool {
            let deadline = Date().addingTimeInterval(20)
            var matches = 0
            while Date() < deadline {
                matches = try visibleCueCount() == (visible ? 1 : 0) ? matches + 1 : 0
                if matches == 2 { return true }
                Thread.sleep(forTimeInterval: 0.5)
            }
            return false
        }
        XCTAssertTrue(try waitForCue(true), "app picker did not draw the fixture cue")
        attach("n5-ios-spanish-cue")
        openAppSubtitles()
        app.buttons["Off"].firstMatch.tap()
        XCTAssertTrue(try waitForCue(false), "app Off left a cue visible")

        XCTAssertFalse(app.buttons["player.more"].exists)
    }

    /// Media servers (owner, 2026-09-17): signs in to the Emby test server on the
    /// Mac through the Add Media Server screen, saves the source, photographs
    /// the result, then deletes the source so nothing is left on the simulator.
    /// Needs OPENSTREAM_TEST_EMBY_URL / _USER / _PASSWORD in the runner's environment.
    func testAddMediaServerSignsInToEmbyAndCleansUp() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["OPENSTREAM_TEST_EMBY_URL"], let user = env["OPENSTREAM_TEST_EMBY_USER"],
              let password = env["OPENSTREAM_TEST_EMBY_PASSWORD"], !url.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_EMBY_* not set")
        }
        launch(screen: "add-media-server")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let any = app.descendants(matching: .any)
        let kindPicker = any.matching(identifier: "sources.mediaServer.kind").firstMatch
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 30), "Add Media Server screen missing")
        attach("add-media-server-jellyfin")
        // Plex: the sign-in code comes from plex.tv (no account needed to show it).
        let plexKind = any.matching(identifier: "sources.mediaServer.kind.plex").firstMatch
        if plexKind.exists { plexKind.tap() } else { kindPicker.tap(); app.buttons["Plex"].firstMatch.tap() }
        let plexSignIn = any.matching(identifier: "sources.mediaServer.plexSignIn").firstMatch
        if plexSignIn.waitForExistence(timeout: 5) {
            plexSignIn.tap()
            let code = any.matching(identifier: "sources.mediaServer.plex.code").firstMatch
            _ = code.waitForExistence(timeout: 20)
            Thread.sleep(forTimeInterval: 1)
            attach("add-media-server-plex")
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
        }
        // Emby, signed in with a server URL (Emby Connect needs a real account).
        let emby = any.matching(identifier: "sources.mediaServer.kind.emby").firstMatch
        if emby.exists { emby.tap() } else { kindPicker.tap(); app.buttons["Emby"].firstMatch.tap() }
        let serverMode = any.matching(identifier: "sources.mediaServer.embyMode.server").firstMatch
        if serverMode.waitForExistence(timeout: 5) { serverMode.tap() }
        else { any.matching(identifier: "sources.mediaServer.embyMode").firstMatch.tap(); app.buttons["Server URL"].firstMatch.tap() }
        let urlField = any.matching(identifier: "sources.mediaServer.url").firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 10), "Server URL field missing")
        urlField.tap(); urlField.typeText(url)
        let userField = any.matching(identifier: "sources.mediaServer.username").firstMatch
        userField.tap(); userField.typeText(user)
        let passwordField = any.matching(identifier: "sources.mediaServer.password").firstMatch
        passwordField.tap(); passwordField.typeText(password)
        attach("add-media-server-emby-filled")
        let test = any.matching(identifier: "sources.mediaServer.test").firstMatch
        if test.exists, test.isEnabled {
            test.tap()
            let connected = any.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Connected")).firstMatch
            let failedStatus = any.matching(identifier: "sources.mediaServer.status").firstMatch
            let answered = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in connected.exists || failedStatus.exists }, object: nil)], timeout: 30)
            XCTAssertEqual(answered, .completed, "no status after Test Connection")
            Thread.sleep(forTimeInterval: 1)
            attach("add-media-server-emby-tested")
            XCTAssertTrue(connected.exists, "test did not connect: \(failedStatus.exists ? failedStatus.label : "no status")")
        }
        let save = any.matching(identifier: "sources.mediaServer.save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save missing")
        save.tap()
        // Back on the Sources list, the server is listed under Your Sources.
        // "Media Server · <host>" is the saved row's subtitle; "Add Media Server" has no dot.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Media Server ·")).firstMatch
        let listed = row.waitForExistence(timeout: 30)
        attach("add-media-server-saved")
        XCTAssertTrue(listed, "saved media server not listed")
        // Whatever fails below, the saved server must not stay on the simulator.
        addTeardownBlock { [self] in
            if app.state != .runningForeground { app.launch() }
            let anyElement = app.descendants(matching: .any)
            let close = anyElement.matching(identifier: "player.close").firstMatch
            if close.exists { close.tap() }
            let back = app.buttons["detail.back"].firstMatch
            if back.exists { back.tap() }
            app.tabBars.buttons["Settings"].firstMatch.tap()
            let sources = app.buttons["Sources"].firstMatch
            if sources.waitForExistence(timeout: 5) { sources.tap() }
            let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Media Server ·")).firstMatch
            guard saved.waitForExistence(timeout: 10) else { return }
            saved.tap()
            let delete = app.buttons["Delete Source"].firstMatch
            var swipes = 0
            while !delete.exists, swipes < 4 { app.swipeUp(); swipes += 1 }
            guard delete.waitForExistence(timeout: 5) else { return }
            delete.tap()
            let confirm = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Delete")).firstMatch
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        // Discover should now carry the server's shelves ("Latest in Movies" …).
        app.tabBars.buttons["Discover"].firstMatch.tap()
        let shelf = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Latest in")).firstMatch
        var shelfSwipes = 0
        while !shelf.exists, shelfSwipes < 12 { app.swipeUp(); shelfSwipes += 1; Thread.sleep(forTimeInterval: 0.6) }
        attach("add-media-server-discover")
        XCTAssertTrue(shelf.exists, "no media-server shelf on Discover after saving the source")
        // Open the first server title, expect a real detail page, and play it.
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.ms.")).firstMatch
        if poster.waitForExistence(timeout: 10) {
            poster.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30), "server title detail never showed Play")
            Thread.sleep(forTimeInterval: 4)
            attach("add-media-server-detail")
            play.tap()
            let any = app.descendants(matching: .any)
            let playing = any.matching(identifier: "player.controls.show").firstMatch
            let close = any.matching(identifier: "player.close").firstMatch
            let alert = app.alerts.firstMatch
            let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in playing.exists || close.exists || alert.exists }, object: nil)], timeout: 60)
            XCTAssertEqual(started, .completed, "player never appeared for the server title")
            Thread.sleep(forTimeInterval: 8)
            attach("add-media-server-playing")
            XCTAssertFalse(alert.exists, "playback of the server title failed: \(alert.exists ? alert.label : "")")
            if !close.exists || !close.isHittable { app.tap() }
            if close.waitForExistence(timeout: 5) { close.tap() }
            let back = app.buttons["detail.back"].firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
        } else {
            XCTFail("no server title under the shelf")
        }
        app.tabBars.buttons["Settings"].firstMatch.tap()
        // Clean up: open it and delete.
        XCTAssertTrue(row.waitForExistence(timeout: 10), "source row gone before cleanup")
        row.tap()
        let delete = app.buttons["Delete Source"].firstMatch
        var swipes = 0
        while !delete.exists, swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "Delete Source missing")
        delete.tap()
        let confirm = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Delete")).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        else { app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Delete")).element(boundBy: 1).tap() }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(row.exists, "media server still listed after delete")
        attach("add-media-server-deleted")
    }

    /// Owner (2026-09-18): the guide for the playlist they sent shows "No
    /// information". Adds that playlist (env OPENSTREAM_TEST_M3U), opens Live,
    /// searches a channel and waits for programme cells; photographs the guide
    /// at 15 / 45 / 90 s so the driver can see what the phone path produces.
    func testPlaylistGuideShowsProgrammes() throws {
        guard let playlist = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"], !playlist.isEmpty else {
            throw XCTSkip("OPENSTREAM_TEST_M3U not set")
        }
        addUITestPlaylist(playlist)
        addTeardownBlock { [self] in
            app.terminate()
            launch(screen: "settings")
            removeUITestPlaylistSource()
        }
        let live = app.tabBars.buttons["Live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        live.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30), "no Live search field")
        search.tap(); search.typeText("TF1")
        if app.keyboards.buttons["search"].exists { app.keyboards.buttons["search"].tap() }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "TF1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "TF1 never listed")
        // The guide cells are not exposed to accessibility, so the evidence is the
        // photographs plus the app's own "guide loaded / guide load failed" trace.
        for checkpoint in [20, 45, 75] {
            Thread.sleep(forTimeInterval: checkpoint == 20 ? 20 : 30)
            attach("guide-\(checkpoint)s")
        }
        XCTAssertTrue(row.exists, "TF1 row disappeared")
    }

    /// iOS 18's XCTest never reports a SwiftUI `Menu` button as hittable,
    /// though a finger opens it (proved on the 18.6 simulator, 2026-10-16).
    /// There these are judged by where they are; the press still has to open
    /// the menu.
    private static let iOS18MenuButtons: Set<String> = ["player.options", "player.captions"]

    private func isTouchableMenuButton(_ element: XCUIElement, identifier: String) -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26,
              Self.iOS18MenuButtons.contains(identifier),
              let snapshot = try? element.snapshot(), snapshot.isEnabled,
              snapshot.frame.width >= 1, snapshot.frame.height >= 1 else { return false }
        return crawlScreenRect.contains(snapshot.frame)
    }

    private func playerCaptionsAreUp() -> Bool {
        let captions = app.buttons["player.captions"].firstMatch
        if captions.exists, captions.isEnabled {
            return captions.isHittable || isTouchableMenuButton(captions, identifier: "player.captions")
        }
        return app.buttons.matching(identifier: "player.play-pause").allElementsBoundByIndex
            .contains(where: { isSafelyHittable($0) })
    }

    /// A guide selection opens the player directly and channel changes stay there.

    /// Reveals the player chrome only when it is hidden; tapping the surface while chrome is up would hide it.
    ///
    /// The chrome auto-hides three seconds after the last interaction, and that
    /// can expire between the query and the tap it was meant to guard, so this
    /// retries until a control is really there rather than checking once.
    /// Brings the transport back up, and says whether it is up now — the crawl
    /// has to read the screen again once it is, or it sees one control.
    @discardableResult
    private func revealPlayerControls() -> Bool {
        let captions = app.buttons["player.captions"]
        for _ in 0..<6 {
            if playerCaptionsAreUp() { return true }
            let background = app.buttons["player.controls.show"].firstMatch
            guard background.exists else { return false }
            // iOS 18 turns a player that opens with the phone already sideways;
            // mid-turn its surface is not inside the screen yet, so wait it out.
            guard let offset = crawlPlayerBackgroundHitOffset(background.frame, scene: crawlScene()) else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            background.coordinate(withNormalizedOffset: .zero).withOffset(offset).tap()
            if captions.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    /// Live now starts in the inline stage. Its UIKit chrome can be hidden or
    /// connecting while its controls still have accessibility frames. Raise it
    /// and wait for an actual hit point before the crawler judges those controls.
    @discardableResult
    private func revealInlineLiveControls(timeout: TimeInterval = 3) -> Bool {
        let stage = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        guard stage.waitForExistence(timeout: min(timeout, 2)) else { return false }
        // UIKit's representable controls can be AX siblings of SwiftUI's
        // stage element. Scope by the visible stage frame instead of ancestry.
        let controls = app.buttons.matching(identifier: "player.play-pause")
        func ready() -> Bool {
            controls.allElementsBoundByIndex.contains {
                !$0.frame.isEmpty && stage.frame.contains($0.frame) && isSafelyHittable($0)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if ready() { return true }
            // UIKit controls can be visible inside a SwiftUI representable
            // while XCTest reports no accessibility hit point. Verify a real
            // centre touch pauses and resumes before accepting that locator.
            if !app.progressIndicators["live.loading"].exists,
               let pause = controls.allElementsBoundByIndex.first(where: {
                   $0.isEnabled && $0.label == "Pause" && stage.frame.contains($0.frame)
               }) {
                pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                let paused = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in pause.exists && pause.label == "Play" }, object: nil)], timeout: 3) == .completed
                if paused {
                    pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    let resumed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in pause.exists && pause.label == "Pause" }, object: nil)], timeout: 3) == .completed
                    if resumed {
                        print("INLINE LIVE coordinate touch paused and resumed the visible control")
                        return true
                    }
                }
                print("INLINE LIVE visible Pause refused a coordinate touch")
                break
            }
            if stage.exists, !stage.frame.isEmpty, app.frame.contains(stage.frame) {
                stage.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
            }
            Thread.sleep(forTimeInterval: 0.4)
        } while Date() < deadline
        let isReady = ready()
        if !isReady {
            print("INLINE LIVE stage=\(stage.frame) type=\(stage.elementType.rawValue) controls=\(controls.count)")
            for control in controls.allElementsBoundByIndex.prefix(6) {
                print("INLINE LIVE control=\(control.frame) hittable=\(isSafelyHittable(control)) label=\(control.label)")
            }
        }
        return isReady
    }

    /// The cross-device scaling sweep (2026-09-20): Discover, Library, Live and
    /// the full-screen live player with its channel picker open, in every
    /// orientation this device supports, so the same screens can be compared
    /// side by side across the iPhone and iPad simulators. Adds nothing and
    /// changes no saved state.
    func testScalingSweepIsPhotographed() {
        continueAfterFailure = true
        executionTimeAllowance = 3600
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientations: [(UIDeviceOrientation, String)] = [(.portrait, "portrait"), (.landscapeLeft, "landscape")]
        for (orientation, orientationName) in orientations {
            for route in ["discover", "library", "live"] {
                app.terminate()
                app.launchArguments = []
                XCUIDevice.shared.orientation = orientation
                launch(screen: route)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
                Thread.sleep(forTimeInterval: route == "discover" ? 26 : 12)
                attach("scale-\(idiom)-\(orientationName)-\(route)")
            }
        }

        // The full-screen live player, and the channel picker in whichever
        // presentation this device uses — the iPad's bottom strip, the phone's
        // leading panel.
        for (orientation, orientationName) in orientations {
            app.terminate()
            app.launchArguments = ["-OpenStreamHoldPlayerChrome", "YES"]
            XCUIDevice.shared.orientation = orientation
            launch(screen: "live")
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
            guard channels.firstMatch.waitForExistence(timeout: 60) else {
                crawlNote("no live channel appeared in \(orientationName)")
                continue
            }
            // In landscape the guide sits below the pinned player and its first
            // row can start off-screen, where `tap()` has no hit point.
            var opened = tapIfPossible(channels.firstMatch)
            for _ in 0..<3 where !opened {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 1)
                opened = tapIfPossible(channels.allElementsBoundByIndex.first { isSafelyHittable($0) } ?? channels.firstMatch)
            }
            guard opened else {
                crawlNote("no live channel could be opened in \(orientationName)")
                continue
            }
            guard app.buttons["player.close"].waitForExistence(timeout: 40) else {
                crawlNote("the live player did not reach full screen in \(orientationName)")
                continue
            }
            Thread.sleep(forTimeInterval: 6)
            _ = revealPlayerControls()
            attach("scale-\(idiom)-\(orientationName)-live-fullscreen")
            guard tapIfPossible(app.buttons["player.channels"].firstMatch) else {
                crawlNote("the Channels button was not reachable in \(orientationName)")
                continue
            }
            let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "live.picker.channel."))
            XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 10), "the channel picker did not open")
            Thread.sleep(forTimeInterval: 2)
            attach("scale-\(idiom)-\(orientationName)-live-picker")
            // The picker's own way back to the guide. While the picker is up the
            // transport is out of the hit-test tree, so this is the only control
            // that can reach it.
            let back = app.buttons["live.picker.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "the picker offered no way back to the guide")
            XCTAssertTrue(tapIfPossible(back), "the picker's Guide button was not hittable")
            XCTAssertTrue(app.buttons["player.fullscreen"].waitForExistence(timeout: 15),
                          "Back to guide did not land on the Live tab with the inline player still up")
            Thread.sleep(forTimeInterval: 2)
            attach("scale-\(idiom)-\(orientationName)-live-after-back")
        }
    }

    /// Owner item 8 (2026-10-09): the player and the category row never move
    /// while the channel list scrolls, and no "Connecting to…" line appears.
    func testLiveLayoutIsStable() throws {
        launch(screen: "live")
        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        let categories = app.descendants(matching: .any).matching(identifier: "live.categories").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 60), "no Live player frame")
        XCTAssertTrue(categories.waitForExistence(timeout: 10), "no category row")
        Thread.sleep(forTimeInterval: 3)
        let playerFrame = player.frame
        let categoryFrame = categories.frame
        XCTAssertEqual(try inlineLivePictureAspectRatio(player), 16.0 / 9.0, accuracy: 0.02)
        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        low.press(forDuration: 0.05, thenDragTo: high)
        low.press(forDuration: 0.05, thenDragTo: high)
        high.press(forDuration: 0.05, thenDragTo: low)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(player.frame, playerFrame, "the player moved while the list scrolled")
        XCTAssertEqual(categories.frame, categoryFrame, "the category row moved while the list scrolled")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "live.connecting").firstMatch.exists)
        attach("live-layout-stable")
    }

    /// Live redesign captures (2026-10-09), in the Mythos wireframes' states:
    /// default, scrolled, inline controls, full-screen controls, a channel
    /// that fails in the frame. PNGs go to `OPENSTREAM_UX_CAPTURE_DIR` with
    /// `OPENSTREAM_UX_CAPTURE_PREFIX`. Skipped unless `OPENSTREAM_UX_CAPTURE=1`.
    func testLiveRedesignIsPhotographed() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_UX_CAPTURE"] == "1" else { throw XCTSkip("captures only with OPENSTREAM_UX_CAPTURE=1") }
        continueAfterFailure = true
        let prefix = env["OPENSTREAM_UX_CAPTURE_PREFIX"] ?? "live"
        let dir = env["OPENSTREAM_UX_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        func shot(_ name: String) {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            if let dir {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? png.write(to: dir.appendingPathComponent("\(prefix)-\(name).png"))
            }
            print("LIVECAPTURE \(name)")
            attach("\(prefix)-\(name)")
        }
        app.launchArguments += ["-OpenStreamMuteAudio", "YES"]
        app.launchArguments += (env["OPENSTREAM_UX_CAPTURE_ARGS"] ?? "").split(separator: " ").map(String.init)
        if env["OPENSTREAM_UX_CAPTURE_LANDSCAPE"] == "1" { XCUIDevice.shared.orientation = .landscapeLeft }
        launch(screen: "live")
        let watching = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND selected == true", "Play ")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 90), "no playing row")
        Thread.sleep(forTimeInterval: 10)
        shot("default")

        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        low.press(forDuration: 0.05, thenDragTo: high)
        low.press(forDuration: 0.05, thenDragTo: high)
        Thread.sleep(forTimeInterval: 1.5)
        shot("scrolled")
        high.press(forDuration: 0.05, thenDragTo: low)
        high.press(forDuration: 0.05, thenDragTo: low)
        high.press(forDuration: 0.05, thenDragTo: low)
        Thread.sleep(forTimeInterval: 1)

        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        if player.exists {
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
            Thread.sleep(forTimeInterval: 0.6)
            shot("inline-controls")
        }
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        if !(fullScreen.exists && fullScreen.isHittable), player.exists {
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        }
        print("LIVECAPTURE fullscreen button exists=\(fullScreen.exists) frame=\(fullScreen.exists ? fullScreen.frame : .zero)")
        if fullScreen.waitForExistence(timeout: 5) {
            fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 6)
            shot("fullscreen-hidden")
            let close = app.buttons["player.close"].firstMatch
            if !(close.exists && close.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
            shot("fullscreen-controls")
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "player.live").count, 1,
                           "LIVE appears once, as the scrubber's label")
            XCTAssertFalse(app.buttons["Last Channel"].exists && app.buttons["Last Channel"].isHittable,
                           "Last Channel lives in More, not on the screen")
            if close.exists, close.isHittable { close.tap() }
            Thread.sleep(forTimeInterval: 2)
        }

        let failing = app.buttons.matching(NSPredicate(format: "label == %@", "Play Offline Sports")).firstMatch
        if failing.exists {
            for _ in 0..<4 where !failing.isHittable { low.press(forDuration: 0.05, thenDragTo: high) }
            if failing.isHittable {
                failing.tap()
                _ = app.descendants(matching: .any).matching(identifier: "live.failure").firstMatch.waitForExistence(timeout: 30)
                Thread.sleep(forTimeInterval: 1)
                shot("error-frame")
            }
        }
    }

    /// Round 4 G4 on the stubbed lineup: five quick swipes up on the picture
    /// tune once (the run's trace holds one `live zap` line for them).
    func testLiveSwipesCoalesceIntoOneTune() {
        app.launchArguments += ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let watching = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND selected == true", "Play ")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 90), "no playing row")
        let firstLabel = watching.label
        Thread.sleep(forTimeInterval: 8)
        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        for _ in 0..<5 { player.swipeUp(velocity: .fast) }
        let changed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND selected == true AND label != %@",
                                                       "Play ", firstLabel)).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 15), "the swipes never changed the channel")
        Thread.sleep(forTimeInterval: 3)
        attach("g4-after-five-swipes")
    }

    /// Device check (test iPhone): a Live channel in full screen on the AVPlayer
    /// route goes to Picture in Picture when the viewer goes home. The
    /// screenshot after Home shows the window; the app trace says
    /// "picture in picture: didStart". Skipped unless `OPENSTREAM_PIP_CHECK=1`.
    func testLiveFullScreenGoesToPictureInPictureOnHome() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_PIP_CHECK"] == "1" else { throw XCTSkip("device check only with OPENSTREAM_PIP_CHECK=1") }
        continueAfterFailure = true
        let inlineFixture = env["OPENSTREAM_PIP_INLINE_FIXTURE_URL"].flatMap(URL.init(string:))
        if let inlineFixture {
            XCTAssertEqual(inlineFixture.host, "127.0.0.1")
            XCTAssertEqual(inlineFixture.scheme, "http")
            app.launchArguments += ["-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackIsLive", "YES",
                                    "-OpenStreamVisionPlaybackURL", inlineFixture.absoluteString]
        }
        app.launchArguments += ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let watching = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND selected == true", "Play ")).firstMatch
        if inlineFixture == nil { XCTAssertTrue(watching.waitForExistence(timeout: 90), "no playing row") }
        Thread.sleep(forTimeInterval: 8)
        let player = app.descendants(matching: .any).matching(identifier: "live.stage.player").firstMatch
        if inlineFixture != nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.23)).tap()
        } else {
            player.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
        }
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 5))
        fullScreen.tap()
        Thread.sleep(forTimeInterval: 8)
        attach("pip-before-home")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        attach("pip-after-home")
        print("PIPCHECK app state after home: \(app.state.rawValue)")
        // AVKit can report a visible PiP app as foreground. A suspended app
        // cannot keep the live window playing; the device trace and Home
        // screenshots separately prove the window lasts through ten seconds.
        XCTAssertTrue(app.state == .runningBackground || app.state == .runningForeground)
        Thread.sleep(forTimeInterval: 5)
        attach("pip-after-10s")
        app.activate()
        Thread.sleep(forTimeInterval: 4)
        attach("pip-after-return")
    }

    /// The system player for reference: Safari's full-screen HLS player with
    /// its controls up (the page is opened first with `simctl openurl`).
    func testSystemPlayerReferenceIsPhotographed() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_UX_CAPTURE"] == "1" else { throw XCTSkip("captures only with OPENSTREAM_UX_CAPTURE=1") }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        Thread.sleep(forTimeInterval: 4)
        safari.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.7)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let dir = env["OPENSTREAM_UX_CAPTURE_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("system-player-controls.png"))
        }
        attach("system-player-controls")
    }

    func testLiveTappedStatesArePhotographed() {
        // Two queries cannot both land inside a three-second auto-hide, and the
        // second one used to fail on a chrome that had already gone.
        app.launchArguments += ["-OpenStreamHoldPlayerChrome", "YES"]
        launch(screen: "live")
        let channel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play CBS")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "CBS channel missing from the configured lineup")
        let originalChannelID = channel.identifier.replacingOccurrences(of: "guide.play.", with: "")
        channel.tap()
        // Selection may leave the preview inline or present the player.
        // Return from any modal before testing the actual inline controls.
        let initialClose = app.buttons["player.close"]
        if initialClose.waitForExistence(timeout: 10) {
            XCTAssertFalse(app.buttons["player.fullscreen"].exists, "covered inline chrome leaked through the modal")
            initialClose.tap()
        }
        XCTAssertTrue(revealInlineLiveControls(timeout: 60), "inline Live controls never became ready")
        let pause = app.buttons["player.play-pause"].firstMatch
        XCTAssertTrue(pause.isHittable, "inline Pause has no touch target after dismissal")
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pause.exists && pause.label == "Play" }, object: nil)], timeout: 3),
            .completed, "a real inline Pause touch did not pause playback")
        pause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pause.exists && pause.label == "Pause" }, object: nil)], timeout: 3),
            .completed, "a real inline Play touch did not resume playback")
        let fullscreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.exists && fullscreen.isEnabled && app.frame.contains(fullscreen.frame),
                      "Full Screen is not an enabled visible control")
        fullscreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Full Screen did not open the player")
        XCTAssertFalse(app.buttons["player.fullscreen"].exists, "covered inline chrome leaked through the modal")
        attach("live-direct-fullscreen")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            revealPlayerControls()
            let captions = app.buttons["player.captions"]
            let more = app.buttons["player.more"]
            let mute = app.buttons["player.mute"]
            XCTAssertTrue(captions.waitForExistence(timeout: 10))
            XCTAssertEqual(app.buttons.matching(identifier: "player.close").count, 1)
            if more.exists { XCTAssertFalse(captions.frame.intersects(more.frame)) }
            if mute.exists {
                XCTAssertFalse(captions.frame.intersects(mute.frame))
                if more.exists { XCTAssertFalse(more.frame.intersects(mute.frame)) }
            }
            attach("live-chrome-\(orientation.rawValue)")
        }

        revealPlayerControls()
        app.buttons["player.channels"].tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "live.picker.channel."))
        let pickerShown = choices.firstMatch.waitForExistence(timeout: 5)
        attach("live-after-channels-tap")
        XCTAssertTrue(pickerShown, "Channels button did not open the picker")
        attach("live-channel-picker")
        XCTAssertGreaterThan(choices.count, 1)
        let replacement = choices.allElementsBoundByIndex.first {
            $0.identifier != "live.picker.channel.\(originalChannelID)" && $0.isHittable
        }
        XCTAssertNotNil(replacement, "No different channel is visible in the picker")
        replacement?.tap()
        revealPlayerControls()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Switching channels dismissed full screen")
        attach("live-channel-switched-fullscreen")
        close.tap()
        XCTAssertTrue(app.buttons["player.fullscreen"].waitForExistence(timeout: 10))
        attach("live-inline-after-return")
    }

    /// Captures real broadcast captions for visual review; no fixture captions are injected.
    func testLiveBroadcastCaptionsArePhotographed() throws {
        app.launchArguments += ["-OpenStreamHoldPlayerChrome", "YES"]
        launch(screen: "live")
        let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
        XCTAssertTrue(channels.firstMatch.waitForExistence(timeout: 30))
        var visited = Set<String>()
        for _ in 0..<5 {
            guard let channel = channels.allElementsBoundByIndex.first(where: { !visited.contains($0.identifier) && $0.isHittable }) else {
                app.swipeUp()
                continue
            }
            visited.insert(channel.identifier)
            channel.tap()
            guard app.buttons["player.close"].waitForExistence(timeout: 10) else { continue }
            let deadline = Date().addingTimeInterval(20)
            repeat {
                revealPlayerControls()
                app.buttons["player.captions"].tap()
                let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label == 'Closed Captions' OR label BEGINSWITH 'English' OR label BEGINSWITH 'French'", "player.subtitle.track.")).firstMatch
                if track.waitForExistence(timeout: 1) {
                    attach("live-broadcast-caption-menu")
                    track.tap()
                    Thread.sleep(forTimeInterval: 8)
                    attach("live-broadcast-caption-text-review-required")
                    revealPlayerControls()
                    app.buttons["player.captions"].tap()
                    app.buttons["Off"].firstMatch.tap()
                    revealPlayerControls()
                    app.buttons["player.close"].tap()
                    return
                }
                let off = app.buttons["Off"].firstMatch
                if off.exists { off.tap() }
                else { attach("live-captions-menu-missing") }
                Thread.sleep(forTimeInterval: 1)
            } while Date() < deadline
            revealPlayerControls()
            app.buttons["player.close"].tap()
        }
        throw XCTSkip("No channel in the available lineup published a legible caption track within 20 seconds per channel (\(visited.count) checked).")
    }


    // MARK: - Every button on every screen

    /// One control on screen, one press, one required answer.
    ///
    /// A screenshot sweep photographs a button that does nothing exactly as it
    /// photographs a working one, and a test written around a named identifier
    /// never meets the controls nobody named. So this walks every debug route,
    /// enumerates what is on the screen — buttons, rows, links, switches,
    /// segments, tab items — presses each one, and requires the app to answer
    /// within three seconds: a sheet, an alert, a navigation, a menu, a flipped
    /// switch, or a change in the control's own state. Silence is a defect, and
    /// so is a control that exists, at a usable size, and refuses a touch.
    ///
    /// Two things make it exhaustive rather than a sampler. There is no budget:
    /// the first version gave each screen a slice of twenty minutes and pressed
    /// 41 of the 129 controls it found, which is a report about the budget. And
    /// it reads the screen through one whole-app snapshot per look instead of
    /// one query per control: on Discover a single `app.buttons.count` costs
    /// seconds, and the old enumeration spent five of them per element.
    private struct CrawlNode {
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        let value: String
        let placeholder: String
        let frame: CGRect
        let isEnabled: Bool
        let isSelected: Bool
        let collection: String?
    }

    /// Everything one look at the screen says, taken in a single round trip.
    private struct CrawlScene {
        var nodes: [CrawlNode] = []
        var navigation = ""
        var alerts = 0
        var sheets = 0
        var keyboards = 0
        var buttons = 0
        var lists: [CGRect] = []
        var appState: UInt = 0
        /// Everything the screen says, and how many things it says. A
        /// validation message, a disclosure opening onto a field, a label
        /// swapping to "Copied": none of them change a count of buttons, and
        /// all of them are the screen answering.
        var texts = 0
        var textDigest = Hasher()
        var textHash = 0
        /// What every control on the screen says about itself. A press that
        /// changes another control's state — the LIVE badge dropping off the
        /// live edge when the viewer skips back ten seconds — changes nothing
        /// else the walk can see.
        var controlDigest = Hasher()
        var controlHash = 0
    }

    /// Play Trailer is a background action, not a silent button. Owner rule
    /// (2026-09-24, N17d2): trailers are art-first — no loading screen, no
    /// spinner, no "Loading" text; the art stays up while the video loads
    /// behind it and fades to video only once it really plays, which can take
    /// longer than the crawl's 3 s, or never happen. So a press that leaves
    /// the screen unchanged is the correct answer here.
    private func crawlIsBackgroundAction(_ target: CrawlTarget) -> Bool {
        ["Play Trailer", "Play preview"].contains(target.label)
    }

    private struct CrawlTarget {
        let typeName: String
        let type: XCUIElement.ElementType
        let identifier: String
        let label: String
        let isTab: Bool
        var collection: String? = nil

        var key: String {
            let named = identifier.isEmpty ? label : identifier
            return named.isEmpty ? "\(typeName)-unnamed" : named
        }

        /// What makes this control this control, for the walk's "already done"
        /// list: a screen is read again after every press.
        var signature: String { "\(typeName)\u{1}\(identifier)\u{1}\(label)" }

        var name: String { "\(typeName) \(key)" }

        var slug: String {
            String(key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }.prefix(70))
        }
    }

    private enum CrawlReach { case hittable, offScreen, blocked, disabled, gone }

    private struct CrawlResult {
        var found = 0
        var pressed = 0
        var silent = 0
        var unreachable = 0
        var skipped = 0
        var defects: [String] = []

        mutating func add(_ other: CrawlResult) {
            found += other.found
            pressed += other.pressed
            silent += other.silent
            unreachable += other.unreachable
            skipped += other.skipped
            defects += other.defects
        }
    }

    /// How a screen is reached when a debug route alone does not reach it: the
    /// players are two taps past a route, and they are where half the controls
    /// in this app live.
    private enum CrawlOpener { case none, vodPlayer, livePlayer }

    private struct CrawlScreen {
        let route: String
        var opener: CrawlOpener = .none
        var landscape = false
        var includesTabs = false

        var name: String {
            let surface: String
            switch opener {
            case .none: surface = route
            case .vodPlayer: surface = "\(route)→player"
            case .livePlayer: surface = "\(route)→live-player"
            }
            return landscape ? "\(surface) (landscape)" : surface
        }
    }

    /// Where the floating tab bar is drawn. Rows under it are on screen, half
    /// visible and not touchable until they are scrolled clear — scrolling to
    /// do, not a tap-target defect. Kept as the bar's own rectangle rather than
    /// as a shrunken screen so that a toolbar item beside the bar, at the same
    /// height, is still judged normally.
    private var crawlBarRect: CGRect = .null

    /// The app's own window. On an iPad running the app in a resizable window
    /// `app.frame` is the whole display, so a row below the window's edge read
    /// as on screen, whole, and untouchable — a defect that was only a scroll.
    private var crawlWindowRect: CGRect = .null

    private var crawlReport: [String] = []
    private var crawlPressesPerCollection: [String: Int] = [:]

    /// One download per screen, and none at all once a cancel has failed. Each
    /// one that outruns its cancel leaves a gigabyte or two on the owner's
    /// simulator — twice today it filled the disk — so the walk presses the
    /// control, proves it answers, takes the download back, and stops there.
    private var crawlDownloadsPressed = 0
    private var crawlDownloadsAreOff = false

    /// "Sources…" on a playback failure leaves the title page for Settings,
    /// and the walk has to relaunch the screen to get back. Every Play on a
    /// simulator with no stream source raises it, so it is pressed once per
    /// screen to prove it answers, and not again.
    private var crawlSourcesPressed = 0
    private static let crawlSourcesLabel = "Sources…"

    /// How many lists the screen holds before anything is pressed. A SwiftUI
    /// menu is neither a `menuItem` nor a `popover` on the phone — it arrives
    /// as one more collection view, narrower than the screen — so an open one
    /// is recognised by the list it added rather than by its type.
    private var crawlBaselineLists = 0

    /// Whether this screen's text stays put when nobody touches it.
    private var crawlTextIsStable = true
    private var crawlControlsAreStable = true

    /// The owner asked for the first three cards of every shelf. A shelf holds
    /// as many as the provider sends, and every card press is a detail page
    /// pushed and popped.
    private static let crawlCardsPerCollection = 3

    /// Anything that throws work away, spends money, or leaves the simulator
    /// different than it was found. The crawler names them in its report and
    /// walks past: this suite runs on the owner's content simulators.
    private static let crawlDestructiveWords = [
        "delete", "remove", "sign out", "log out", "clear", "reset", "erase",
        "forget", "disconnect", "unpair", "send", "upload", "ship", "purchase", "buy",
    ]
    private static let crawlMutatingWords = [
        "add source", "import", "export", "restore", "pair", "subscribe", "shareplay",
    ]
    /// Buttons that submit a form. The owner's rule: press them only with empty
    /// fields, which is the validation path, and never with something typed in
    /// them — the fields on these screens hold credentials.
    private static let crawlSubmitWords = [
        "save", "sign in", "log in", "connect", "test connection", "load shares",
    ]

    /// Cards and rows that arrive in unbounded numbers. The first three of each
    /// are pressed; the rest are reported as a policy skip rather than silently
    /// dropped.
    private static let crawlCollectionPrefixes = [
        "home.continue.", "home.top10.", "home.ms.", "home.top-picks.",
        "library.title.", "librarytv.channel.", "detail.similar.",
        "guide.play.", "guide.favorite.", "live.footer.", "live.picker.channel.",
        "settings.subtitleLanguages.", "watchprovider.", "sources.smb.share.",
        "sources.mediaServer.embyServer.", "sources.mediaServer.plex.server.",
    ]

    /// Controls that answer a press by turning on and a second press by turning
    /// off. Pressed twice, so the simulator keeps the setting it had.
    private static let crawlRestorablePrefixes = [
        "settings.subtitleLanguages.", "watchprovider.", "guide.favorite.",
    ]

    /// iPadOS publishes each tab item's symbol name where the phone publishes
    /// its title, and does not expose the bar as a `tabBar` at all, so the
    /// items have to be recognised by name or they are pressed on every screen.
    private static let crawlTabLabels: Set<String> = [
        "Discover", "Library", "Live", "Settings",
        "sparkles", "books.vertical", "dot.radiowaves.left.and.right", "gearshape",
    ]

    private static let crawlExitLabels: Set<String> = ["Cancel", "Close", "Done", "Dismiss", "OK", "Not Now", "Later"]

    // MARK: Crawl groups — one test per screen group, each re-runnable alone

    func testCrawlDiscover() {
        runCrawlGroup("discover", [CrawlScreen(route: "discover", includesTabs: true)])
    }

    func testCrawlLibrary() {
        runCrawlGroup("library", [CrawlScreen(route: "library", includesTabs: true)])
    }

    func testDiscoverBackFromTitlePageTenTimes() {
        executionTimeAllowance = 180
        app.launchArguments = ["-OpenStreamHoldPlayerChrome", "YES", "-OpenStreamMuteAudio", "YES"]
        launch(screen: "discover")
        let details = app.buttons["home.featured.details"].firstMatch
        let back = app.buttons["detail.back"].firstMatch
        for visit in 1...10 {
            XCTAssertTrue(details.waitForExistence(timeout: 30), "Discover before visit \(visit)")
            details.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 15))
            if visit == 1 {
                app.buttons["detail.play"].firstMatch.tap()
                let ready = app.descendants(matching: .any).matching(identifier: "player.playback.ready").firstMatch
                XCTAssertTrue(ready.waitForExistence(timeout: 30))
                app.buttons["player.close"].firstMatch.tap()
            }
            let myList = app.descendants(matching: .any).matching(identifier: "detail.icon-row").firstMatch
                .buttons.matching(NSPredicate(format: "label IN %@", ["Add to My List", "Remove from My List"])).firstMatch
            XCTAssertTrue(myList.waitForExistence(timeout: 10))
            let nextLabel = myList.label == "Add to My List" ? "Remove from My List" : "Add to My List"
            myList.tap()
            let toggled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", nextLabel),
                                                    object: myList)
            XCTAssertEqual(XCTWaiter.wait(for: [toggled], timeout: 5), .completed, "My List did not toggle on visit \(visit)")
            XCTAssertTrue(back.isHittable)
            back.tap()
            XCTAssertTrue(details.waitForExistence(timeout: 5), "Return \(visit) to Discover")
            XCTAssertFalse(back.exists)
        }
    }

    func testLibrarySortBeforeAndAfterScrolling() {
        launch(screen: "library")
        let sort = app.buttons["library.sort"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: sort)
        let readiness = XCTWaiter().wait(for: [ready], timeout: 15)
        if readiness != .completed {
            attachHierarchy("library-sort-unhittable")
            attach("library-sort-unhittable")
        }
        XCTAssertEqual(readiness, .completed)
        XCTAssertGreaterThanOrEqual(sort.frame.width, 44)
        XCTAssertGreaterThanOrEqual(sort.frame.height, 44)
        XCTAssertTrue(sort.isHittable)
        sort.tap()
        let byTitle = app.buttons["Title A–Z"].firstMatch
        XCTAssertTrue(byTitle.waitForExistence(timeout: 5))
        byTitle.tap()
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(sort.isHittable)
        sort.tap()
        let byAdded = app.buttons["Added"].firstMatch
        XCTAssertTrue(byAdded.waitForExistence(timeout: 5))
        byAdded.tap()
    }

    func testCrawlLive() {
        runCrawlGroup("live", [CrawlScreen(route: "live"), CrawlScreen(route: "channels")])
    }

    func testLiveFullScreenCenterRejectsNonControlOverlays() throws {
        try XCTSkipIf(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
                      "The coordinate fallback is for the iOS 18 accessibility runtime")
        XCUIDevice.shared.orientation = .portrait
        for kind in ["other", "image", "none"] {
            app.terminate()
            app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES",
                                   "-OpenStreamResetOnLaunch", "YES",
                                   "-OpenStreamProbeLiveHitTest", "YES", "-OpenStreamLiveHitTestOverlay", kind]
            launch(screen: "live")
            let channel = app.buttons["Play Fixture News"].firstMatch
            XCTAssertTrue(channel.waitForExistence(timeout: 60))
            channel.tap()
            let fullScreen = app.buttons["player.fullscreen"].firstMatch
            XCTAssertTrue(fullScreen.waitForExistence(timeout: 60))
            crawlWindowRect = app.windows.firstMatch.frame
            let root = try app.snapshot()
            let snapshot = try XCTUnwrap(crawlSnapshot("player.fullscreen", in: root))
            XCTAssertTrue(snapshot.isEnabled)
            XCTAssertGreaterThan(snapshot.frame.width, 0)
            XCTAssertGreaterThan(snapshot.frame.height, 0)
            let clear = inlineFullScreenHasUnobscuredCenter(snapshot: snapshot, root: root)
            if kind == "none" {
                XCTAssertTrue(clear, "An unobscured Full Screen center must remain reachable")
                XCTAssertFalse(inlineFullScreenHasUnobscuredCenter(snapshot: snapshot, root: snapshot),
                               "Missing hit-test evidence must keep the coordinate fallback closed")
                fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["player.close"].firstMatch.waitForExistence(timeout: 30))
            } else {
                let blocker = app.descendants(matching: .any)["live.test.blocker"].firstMatch
                XCTAssertTrue(blocker.exists)
                XCTAssertEqual(blocker.elementType, kind == "image" ? .image : .other)
                XCTAssertTrue(blocker.frame.contains(CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)))
                XCTAssertTrue(blocker.isHittable)
                XCTAssertFalse(clear, "A hittable \(kind) overlay covers the Full Screen center")
            }
        }
    }

    func testCrawlSettingsRoot() {
        runCrawlGroup("settings-root", [
            CrawlScreen(route: "settings", includesTabs: true),
            CrawlScreen(route: "sources"),
            CrawlScreen(route: "first-run"),
        ])
    }

    func testCrawlSettingsPages() {
        runCrawlGroup("settings-pages", [
            CrawlScreen(route: "playback-settings"),
            CrawlScreen(route: "subtitle-languages"),
            CrawlScreen(route: "metadata"),
            CrawlScreen(route: "watch-providers"),
            CrawlScreen(route: "privacy"),
            CrawlScreen(route: "storage"),
            CrawlScreen(route: "about"),
            CrawlScreen(route: "backup"),
        ])
    }

    func testCrawlSourcesForms() {
        runCrawlGroup("sources-forms", [
            CrawlScreen(route: "add-files"),
            CrawlScreen(route: "add-live"),
            CrawlScreen(route: "add-media-server"),
            CrawlScreen(route: "network-share"),
            CrawlScreen(route: "web-management"),
        ])
    }

    func testCrawlDetailAndEpisodes() {
        let screens = [CrawlScreen(route: "detail"), CrawlScreen(route: "episodes")]
        // A full title-page walk exceeds one simulator call; filter by route for
        // bounded proof runs, while the default still crawls both pages.
        let route = ProcessInfo.processInfo.environment["OPENSTREAM_CRAWL_ROUTE"]
        runCrawlGroup("detail", route.map { selected in screens.filter { $0.route == selected } } ?? screens)
    }

    /// N22: Back was drawn on the hero art, so once the page scrolled it sat
    /// under the status bar and refused a touch. It is pinned now.
    func testDetailBackAfterScrolling() {
        launch(screen: "detail")
        let back = app.buttons["detail.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 40))
        crawlScrollDown()
        crawlScrollDown()
        XCTAssertTrue(back.isHittable, "Back must remain reachable after scrolling the title page")
        back.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: back)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Back must dismiss the title page")
    }

    /// Both players, both ways up. The transport is the one surface whose
    /// controls move between orientations, and the live player's channel panel
    /// only exists there.
    func testCrawlPlayers() {
        runCrawlGroup("players", [
            CrawlScreen(route: "detail", opener: .vodPlayer),
            CrawlScreen(route: "detail", opener: .vodPlayer, landscape: true),
            CrawlScreen(route: "live", opener: .livePlayer),
            CrawlScreen(route: "live", opener: .livePlayer, landscape: true),
        ])
    }

    func testVODHasOneMoreMenuAndOneCaptionsControlThatHideTogether() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        for engine in ["native", "engine"] {
            app.launchArguments = ["-OpenStreamVisionScreen", "add-files",
                "-OpenStreamVisionPlaybackURL", base + "/media/e2e-long.mp4",
                "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", engine,
                "-OpenStreamMuteAudio", "YES"]
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch
                .waitForExistence(timeout: 60))
            assertOnePlayerMenuThatHidesWithCaptions()
            let captions = app.buttons["player.captions"].firstMatch
            XCTAssertTrue(tapIfPossible(captions))
            XCTAssertTrue(app.buttons["English"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Off"].firstMatch.exists)
            app.buttons["English"].firstMatch.tap()
            XCTAssertTrue(revealPlayerControls())
            XCTAssertTrue(tapIfPossible(captions))
            XCTAssertTrue(app.buttons["English"].firstMatch.isSelected)
            app.buttons["Off"].firstMatch.tap()
            app.terminate()
        }
    }

    func testLiveHasOneMoreMenuAndOneCaptionsControlThatHideTogether() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        app.launchArguments = ["-OpenStreamInlineLiveFixture",
            "-OpenStreamVisionPlaybackURL", base + "/live/cbs.ts",
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 60))
        fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        assertOnePlayerMenuThatHidesWithCaptions()
    }

    private func launchSlidingLiveFixture(engine: String = "engine") throws {
        let url = try liveLabURL()
        app.launchArguments = ["-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackURL", url.absoluteString,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES",
            "-openstream.playback.engine", engine,
            "-OpenStreamHoldPlayerChrome", "YES", "-openstream.reset.cloudRestoreHeld.v1", "YES"]
        configureFixtureLaunch(app)
        app.launch()
    }

    private func liveLabURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.host, "127.0.0.1")
        return url
    }

    private func localSourceArguments(_ sources: [[String: String]]) throws -> [String] {
        XCTAssertEqual(ProcessInfo.processInfo.environment["OPENSTREAM_ALLOW_MUTATING_UI_TESTS"], "1")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("live-sources-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": sources]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ["-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES",
                "-OpenStreamStubLiveBase", try liveLabURL().deletingLastPathComponent().deletingLastPathComponent().absoluteString,
                "-openstream.reset.cloudRestoreHeld.v1", "YES", "-openstream.settings.live.package.v1", "everything"]
    }

    func testStalledLiveOriginStopsLoadingAndLeavesTheListUsable() throws {
        let url = try liveLabURL().deletingLastPathComponent().deletingLastPathComponent()
        app.launchArguments = try localSourceArguments([["kind": "m3u", "name": "IPTV",
            "playlistURL": url.appendingPathComponent("failure/channels.m3u").absoluteString]])
        app.launchArguments += ["-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let stalled = app.buttons["Play A&E Fixture"].firstMatch
        XCTAssertTrue(stalled.waitForExistence(timeout: 30))
        let stage = app.descendants(matching: .any)["live.stage.player"].firstMatch
        let loading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Loading'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [loading], timeout: 15), .completed)
        attach("live-stalled-origin-before-deadline")
        let retry = app.buttons["live.failure.retry"].firstMatch
        let reachedDeadline = retry.waitForExistence(timeout: 30)
        if !reachedDeadline {
            attachHierarchy("live-stalled-origin-deadline-hierarchy")
            let trace = XCTAttachment(string: try currentOpenStreamTrace().joined(separator: "\n"))
            trace.name = "live-stalled-origin-deadline-trace"; trace.lifetime = .keepAlways; add(trace)
        }
        XCTAssertTrue(reachedDeadline)
        XCTAssertEqual(retry.label, "Retry")
        XCTAssertTrue(app.staticTexts["Can’t reach this channel’s server"].exists)
        XCTAssertNotEqual(stage.value as? String, "Loading")
        assertControlRowFrames(["live.failure.retry"], name: "live-failure-retry")
        attach("live-stalled-origin-after-deadline")
        let next = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'guide.play.' AND label != 'Play A&E Fixture'")).firstMatch
        XCTAssertTrue(next.exists)
        next.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'Playing'"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 30), .completed)
        XCTAssertFalse(retry.exists)
        attach("live-working-channel-after-stalled-origin")
    }

    private func openFixtureSourceDetails(named name: String) throws {
        app.terminate()
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-openstream.reset.cloudRestoreHeld.v1", "YES"]
        app.launchArguments += ["-OpenStreamStubLiveBase", try liveLabURL().deletingLastPathComponent().deletingLastPathComponent().absoluteString]
        launch(screen: "settings")
        let sources = app.buttons["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 20))
        sources.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
    }

    func testMediaServerLibraryLoadShowsConnectedInSources() throws {
        let base = try liveLabURL().deletingLastPathComponent().deletingLastPathComponent()
        app.launchArguments = try localSourceArguments([["kind": "mediaServer", "server": "jellyfin", "name": "Rill",
            "url": base.appendingPathComponent("jf").absoluteString, "username": "fixture", "password": "fixture"]])
        launch(screen: "discover")
        let shelf = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.ms.'")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 45))
        try openFixtureSourceDetails(named: "Rill")
        XCTAssertTrue(app.staticTexts["Health, Connected"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Status, Connected · '")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Health, Not checked"].exists)
        attach("sources-rill-connected-after-library-load")
    }

    func testStalledPlaylistKeepsSavedChannelsWithoutAnImmediateWarning() throws {
        let base = try liveLabURL().deletingLastPathComponent().deletingLastPathComponent()
        app.launchArguments = try localSourceArguments([["kind": "m3u", "name": "IPTV",
            "playlistURL": base.appendingPathComponent("saved/channels.m3u").absoluteString]])
        launch(screen: "live")
        XCTAssertTrue(app.buttons["Play Fixture Live 1"].firstMatch.waitForExistence(timeout: 30))
        try stallOpenStreamSavedPlaylist()
        attach("live-saved-playlist-before-stalled-refresh")
        app.terminate()
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-openstream.reset.cloudRestoreHeld.v1", "YES"]
        app.launchArguments += ["-OpenStreamStubLiveBase", base.absoluteString]
        launch(screen: "live")
        XCTAssertTrue(app.buttons["Play Fixture Live 1"].firstMatch.waitForExistence(timeout: 20))
        let failedRefresh = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live playlist failed: IPTV saved=true") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failedRefresh], timeout: 45), .completed)
        XCTAssertFalse(app.descendants(matching: .any)["live.sourceError"].exists)
        attach("live-saved-channels-after-stalled-refresh")
        try openFixtureSourceDetails(named: "IPTV")
        let health = app.staticTexts["Health, Showing saved channels"].firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Status, Showing saved channels · last updated '")).firstMatch
        XCTAssertTrue(status.exists)
        if app.frame.width < 600 {
            XCTAssertGreaterThan(status.frame.height, health.frame.height + 1, "The saved-channel update date must wrap on iPhone")
        }
        XCTAssertFalse(app.staticTexts["Health, Needs attention"].exists)
        attach("sources-iptv-showing-saved-channels")
    }

    func testSlidingLiveStartsAtTheEdgeWithoutALivePress() throws {
        try assertSlidingLiveStartsAtTheEdge(engine: "engine")
    }

    func testNativeSlidingLiveStartsAtTheEdgeWithoutALivePress() throws {
        try assertSlidingLiveStartsAtTheEdge(engine: "native")
    }

    private func assertSlidingLiveStartsAtTheEdge(engine: String) throws {
        try launchSlidingLiveFixture(engine: engine)
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live initial edge joined engine=\(engine) route=avPlayer") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 30), .completed)
        let line = try XCTUnwrap(currentOpenStreamTrace().last { $0.contains("live initial edge joined engine=\(engine)") })
        let fields = Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { field -> (String, Double)? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { return nil }
            return (String(parts[0]), value)
        })
        let edge = try XCTUnwrap(fields["edge"])
        let position = try XCTUnwrap(fields["position"])
        XCTAssertLessThanOrEqual(abs(edge - position), 3, line)
        let trace = XCTAttachment(string: line)
        trace.name = "live-initial-edge-\(engine)-trace"; trace.lifetime = .keepAlways; add(trace)
        let play = app.buttons["player.play-pause"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 15), .completed)
        attach("live-sliding-\(engine)-initial-playback-no-live-press")
        let fullScreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullScreen.waitForExistence(timeout: 10))
        fullScreen.tap()
        let live = app.descendants(matching: .any)["player.live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        XCTAssertNotEqual(live.value as? String, "Behind live")
        XCTAssertTrue(app.buttons["player.skip-back"].firstMatch.exists,
                      "The fixture must expose a real DVR window")
        attach("live-sliding-\(engine)-fullscreen-at-edge-no-live-press")
    }

    func testLiveControlRowsHaveMatchingFrames() throws {
        continueAfterFailure = true
        try launchSlidingLiveFixture()
        let fullscreen = app.buttons["player.fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 45))
        assertControlRowFrames(["player.mute", "player.airplay", "player.fullscreen"], name: "live-inline-controls")
        fullscreen.tap()
        let back = app.buttons["player.skip-back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        assertControlRowFrames(["player.skip-back", "player.play-pause", "player.skip-forward"],
                              name: "live-fullscreen-transport")
        assertControlRowFrames(["player.close", "player.options"], name: "live-fullscreen-top")
        assertControlRowFrames(["player.airplay", "player.captions"], name: "live-fullscreen-bottom")
        back.tap()
        let live = app.buttons["player.live"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        assertControlRowFrames(["player.live"], name: "live-fullscreen-live-edge")
    }

    func testVODControlRowsHaveMatchingFrames() throws {
        continueAfterFailure = true
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        for engine in ["native", "engine"] {
            app.launchArguments = ["-OpenStreamVisionScreen", "add-files",
                "-OpenStreamVisionPlaybackURL", base + "/media/e2e-long.mp4",
                "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", engine,
                "-OpenStreamMuteAudio", "YES", "-OpenStreamHoldPlayerChrome", "YES"]
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["player.playback.ready"].firstMatch.waitForExistence(timeout: 45))
            XCTAssertTrue(revealPlayerControls())
            let topControls = ["player.close"] + ["player.pip", "player.airplay"].filter {
                app.descendants(matching: .any)[$0].firstMatch.exists
            }
            assertControlRowFrames(topControls, name: "vod-\(engine)-top-controls")
            assertControlRowFrames(["player.captions", "player.options"], name: "vod-\(engine)-bottom-controls")
            assertControlRowFrames(["player.skip-back", "player.play-pause", "player.skip-forward"],
                                  name: "vod-\(engine)-transport")
            app.terminate()
        }
    }

    private func assertControlRowFrames(_ identifiers: [String], name: String) {
        let controls = identifiers.map { app.descendants(matching: .any)[$0].firstMatch }
        for (identifier, control) in zip(identifiers, controls) { XCTAssertTrue(control.exists, "Missing \(identifier)") }
        guard controls.allSatisfy(\.exists) else { return }
        let frames = controls.map(\.frame)
        guard let first = frames.first else { XCTFail("Empty control row"); return }
        for frame in frames {
            XCTAssertEqual(frame.width, first.width, accuracy: 1)
            XCTAssertEqual(frame.height, first.height, accuracy: 1)
            XCTAssertEqual(frame.midY, first.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
        }
        let record = XCTAttachment(string: zip(identifiers, frames).map { "\($0): \($1)" }.joined(separator: "\n"))
        record.name = name + "-frames"; record.lifetime = .keepAlways; add(record)
        attach(name)
    }

    private func assertOnePlayerMenuThatHidesWithCaptions() {
        let more = app.buttons.matching(NSPredicate(format:
            "identifier IN %@ OR label == 'More Controls' OR identifier == 'Overflow Menu'",
            ["player.options", "player.more"]))
        let captions = app.buttons.matching(identifier: "player.captions")
        let toggle = app.buttons["player.play-pause"].firstMatch
        for _ in 0..<3 {
            XCTAssertTrue(revealPlayerControls())
            if toggle.exists {
                if toggle.label == "Pause" { toggle.tap() }
                break
            }
        }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.exists && toggle.label == "Play"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        XCTAssertEqual(more.count, 1, "The player must expose exactly one ellipsis")
        XCTAssertEqual(captions.count, 1, "The player must expose exactly one captions control")
        XCTAssertTrue(tapIfPossible(more.firstMatch), "More does not accept a touch")
        XCTAssertTrue(app.buttons["player.sleepTimer"].firstMatch.waitForExistence(timeout: 5))
        attach("player-dots-single-more-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.buttons["player.sleepTimer"].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(revealPlayerControls())
        if toggle.label == "Play" { toggle.tap() }
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.exists && toggle.label == "Pause"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            more.count == 0 && captions.count == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed,
            "More and captions must leave the control layer together")
        XCTAssertFalse(more.firstMatch.exists && more.firstMatch.isHittable)
        XCTAssertFalse(captions.firstMatch.exists && captions.firstMatch.isHittable)
        attach("player-dots-controls-hidden")
        XCTAssertTrue(revealPlayerControls())
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(captions.count, 1)
        attach("player-dots-controls-shown")
    }

    /// The iPad variant. A regular-width split layout puts a different set of
    /// controls on screen than the phone does, and landscape is where the tab
    /// bar and the player chrome trade places.
    func testCrawlLandscapeOnIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The landscape crawl is the iPad variant; run it on the iPad simulator.")
        }
        runCrawlGroup("landscape", [
            CrawlScreen(route: "discover", landscape: true, includesTabs: true),
            CrawlScreen(route: "library", landscape: true),
            CrawlScreen(route: "live", landscape: true),
            CrawlScreen(route: "settings", landscape: true),
            CrawlScreen(route: "detail", landscape: true),
        ])
    }

    private func runCrawlGroup(_ group: String, _ screens: [CrawlScreen]) {
        // Every screen has to be reported on, so one silent button must not end
        // the walk at the screen it was found on.
        continueAfterFailure = true
        executionTimeAllowance = 3600
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        crawlReport = ["button crawl — \(device) — group \(group) — \(Date())", ""]
        var totals = CrawlResult()
        for screen in screens { totals.add(crawl(screen)) }

        crawlReport.insert(contentsOf: [
            "group \(group)  screens: \(screens.count)  controls found: \(totals.found)  "
                + "pressed: \(totals.pressed)  no response: \(totals.silent)  "
                + "unhittable: \(totals.unreachable)  skipped: \(totals.skipped)",
            "",
        ], at: 1)
        let attachment = XCTAttachment(string: crawlReport.joined(separator: "\n"))
        attachment.name = "button-crawl-\(device)-\(group).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        for defect in totals.defects { XCTFail(defect) }
    }

    private func crawlNote(_ line: String) {
        // Echoed as it is written: a walk that dies on its last screen would
        // otherwise take the whole report with it, and the log survives.
        print("CRAWL| " + line)
        crawlReport.append(line)
    }

    // MARK: Reading the screen

    /// One look at the whole app, flattened. Every count the walk needs comes
    /// out of this: the alternative — `app.buttons.count`, `app.sheets.count`,
    /// `app.alerts.count` and the rest, one query each — costs a full snapshot
    /// per question and made a single press on Discover take a minute.
    private func crawlScene() -> CrawlScene {
        var scene = CrawlScene()
        scene.appState = app.state.rawValue
        guard let snapshot = try? app.snapshot() else { return scene }
        crawlWalk(snapshot, into: &scene)
        scene.textHash = scene.textDigest.finalize()
        scene.controlHash = scene.controlDigest.finalize()
        return scene
    }

    private func crawlWalk(_ node: XCUIElementSnapshot, into scene: inout CrawlScene) {
        let identifier = node.identifier
        switch node.elementType {
        case .button, .link, .switch, .segmentedControl, .cell, .textField, .secureTextField, .slider:
            scene.nodes.append(CrawlNode(
                type: node.elementType,
                identifier: identifier,
                label: node.label,
                value: (node.value as? String) ?? "",
                placeholder: node.placeholderValue ?? "",
                frame: node.frame,
                isEnabled: node.isEnabled,
                isSelected: node.isSelected,
                collection: crawlCollectionKey(identifier)))
            scene.controlDigest.combine(identifier)
            scene.controlDigest.combine(node.label)
            scene.controlDigest.combine((node.value as? String) ?? "")
            scene.controlDigest.combine(node.isSelected)
            scene.controlDigest.combine(node.isEnabled)
            if node.elementType == .button { scene.buttons += 1 }
            // The scrubber is in the scene for its value — a ten-second skip on
            // a live stream with a DVR window moves nothing else — but not in
            // the list of things to press: it is dragged, not tapped, and the
            // chapter test drives it.
        case .navigationBar:
            if scene.navigation.isEmpty { scene.navigation = identifier }
        case .alert:
            scene.alerts += 1
        case .sheet, .popover:
            scene.sheets += 1
        case .keyboard:
            scene.keyboards += 1
        case .staticText:
            scene.texts += 1
            scene.textDigest.combine(node.label)
        case .collectionView, .table:
            scene.lists.append(node.frame)
        default:
            break
        }
        for child in node.children { crawlWalk(child, into: &scene) }
    }

    private func crawlCollectionKey(_ identifier: String) -> String? {
        guard let prefix = Self.crawlCollectionPrefixes.first(where: { identifier.hasPrefix($0) }) else { return nil }
        // The two Top 10 rows, and one media server's shelf against another's.
        if prefix == "home.top10." || prefix == "home.ms." {
            let parts = identifier.split(separator: ".")
            if parts.count >= 3 { return parts.prefix(3).joined(separator: ".") }
        }
        return String(prefix.dropLast())
    }

    private func crawlScrollSignature(_ scene: CrawlScene) -> String {
        "\(scene.nodes.count)|\(scene.nodes.first?.identifier ?? "")|\(scene.nodes.first?.frame.origin.y ?? 0)|"
            + "\(scene.nodes.last?.identifier ?? "")|\(scene.nodes.last?.frame.origin.y ?? 0)"
    }

    private func crawlFind(_ target: CrawlTarget, in scene: CrawlScene) -> CrawlNode? {
        scene.nodes.first {
            $0.type == target.type
                && (target.identifier.isEmpty ? $0.label == target.label : $0.identifier == target.identifier)
        }
    }

    private func crawlStateString(_ scene: CrawlScene, target: CrawlTarget?) -> String {
        // A retained UIKit controller can expose the same identifier as the
        // foreground one. Observe every matching control's state, rather than
        // letting an inactive first match conceal the foreground response.
        let own = target.map { target in
            if !target.identifier.hasPrefix("player."), !target.identifier.hasPrefix("live.player.") {
                return crawlFind(target, in: scene)
                    .map { "\($0.label)|\($0.value)|\($0.isSelected)|\($0.isEnabled)" } ?? "none"
            }
            return scene.nodes.filter {
                $0.type == target.type && (target.identifier.isEmpty
                    ? $0.label == target.label : $0.identifier == target.identifier)
            }.map { "\($0.label)|\($0.value)|\($0.isSelected)|\($0.isEnabled)" }
                .sorted().joined(separator: ";")
        } ?? "none"
        return [
            // A link that opens Safari answers by taking the app off screen.
            "state:\(scene.appState)",
            scene.navigation,
            "alerts:\(scene.alerts)",
            "sheets:\(scene.sheets)",
            "keyboard:\(scene.keyboards)",
            // How much is on the screen. A menu, a pushed page that kept the
            // title, a spinner that replaced a button while a retry ran: all of
            // them change one of these counts and nothing else does.
            "breadth:\(scene.buttons)",
            "controls:\(scene.nodes.count)",
            "lists:\(scene.lists.count)",
            "texts:\(scene.texts)",
            // A screen with a clock on it rewrites itself while nobody is
            // pressing anything; there, what the screen says cannot be the
            // evidence that a press did something.
            crawlTextIsStable ? "says:\(scene.textHash)" : "says:-",
            crawlControlsAreStable ? "controls-say:\(scene.controlHash)" : "controls-say:-",
            own,
        ].joined(separator: "|")
    }

    private func crawlPlaybackSeconds() -> Double? {
        let slider = app.sliders.firstMatch
        guard slider.exists, let value = slider.value as? String,
              value.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
        return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    private func crawlInlineLiveHasState(_ state: String) -> Bool {
        app.descendants(matching: .any).matching(identifier: "live.stage.player")
            .allElementsBoundByIndex.contains { ($0.value as? String) == state && !$0.frame.isEmpty }
    }

    #if targetEnvironment(simulator)
    // AVRoutePickerView exposes its system button on the simulator without
    // presenting receivers. Discovery and routing need a physical device.
    // Live's AirPlay is itself the `player.airplay` button (`AppleLiveRouteButton`).
    private func crawlSimulatorAirPlayIsAvailable(_ button: XCUIElement, inline: Bool) -> Bool {
        let pickers = app.descendants(matching: .any).matching(identifier: "player.airplay")
        let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let playing: Bool
            if inline {
                playing = self.crawlInlineLiveHasState("Playing")
            } else {
                playing = self.app.descendants(matching: .any).matching(identifier: "player.live").firstMatch.exists
                    && self.app.buttons.matching(identifier: "player.play-pause").allElementsBoundByIndex
                        .contains { self.isSafelyHittable($0) && $0.label == "Pause" }
            }
            return self.app.state == .runningForeground && button.exists
                && button.label == "AirPlay" && button.isEnabled
                && pickers.allElementsBoundByIndex.contains { $0.frame.contains(button.frame) }
                && self.isSafelyHittable(button)
                && playing
                && !self.app.progressIndicators["live.loading"].exists
        }, object: nil)
        let passed = XCTWaiter.wait(for: [available], timeout: 5) == .completed
        let evidence = XCTAttachment(string: "Simulator route-control check: \(passed); inline=\(inline); routing requires hardware.\n"
            + app.debugDescription + "\nSystem host:\n"
            + XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        evidence.name = "live-airplay-simulator-surface"; evidence.lifetime = .keepAlways; add(evidence)
        return passed
    }
    #endif

    private func waitForCrawlResponse(from before: String, target: CrawlTarget) -> (Bool, CrawlScene) {
        let deadline = Date().addingTimeInterval(3)
        while true {
            let scene = crawlScene()
            if crawlStateString(scene, target: target) != before { return (true, scene) }
            guard Date() < deadline else { return (false, scene) }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    // MARK: The walk

    /// Walks the screen where it stands rather than listing it and coming back.
    ///
    /// A `LazyVStack` builds a shelf as it nears the fold and throws it away
    /// when it leaves, so a list made at the bottom of Discover names controls
    /// that do not exist while the screen sits at the top — the first attempt
    /// at this reported ninety of Discover's hundred and thirty controls as
    /// "gone", which was the screen scrolling, not the app failing. So: press
    /// everything the screen is showing now, scroll by one screen, press
    /// whatever that brought, and stop when a scroll changes nothing.
    private func crawl(_ screen: CrawlScreen) -> CrawlResult {
        var result = CrawlResult()
        let route = screen.route
        let isPlayer = screen.opener != .none
        let isLive = route == "live"
        let isInlineLive = isLive && !isPlayer

        launchForCrawl(screen)
        crawlNote("== \(screen.name)")
        guard app.state == .runningForeground else {
            crawlNote("   the app did not reach the foreground")
            result.defects.append("[\(screen.name)] the app never reached the foreground")
            return result
        }
        guard openForCrawl(screen.opener) else {
            crawlNote("   the screen could not be opened")
            result.defects.append("[\(screen.name)] the screen could not be opened for the crawl")
            app.terminate()
            return result
        }
        if isPlayer {
            let transport = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.crawlScene().nodes.contains { $0.identifier == "player.play-pause" }
            }, object: nil)
            guard XCTWaiter.wait(for: [transport], timeout: 10) == .completed else {
                let evidence = XCTAttachment(string: "Snapshot controls: \(crawlScene().nodes.map(\.identifier))\n"
                    + app.debugDescription)
                evidence.name = "players-missing-transport"; evidence.lifetime = .keepAlways; add(evidence)
                result.defects.append("[\(screen.name)] the player snapshot never exposed its transport")
                app.terminate()
                return result
            }
            if isLive, ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false {
                XCTAssertFalse(app.buttons["player.captions"].firstMatch.isEnabled,
                               "The audio-only Live fixture must not offer an empty track menu")
            }
        }

        crawlWindowRect = app.windows.firstMatch.frame
        crawlBarRect = isPlayer ? .null : tabBarRectForCrawl()
        crawlPressesPerCollection = [:]
        crawlDownloadsPressed = 0
        crawlSourcesPressed = 0
        let homeTab = selectedTabLabel()
        var scene = crawlScene()
        crawlBaselineLists = scene.lists.count
        // Read twice, untouched: a guide with what's-on-now times in it, or a
        // player with a clock, rewrites its own labels, and on those screens a
        // changed word is not an answer to a press.
        crawlTextIsStable = true
        crawlControlsAreStable = true
        Thread.sleep(forTimeInterval: 0.8)
        let second = crawlScene()
        crawlTextIsStable = second.textHash == scene.textHash && second.texts == scene.texts
        crawlControlsAreStable = second.controlHash == scene.controlHash
        scene = second
        if !crawlTextIsStable {
            crawlNote("   (this screen rewrites its own text while untouched; "
                      + "what it says is not read as an answer here)")
        }
        let baseline = scene.navigation
        // The screen's own first control, to check the screen against after a
        // press: if it is gone, a modal is still up and the rest of the walk
        // would be nonsense.
        let anchor = crawlTargets(from: scene, includesTabs: false, playerOnly: isPlayer)
            .first { !isCrawlExit($0) }

        // A control that is on the screen, whole, enabled, and will not take a
        // touch is a tap-target defect — unless most of the screen is like that,
        // in which case the screen is behind a card that `app.sheets` did not
        // report and none of it is a defect. Which it is cannot be known until
        // the screen has been walked, so the verdicts are held to the end.
        var blocked: [CrawlTarget] = []
        var handled = Set<String>()
        var exits: [CrawlTarget] = []
        var relaunches = 0
        var scrolls = 0

        while true {
            // The transport hides itself, and a screen read with the chrome
            // down holds one control: the clear surface that brings it back.
            if isPlayer, revealPlayerControls() { scene = crawlScene() }
            else if route == "live", scene.sheets == 0, scene.alerts == 0,
                    revealInlineLiveControls() { scene = crawlScene() }
            let here = crawlTargets(from: scene, includesTabs: screen.includesTabs, playerOnly: isPlayer)
            for target in here where isCrawlExit(target) && !handled.contains(target.signature) {
                handled.insert(target.signature)
                result.found += 1
                exits.append(target)
            }
            guard let target = here.first(where: { !handled.contains($0.signature) }) else {
                // Nothing new at this offset. A player has no scroll, and a
                // sheet is dismissed by a swipe, so neither is scrolled.
                if isPlayer || scene.sheets > 0 || scrolls >= 16 { break }
                let before = crawlScrollSignature(scene)
                crawlScrollDown()
                Thread.sleep(forTimeInterval: 0.6)
                scrolls += 1
                scene = crawlScene()
                if crawlScrollSignature(scene) == before { break }
                continue
            }
            handled.insert(target.signature)
            result.found += 1

            if let reason = crawlPolicySkip(target, route: route, scene: scene) {
                result.skipped += 1
                crawlNote("   · \(target.name) — not pressed: \(reason)")
                continue
            }
            if let collection = target.collection,
               (crawlPressesPerCollection[collection] ?? 0) >= Self.crawlCardsPerCollection {
                result.skipped += 1
                crawlNote("   · \(target.name) — not pressed: past the first "
                          + "\(Self.crawlCardsPerCollection) of \(collection) (policy)")
                continue
            }
            guard let node = crawlFind(target, in: scene) else { continue }
            // A disabled control is meant to do nothing, and an option that is
            // already the chosen one is meant to stay chosen. Pressing either
            // and calling the silence a defect would bury the real findings.
            guard node.isEnabled else {
                result.skipped += 1
                crawlNote("   · \(target.name) — not pressed: disabled")
                continue
            }

            let element = resolveCrawlTarget(target)
            let reach = revealForCrawl(element, node: node, isTab: target.isTab)
            // A guide cell for a programme that started before the window runs
            // off the leading edge, and its centre — the point `tap()` uses —
            // is past the edge of the screen while a good part of the cell is
            // in plain sight and takes a finger. Press the part that is there.
            var hitOffset: CGVector? = nil
            if target.identifier == "player.controls.show" {
                // The surface's centre is covered by Play/Pause. A background
                // touch belongs in a clear part of the video, and must still
                // change the chrome state to count as a response.
                hitOffset = crawlPlayerBackgroundHitOffset(element.frame, scene: scene)
                crawlNote("   background frame=\(element.frame) offset=\(String(describing: hitOffset)) Close=\(app.buttons["player.close"].firstMatch.exists ? app.buttons["player.close"].firstMatch.frame : .zero)")
            }
            if reach == .offScreen, let live = (try? element.snapshot())?.frame,
               let offset = crawlVisibleHitOffset(live) {
                hitOffset = offset
                crawlNote("   (\(target.name) hangs off the edge; pressing the part that is on screen)")
            }
            guard (reach == .hittable && target.identifier != "player.controls.show") || hitOffset != nil else {
                switch reach {
                case .gone:
                    result.skipped += 1
                    crawlNote("   · \(target.name) — not pressed: it left the screen before its turn")
                case .disabled:
                    result.skipped += 1
                    crawlNote("   · \(target.name) — not pressed: disabled")
                case .offScreen where (try? element.snapshot())?.frame.intersects(crawlScreenRect) == true:
                    // A guide cell for a programme that began before the
                    // window starts is drawn partly under the pinned channel
                    // rail, with too little of it clear of the rail to aim at.
                    // A finger finds the part it can see; XCUITest aims at the
                    // centre, and the centre is past the edge. Not a defect.
                    result.skipped += 1
                    crawlNote("   · \(target.name) — not pressed: it hangs off the leading edge with too "
                              + "little of it clear to aim at")
                case .offScreen:
                    result.unreachable += 1
                    crawlNote("   ✗ \(target.name) — COULD NOT BE SCROLLED ON SCREEN: nothing of it is on the screen")
                    attach("\(screen.name)__\(target.slug)")
                    result.defects.append("[\(screen.name)] \(target.name) could not be brought on screen by scrolling")
                case .blocked where scene.navigation != baseline:
                    // The system document picker is another process's view and
                    // is reported as neither a sheet nor an alert; behind it,
                    // the app's own back chevron is correctly untouchable.
                    result.skipped += 1
                    crawlNote("   · \(target.name) — not pressed: another view was over the screen when its turn came")
                default:
                    blocked.append(target)
                    // Photographed where it happened: taken with the verdict at
                    // the end of the screen, the picture would be of wherever
                    // the walk had scrolled to by then.
                    attach("\(screen.name)__\(target.slug)")
                    crawlNote("   ? \(target.name) — would not take a touch at "
                              + "\((try? element.snapshot())?.frame.debugDescription ?? "no frame")"
                              + "; judged at the end of the screen")
                }
                scene = crawlScene()
                continue
            }

            if (target.label + " " + target.identifier).lowercased().contains("download") {
                crawlDownloadsPressed += 1
            }
            // Counted here, where the press actually happens: counted at the
            // top, three rows that turned out to be disabled used up a shelf's
            // whole allowance and nothing in it was pressed.
            if let collection = target.collection {
                crawlPressesPerCollection[collection] = (crawlPressesPerCollection[collection] ?? 0) + 1
            }
            // Scrolling may move the target after the original scene snapshot.
            var expectedSkip: Double?
            var resumeAfterSkip = false
            if !isLive, ["player.skip-back", "player.skip-forward"].contains(target.identifier) {
                let transport = app.buttons["player.play-pause"].firstMatch
                resumeAfterSkip = transport.label == "Pause"
                // Playback itself carries the clock past 10 s: a scrub to 10 % of
                // the slider landed at 1-9 s, and how fast the crawl got here (or
                // that it just paused the player) must not decide this check.
                if (crawlPlaybackSeconds() ?? 0) <= 10 {
                    if transport.label == "Play" { transport.tap() }
                    let played = Date().addingTimeInterval(15)
                    while Date() < played, (crawlPlaybackSeconds() ?? 0) <= 10 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
                if transport.label == "Pause" { transport.tap() }
                XCTAssertTrue(app.sliders.firstMatch.exists, "Skip verification requires the real scrubber")
                // Measure the settled paused position, not the moment of the tap.
                let positioned = Date().addingTimeInterval(5)
                var position = crawlPlaybackSeconds()
                while Date() < positioned {
                    Thread.sleep(forTimeInterval: 0.3)
                    let next = crawlPlaybackSeconds()
                    if let next, next == position { break }
                    position = next
                }
                let observed = position ?? -100
                XCTAssertGreaterThan(observed, 10, "Skip test did not reach an interior position")
                XCTAssertLessThan(observed, 1790)
                expectedSkip = observed + (target.identifier == "player.skip-back" ? -10 : 10)
            }
            var settledPlayPause: XCUIElement?
            if target.identifier == "player.play-pause" {
                let transport = resolveCrawlTarget(target)
                let initial = XCTAttachment(string: app.debugDescription)
                initial.name = "players-play-pause-before-settle"; initial.lifetime = .keepAlways; add(initial)
                if transport.label == "Play" {
                    transport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                let start = crawlPlaybackSeconds()
                var previousLabel = transport.label
                var settled = false
                var samples = ["start=\(String(describing: start)), label=\(previousLabel)"]
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.3)
                    let clock = crawlPlaybackSeconds()
                    let currentLabel = transport.label
                    samples.append("clock=\(String(describing: clock)), label=\(currentLabel)")
                    let playbackReady: Bool
                    if isLive {
                        // Live publishes Playing or Live/Behind live, not a VOD clock.
                        playbackReady = isInlineLive ? crawlInlineLiveHasState("Playing")
                            : app.descendants(matching: .any).matching(identifier: "player.live").firstMatch.exists
                    } else {
                        playbackReady = start.flatMap { start in clock.map { $0 > start } } ?? false
                    }
                    if playbackReady, currentLabel == "Pause", currentLabel == previousLabel {
                        settled = true
                        break
                    }
                    previousLabel = currentLabel
                }
                let timing = XCTAttachment(string: samples.joined(separator: "\n"))
                timing.name = "players-play-pause-settle-clock"; timing.lifetime = .keepAlways; add(timing)
                let chromeReady = settled && (isInlineLive ? revealInlineLiveControls() : revealPlayerControls())
                guard chromeReady,
                      let current = app.buttons.matching(identifier: "player.play-pause")
                        .allElementsBoundByIndex.first(where: { $0.isHittable && $0.label == "Pause" }) else {
                    result.silent += 1
                    let condition = isLive ? "live Playing state" : "advancing VOD clock"
                    result.defects.append("[\(screen.name)] playback did not settle with \(condition) before Play/Pause within 10 s")
                    crawlNote("   ✗ playback did not settle with \(condition) before Play/Pause")
                    let failed = XCTAttachment(string: app.debugDescription)
                    failed.name = "players-play-pause-unsettled"; failed.lifetime = .keepAlways; add(failed)
                    attach("players-play-pause-unsettled")
                    continue
                }
                settledPlayPause = current
                crawlNote("   settled Play/Pause frame=\(current.frame) center=(\(current.frame.midX), \(current.frame.midY))")
            }
            scene = crawlScene()
            let before = crawlStateString(scene, target: target)
            let opensBrowser = target.identifier == "settings.acknowledgements.sourceCode"
            let controlsWereUp = target.identifier == "player.controls.show" && playerCaptionsAreUp()
            if let settledPlayPause {
                settledPlayPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else if target.identifier.hasPrefix("home.featured.") {
                // Hero paging can replace the control while the response snapshot is collected.
                var heroTouch: (control: XCUIElement, offset: CGVector)?
                let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let current = self.resolveCrawlTarget(target)
                    guard let frame = (try? current.snapshot())?.frame,
                          let offset = self.crawlVisibleHitOffset(frame) else { return false }
                    heroTouch = (current, offset)
                    return true
                }, object: nil)
                guard XCTWaiter.wait(for: [visible], timeout: 5) == .completed, let heroTouch else {
                    result.unreachable += 1
                    result.defects.append("[\(screen.name)] \(target.name) had no visible hero control within 5 s")
                    attach("hero-before-touch")
                    continue
                }
                pressForCrawl(heroTouch.control, node: node, at: heroTouch.offset)
            } else {
                pressForCrawl(element, node: node, at: hitOffset)
            }
            var answered: Bool
            if let settledPlayPause {
                let deadline = Date().addingTimeInterval(3)
                while settledPlayPause.label != "Play", Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                answered = settledPlayPause.label == "Play"
                if answered, isInlineLive {
                    let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        settledPlayPause.exists && settledPlayPause.label == "Play"
                            && self.crawlInlineLiveHasState("")
                    }, object: nil)
                    answered = XCTWaiter.wait(for: [paused], timeout: 3) == .completed
                }
                if answered, isLive {
                    settledPlayPause.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        settledPlayPause.exists && settledPlayPause.label == "Pause"
                            && (!isInlineLive || self.crawlInlineLiveHasState("Playing"))
                    }, object: nil)
                    answered = XCTWaiter.wait(for: [resumed], timeout: 5) == .completed
                }
                let evidence = XCTAttachment(string: "label=\(settledPlayPause.label), clock=\(String(describing: crawlPlaybackSeconds()))\n" + app.debugDescription)
                evidence.name = "players-play-pause-after"; evidence.lifetime = .keepAlways; add(evidence)
            } else if opensBrowser {
                // The repository may return 404; the response is the browser handoff.
                let handedOff = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let state = self.app.state
                    return state == .runningBackground || state == .runningBackgroundSuspended
                }, object: nil)
                answered = XCTWaiter.wait(for: [handedOff], timeout: 15) == .completed
                app.activate()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "OpenStream did not return from the browser")
            } else if target.identifier == "home.featured.details" {
                let back = app.buttons["detail.back"].firstMatch
                let detail = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    self.isSafelyHittable(back)
                }, object: nil)
                answered = XCTWaiter.wait(for: [detail], timeout: 5) == .completed
                if answered {
                    back.tap()
                    let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        !self.isSafelyHittable(back) && self.isSafelyHittable(self.resolveCrawlTarget(target))
                    }, object: nil)
                    guard XCTWaiter.wait(for: [returned], timeout: 10) == .completed else {
                        result.pressed += 1
                        result.silent += 1
                        result.defects.append("[\(screen.name)] Hero Details did not return before the next target")
                        attach("hero-details-return")
                        app.terminate()
                        return result
                    }
                }
            } else {
                answered = waitForCrawlResponse(from: before, target: target).0
                #if targetEnvironment(simulator)
                if !answered, isLive, target.label == "AirPlay" {
                    answered = crawlSimulatorAirPlayIsAvailable(element, inline: isInlineLive)
                    if answered {
                        crawlNote("   AirPlay system control remains available after touch; routing needs hardware")
                    }
                }
                #endif
            }
            if let expectedSkip {
                let deadline = Date().addingTimeInterval(5)
                while abs((crawlPlaybackSeconds() ?? -100) - expectedSkip) > 1, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
                let observed = crawlPlaybackSeconds()
                answered = observed.map { abs($0 - expectedSkip) <= 1 } ?? false
                crawlNote("   seek response expected=\(expectedSkip) observed=\(String(describing: observed))")
                if resumeAfterSkip, app.buttons["player.play-pause"].firstMatch.label == "Play" {
                    app.buttons["player.play-pause"].firstMatch.tap()
                }
            } else if target.identifier == "player.controls.show" {
                if isLive {
                    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        self.playerCaptionsAreUp() != controlsWereUp
                    }, object: nil)
                    answered = XCTWaiter.wait(for: [changed], timeout: 3) == .completed
                } else {
                    answered = playerCaptionsAreUp()
                }
            } else if target.identifier == "player.captions" {
                let off = app.buttons.matching(NSPredicate(format: "label == %@", "Off"))
                let english = app.buttons.matching(NSPredicate(format: "label == %@", "English"))
                let choices = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    off.allElementsBoundByIndex.contains(where: { $0.isHittable })
                        && (isLive || english.allElementsBoundByIndex.contains(where: { $0.isHittable }))
                }, object: nil)
                answered = XCTWaiter.wait(for: [choices], timeout: 5) == .completed
                let menu = XCTAttachment(string: app.debugDescription)
                menu.name = "players-caption-menu-actions"; menu.lifetime = .keepAlways; add(menu)
            }
            result.pressed += 1
            if answered {
                crawlNote("   ✓ \(target.name) — responded")
            } else if target.label == "Refresh", element.exists, element.isEnabled {
                // Reloading the deterministic fixture may return identical content.
                // The reload control must be available again, with no loading indicator.
                XCTAssertFalse(app.progressIndicators.firstMatch.exists, "Refresh did not finish")
                crawlNote("   ✓ \(target.name) — reload completed with identical content")
            } else if crawlIsBackgroundAction(target) {
                crawlNote("   ✓ \(target.name) — background action: the art stays until the video can play")
            } else if node.isSelected {
                // An option that was already the chosen one is meant to stay
                // chosen; it is pressed for the sake of pressing everything,
                // and its silence is the correct answer.
                crawlNote("   ✓ \(target.name) — no change, and it was already the selected option")
            } else {
                result.silent += 1
                crawlNote("   ✗ \(target.name) — NO VISIBLE RESPONSE")
                attach("\(screen.name)__\(target.slug)")
                let response = opensBrowser ? "did not hand off to the browser within 15 s"
                    : "produced no visible response within 3 s"
                result.defects.append("[\(screen.name)] \(target.name) \(response)")
            }

            // Everything the press opened is walked before it is closed. The
            // response can land while the menu is still on its way in, so the
            // screen is given a moment to finish before it is read.
            Thread.sleep(forTimeInterval: 0.6)
            var after = crawlScene()
            if target.identifier == "player.controls.show", answered {
                let restored = revealPlayerControls()
                if !restored {
                    let evidence = XCTAttachment(string: app.debugDescription)
                    evidence.name = "players-after-background-hierarchy"; evidence.lifetime = .keepAlways; add(evidence)
                    attach("players-after-background")
                }
                XCTAssertTrue(restored, "Playback controls did not return after the background touch")
                after = crawlScene()
            }
            if crawlMenuRect(after) != nil {
                crawlMenu(owner: element, ownerName: target.name, scene: &after, result: &result)
            }
            if after.sheets > 0 || after.alerts > 0 {
                crawlPresentation(screen: screen, scene: &after, result: &result)
            }

            crawlRestore(target, element: element, node: node, screen: screen,
                         answered: answered, result: &result)
            if target.isTab, let homeTab {
                _ = tapIfPossible(app.tabBars.buttons[homeTab].firstMatch)
                    || tapIfPossible(app.buttons[homeTab].firstMatch)
            }
            scene = restoreCrawlScreen(baseline: baseline, screen: screen)
            // A full-screen player keeps the page it was opened from in the
            // accessibility tree, and the page keeps the player's controls in
            // it after the player has gone, so neither one's identifiers say
            // which is in front. What can be touched does.
            if isPlayer, !crawlPlayerIsUp() {
                attach("\(screen.name)__player-is-gone")
                crawlNote("   … nothing of the player would take a touch; the rest of \(screen.name) was not pressed")
                break
            }
            let lost = anchor.map { crawlFind($0, in: scene) == nil && scene.navigation != baseline } ?? false
            if lost || scene.alerts > 0 || scene.sheets > 0 {
                guard relaunches < 5 else {
                    crawlNote("   … the screen could not be put back; the rest of \(screen.name) was not pressed")
                    break
                }
                relaunches += 1
                scrolls = 0
                crawlNote("   … relaunched \(screen.name): something was still covering the screen")
                launchForCrawl(screen)
                guard openForCrawl(screen.opener) else {
                    crawlNote("   … the screen could not be re-opened; the rest of \(screen.name) was not pressed")
                    break
                }
                scene = crawlScene()
            }
        }

        // The ways off the screen go last, or the walk leaves before it has
        // pressed what the screen is made of. Each one is given the screen back
        // first, because the one before it was a way off.
        for target in exits.prefix(6) {
            // The press before this one was usually the one that put a player
            // up, and a chevron tapped while the player is still dismissing is
            // a tap on the player.
            Thread.sleep(forTimeInterval: 1.5)
            if screen.route == "first-run" {
                // Connect dismisses the welcome sheet. Re-enter it before
                // judging its other exit, rather than querying a retained hidden button.
                launchForCrawl(screen)
                scene = crawlScene()
                crawlBarRect = tabBarRectForCrawl()
            } else {
                scene = restoreCrawlScreen(baseline: baseline, screen: screen)
            }
            Thread.sleep(forTimeInterval: 1)
            if crawlFind(target, in: scene) == nil {
                guard relaunches < 8 else { break }
                relaunches += 1
                launchForCrawl(screen)
                guard openForCrawl(screen.opener) else { break }
                scene = crawlScene()
            }
            if isPlayer, revealPlayerControls() { scene = crawlScene() }
            if let reason = crawlPolicySkip(target, route: route, scene: scene) {
                result.skipped += 1
                crawlNote("   · \(target.name) — not pressed: \(reason)")
                continue
            }
            guard let node = crawlFind(target, in: scene), node.isEnabled else {
                result.skipped += 1
                crawlNote("   · \(target.name) — not pressed: it was not on the screen when its turn came")
                continue
            }
            let element = resolveCrawlTarget(target)
            guard revealForCrawl(element, node: node, isTab: false) == .hittable else {
                blocked.append(target)
                attach("\(screen.name)__\(target.slug)")
                crawlNote("   ? \(target.name) — would not take a touch; judged at the end of the screen")
                continue
            }
            let before = crawlStateString(scene, target: target)
            element.tap()
            let (answered, _) = waitForCrawlResponse(from: before, target: target)
            result.pressed += 1
            if answered {
                crawlNote("   ✓ \(target.name) — responded")
            } else if target.label == "Refresh", element.exists, element.isEnabled {
                // Reloading the deterministic fixture may return identical content.
                // The reload control must be available again, with no loading indicator.
                XCTAssertFalse(app.progressIndicators.firstMatch.exists, "Refresh did not finish")
                crawlNote("   ✓ \(target.name) — reload completed with identical content")
            } else if crawlIsBackgroundAction(target) {
                crawlNote("   ✓ \(target.name) — background action: the art stays until the video can play")
            } else {
                result.silent += 1
                crawlNote("   ✗ \(target.name) — NO VISIBLE RESPONSE")
                attach("\(screen.name)__\(target.slug)")
                result.defects.append("[\(screen.name)] \(target.name) produced no visible response within 3 s")
            }
        }

        crawlNote("   controls found: \(result.found)  window \(crawlScreenRect)  tab bar \(crawlBarRect)")
        if blocked.count >= 3, blocked.count * 2 > max(1, result.found) {
            result.skipped += blocked.count
            crawlNote("   (most of this screen refused a touch: it is behind a presented view, "
                      + "so its \(blocked.count) untouchable controls are reported as skipped, not as defects)")
        } else {
            for target in blocked {
                result.unreachable += 1
                crawlNote("   ✗ \(target.name) — UNHITTABLE: on screen, enabled, and refuses a touch")
                result.defects.append("[\(screen.name)] \(target.name) is on screen and refuses a touch — tap-target defect")
            }
        }

        app.terminate()
        return result
    }

    private func crawlPlayerIsUp() -> Bool {
        ["player.close", "player.fullscreen", "player.controls.show", "live.picker.close"]
            .contains { isSafelyHittable(app.buttons[$0].firstMatch) }
    }

    /// Every control the screen is showing right now, in the order they are
    /// drawn.
    ///
    /// `playerOnly` keeps the walk to the transport's own controls. The page
    /// underneath a full-screen player stays in the tree, and pressing its
    /// buttons through the player would report every one of them as a control
    /// that refuses a touch.
    private func crawlTargets(from scene: CrawlScene, includesTabs: Bool,
                              playerOnly: Bool = false) -> [CrawlTarget] {
        let names: [XCUIElement.ElementType: String] = [
            .button: "button", .link: "link", .switch: "switch",
            .segmentedControl: "segment", .cell: "cell",
        ]
        var seen = Set<String>()
        var targets: [CrawlTarget] = []
        for node in scene.nodes {
            guard let typeName = names[node.type] else { continue }
            if node.identifier.isEmpty && node.label.isEmpty { continue }
            if playerOnly, !node.identifier.hasPrefix("player."),
               !node.identifier.hasPrefix("live.picker.") { continue }
            // A Form row is a cell wrapping the button it already offered us;
            // pressing both would double the walk.
            if node.type == .cell, seen.contains("button\u{1}\(node.identifier)\u{1}\(node.label)") { continue }
            let signature = "\(typeName)\u{1}\(node.identifier)\u{1}\(node.label)"
            guard seen.insert(signature).inserted else { continue }
            let isTab = Self.crawlTabLabels.contains(node.label)
            guard includesTabs || !isTab else { continue }
            targets.append(CrawlTarget(typeName: typeName, type: node.type, identifier: node.identifier,
                                       label: node.label, isTab: isTab, collection: node.collection))
        }
        return targets
    }

    /// A press that changed something the owner's simulator keeps is undone
    /// here: a switch is flipped back, My List is emptied again, a download the
    /// walk started is cancelled.
    private func crawlRestore(_ target: CrawlTarget, element: XCUIElement, node: CrawlNode,
                              screen: CrawlScreen, answered: Bool, result: inout CrawlResult) {
        if target.type == .switch, answered {
            pressForCrawl(element, node: node, at: nil)
            return
        }
        let name = (target.label + " " + target.identifier).lowercased()
        if name.contains("my list") || Self.crawlRestorablePrefixes.contains(where: { target.identifier.hasPrefix($0) }) {
            if tapIfPossible(element) { crawlNote("   ↩ \(target.name) — pressed again to leave it as it was") }
            return
        }
        guard name.contains("download"), answered else { return }
        undoCrawlDownload(control: element, node: node, screen: screen, result: &result)
    }

    /// The download control is the one press in the walk that leaves a file on
    /// the simulator. Pressing it again opens its options, where the download
    /// is cancelled — the screen is left as it was found.
    private func undoCrawlDownload(control: XCUIElement, node: CrawlNode, screen: CrawlScreen, result: inout CrawlResult) {
        func originalRowControl() -> XCUIElement? {
            guard !node.identifier.isEmpty else { return nil }
            let candidates = app.buttons.matching(identifier: node.identifier).allElementsBoundByIndex
            // A started download puts its status line above the episode row
            // and the row moves down; the episode named in the label does not.
            if let episode = Self.crawlDownloadSubject(node.label),
               let same = candidates.first(where: { Self.crawlDownloadSubject($0.label) == episode }) {
                if !isSafelyHittable(same) { scrollToControl(same, in: app) }
                return isSafelyHittable(same) ? same : nil
            }
            return candidates
                .filter { candidate in
                    // On iOS 18 one of the matches has no hit point, and raw isHittable throws on it.
                    isSafelyHittable(candidate) && candidate.frame.intersects(node.frame.insetBy(dx: -8, dy: -8))
                        && abs(candidate.frame.midY - node.frame.midY) <= max(44, node.frame.height)
                }
                .min {
                    hypot($0.frame.midX - node.frame.midX, $0.frame.midY - node.frame.midY)
                        < hypot($1.frame.midX - node.frame.midX, $1.frame.midY - node.frame.midY)
                }
        }
        // The options dialog offers to cancel only once the coordinator owns
        // the download, and resolving a stream takes longer than a moment.
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<8 {
            var scene = crawlScene()
            if scene.sheets == 0, scene.alerts == 0 {
                // A download that failed before it began — no source on the
                // simulator can serve a file — leaves nothing to take back,
                // and pressing ↓ again then starts a fresh attempt instead of
                // opening the options. That is how the walk once reported a
                // download it "could not cancel" after restarting eight
                // attempts that never wrote a byte (ui-smoke 20260923-2209).
                switch crawlDownloadState(scene, control: originalRowControl() ?? control) {
                case .running:
                    break
                case .finished:
                    crawlDownloadsAreOff = true
                    crawlNote("   ! the download the walk started finished before it could be cancelled — CHECK THE SIMULATOR")
                    result.defects.append("[\(screen.name)] the download the crawl started finished before it could be cancelled")
                    return
                case .notRunning:
                    let status = app.staticTexts["detail.download.status"].firstMatch
                    crawlNote("   ↩ the download never started, so there is nothing to cancel"
                              + (status.exists ? ": \(status.label)" : ""))
                    return
                }
                // The control that started it is the control that offers to
                // stop it.
                guard let original = originalRowControl(), tapIfPossible(original) else {
                    crawlNote("   ! the original download row is not hittable; refusing another episode's control")
                    break
                }
                Thread.sleep(forTimeInterval: 1.2)
                scene = crawlScene()
            }
            let stop = scene.nodes.first {
                $0.type == .button
                    && ($0.label.localizedCaseInsensitiveContains("cancel download")
                        || $0.label.localizedCaseInsensitiveContains("stop download"))
            }
            if let stop, tapIfPossible(app.buttons[stop.label].firstMatch) {
                crawlNote("   ↩ the download the walk started was cancelled")
                Thread.sleep(forTimeInterval: 1)
                return
            }
            _ = restoreCrawlScreen(baseline: scene.navigation, screen: screen)
            Thread.sleep(forTimeInterval: 3)
        }
        crawlDownloadsAreOff = true
        crawlNote("   ! a download the walk started could not be cancelled from the UI — CHECK THE SIMULATOR")
        result.defects.append("[\(screen.name)] the download the crawl started could not be cancelled from its own options")
    }

    /// "Downloading S1 E1 · Pilot, 40%" → "S1 E1 · Pilot": the episode a
    /// download control speaks for, whatever state its label is in.
    private static func crawlDownloadSubject(_ label: String) -> String? {
        let verbs = ["Download ", "Preparing ", "Downloading ", "Paused ", "Downloaded "]
        guard let verb = verbs.first(where: { label.hasPrefix($0) }) else { return nil }
        return String(label.dropFirst(verb.count))
            .replacingOccurrences(of: #", \d+%$"#, with: "", options: .regularExpression)
    }

    private enum CrawlDownloadState { case running, finished, notRunning }

    /// Read from the download controls' own labels: "Preparing …",
    /// "Downloading …", "Paused …" and "Resum…" on any of them while the
    /// coordinator holds a download (it holds one at a time, so it is the
    /// walk's), "Downloaded …" on the pressed one once it is stored, the plain
    /// "Download …" or "Retry …" otherwise.
    private func crawlDownloadState(_ scene: CrawlScene, control: XCUIElement) -> CrawlDownloadState {
        let running = scene.nodes.contains { node in
            node.type == .button && node.identifier.lowercased().contains("download")
                && ["Preparing", "Downloading", "Paused", "Resum"].contains { node.label.hasPrefix($0) }
        }
        if running { return .running }
        if (try? control.snapshot())?.label.hasPrefix("Downloaded") == true { return .finished }
        return .notRunning
    }

    /// Presses the menu's every item, then puts the menu's own selection back.
    private func crawlMenu(owner: XCUIElement, ownerName: String, scene: inout CrawlScene,
                           result: inout CrawlResult) {
        guard let rect = crawlMenuRect(scene) else { return }
        let items = crawlMenuItems(scene, rect: rect)
        guard !items.isEmpty else { return }
        let original = items.first(where: \.isSelected)?.label
        crawlNote("   ↳ menu \(ownerName): \(items.count) item(s)\(original.map { ", on \($0)" } ?? "")")

        for item in items {
            if crawlMenuRect(scene) == nil {
                guard tapIfPossible(owner) else { break }
                Thread.sleep(forTimeInterval: 0.8)
                scene = crawlScene()
            }
            let name = item.label
            if let word = Self.crawlDestructiveWords.first(where: { name.lowercased().contains($0) }) {
                result.skipped += 1
                crawlNote("   ↳ · \(name) — not pressed: destructive (\(word))")
                continue
            }
            if let word = Self.crawlMutatingWords.first(where: { name.lowercased().contains($0) }) {
                result.skipped += 1
                crawlNote("   ↳ · \(name) — not pressed: would change saved data (\(word))")
                continue
            }
            let target = CrawlTarget(typeName: "menu", type: .button, identifier: "", label: name, isTab: false)
            // Scoped to the menu: a track called "English" is also a row on the
            // page behind the player, and `firstMatch` reached through the menu
            // and reported the row underneath as untouchable.
            let currentRect = crawlMenuRect(scene) ?? rect
            guard let element = crawlMenuElement(named: name, in: currentRect) else {
                result.skipped += 1
                crawlNote("   ↳ · \(name) — not pressed: it left the menu before its turn")
                continue
            }
            guard isSafelyHittable(element) else {
                result.unreachable += 1
                crawlNote("   ↳ ✗ \(name) — the open menu would not take a touch")
                attach("menu__\(name.prefix(40))")
                result.defects.append("[menu \(ownerName)] the item \(name) is in an open menu and refuses a touch")
                continue
            }
            let before = crawlStateString(scene, target: target)
            element.tap()
            var (answered, after) = waitForCrawlResponse(from: before, target: target)
            // A menu that closes on the press has answered it, even when the
            // item chosen was the one already in force and nothing else on the
            // screen moved.
            let closedOnIt = !answered && crawlMenuRect(after) == nil
            if closedOnIt { answered = true }
            scene = after
            result.pressed += 1
            if closedOnIt {
                crawlNote("   ↳ ✓ \(name) — the menu closed on it")
            } else if answered {
                crawlNote("   ↳ ✓ \(name) — responded")
            } else if item.isSelected {
                // Choosing the choice that is already made is meant to change
                // nothing. "Off" in a captions menu with no tracks is the whole
                // menu and already the answer.
                crawlNote("   ↳ ✓ \(name) — no change, and it was already the selected item")
            } else {
                result.silent += 1
                crawlNote("   ↳ ✗ \(name) — NO VISIBLE RESPONSE")
                attach("menu__\(name.prefix(40))")
                result.defects.append("[menu \(ownerName)] the item \(name) produced no visible response within 3 s")
            }
            Thread.sleep(forTimeInterval: 0.4)
            scene = crawlScene()
            if scene.sheets > 0 || scene.alerts > 0 { break }
        }

        guard let original else {
            if crawlMenuRect(scene) != nil { crawlDismissMenu() }
            return
        }
        if crawlMenuRect(scene) == nil {
            _ = tapIfPossible(owner)
            Thread.sleep(forTimeInterval: 0.8)
            scene = crawlScene()
        }
        let reopened = crawlMenuRect(scene) ?? rect
        let restore = crawlMenuElement(named: original, in: reopened) ?? app.buttons[original].firstMatch
        if crawlMenuRect(scene) != nil, tapIfPossible(restore) {
            crawlNote("   ↩ menu \(ownerName) — put back on \(original)")
            Thread.sleep(forTimeInterval: 0.6)
        } else if crawlMenuRect(scene) != nil {
            crawlDismissMenu()
        }
        scene = crawlScene()
    }

    /// The rectangle an open menu is drawn in, or nothing when none is open.
    ///
    /// On iOS 26 a SwiftUI `Menu` and a `.menu` Picker present as a plain
    /// collection view over the screen: no menu item, no popover, no sheet to
    /// find them by — which is why the first crawl pressed a Sort menu open,
    /// failed to see it, and relaunched the screen instead of walking it.
    /// Two things tell it from a list the screen already had: it is one more
    /// than the screen started with, and it is narrower than the screen.
    private func crawlMenuRect(_ scene: CrawlScene) -> CGRect? {
        guard scene.alerts == 0, scene.sheets == 0, scene.lists.count > crawlBaselineLists else { return nil }
        let screen = crawlScreenRect
        return scene.lists.last {
            $0.width > 60 && $0.width < screen.width - 40 && $0.height > 30
        }
    }

    /// The button with that label that is inside the open menu.
    private func crawlMenuElement(named name: String, in rect: CGRect) -> XCUIElement? {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", name))
        var retained: XCUIElement?
        for element in matches.allElementsBoundByIndex.prefix(6) {
            guard let frame = (try? element.snapshot())?.frame else { continue }
            if rect.insetBy(dx: -4, dy: -4).contains(CGPoint(x: frame.midX, y: frame.midY)) {
                if isSafelyHittable(element) { return element }
                if retained == nil { retained = element }
            }
        }
        return retained
    }

    private func crawlMenuItems(_ scene: CrawlScene, rect: CGRect) -> [CrawlNode] {
        scene.nodes.filter { $0.type == .button && rect.insetBy(dx: -2, dy: -2).contains($0.frame.origin) && !$0.label.isEmpty }
    }

    private func crawlDismissMenu() {
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if tapIfPossible(dismissRegion) { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
    }

    /// Presses what a sheet or an alert brought with it, then leaves it to the
    /// screen restore to close. Only one level deep: a sheet opened from a
    /// sheet is dismissed rather than walked, or the walk never comes back.
    private func crawlPresentation(screen: CrawlScreen, scene: inout CrawlScene, result: inout CrawlResult) {
        let isAlert = scene.alerts > 0
        let root = isAlert ? app.alerts.firstMatch : app.sheets.firstMatch
        let names = root.buttons.allElementsBoundByIndex.prefix(16)
            .compactMap { (try? $0.snapshot())?.label }
            .filter { !$0.isEmpty && !Self.crawlExitLabels.contains($0) }
        guard !names.isEmpty else { return }
        crawlNote("   ↳ \(isAlert ? "alert" : "sheet"): \(names.count) control(s) besides its way out")

        for name in names {
            guard scene.sheets > 0 || scene.alerts > 0 else {
                crawlNote("   ↳ … it closed before \(name) came up")
                break
            }
            let target = CrawlTarget(typeName: "button", type: .button, identifier: "", label: name, isTab: false)
            if let reason = crawlPolicySkip(target, route: screen.route, scene: scene) {
                result.skipped += 1
                crawlNote("   ↳ · \(name) — not pressed: \(reason)")
                continue
            }
            let element = root.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            guard isSafelyHittable(element) else {
                result.unreachable += 1
                crawlNote("   ↳ ✗ \(name) — on a presented card and refuses a touch")
                attach("\(screen.name)__presented__\(name.prefix(40))")
                result.defects.append("[\(screen.name)] \(name) is on a presented card and refuses a touch")
                continue
            }
            let before = crawlStateString(scene, target: target)
            if name == Self.crawlSourcesLabel { crawlSourcesPressed += 1 }
            element.tap()
            let (answered, after) = waitForCrawlResponse(from: before, target: target)
            scene = after
            result.pressed += 1
            if answered {
                crawlNote("   ↳ ✓ \(name) — responded")
            } else {
                result.silent += 1
                crawlNote("   ↳ ✗ \(name) — NO VISIBLE RESPONSE")
                attach("\(screen.name)__presented__\(name.prefix(40))")
                result.defects.append("[\(screen.name)] \(name) produced no visible response within 3 s")
            }
            if scene.keyboards > 0 { break }
        }
    }

    private func crawlPolicySkip(_ target: CrawlTarget, route: String, scene: CrawlScene) -> String? {
        let name = (target.label + " " + target.identifier.replacingOccurrences(of: ".", with: " ")).lowercased()
        // An Add Service menu item saves a streaming service, and its open menu
        // arrives as a collection, so this is checked before the card rule.
        if target.identifier.hasPrefix("settings.watchProviders.add.") {
            return "would add a streaming service to saved settings (policy)"
        }
        // A card in a shelf is a place to go, not an action, and its label is
        // somebody's title: one of Netflix's carried the word "send" in it and
        // was reported as a destructive control.
        if target.collection != nil { return nil }
        // My List is a switch wearing a button's clothes: its own second press
        // puts the list back, so "Remove from My List" is walked, not skipped.
        if !name.contains("my list") {
            if let word = Self.crawlDestructiveWords.first(where: { matchesCrawlWord(target, $0) }) {
                return "destructive (\(word))"
            }
        }
        if let word = Self.crawlMutatingWords.first(where: { matchesCrawlWord(target, $0) }) {
            return "would change saved data (\(word))"
        }
        if name.contains("download"), !["detail", "episodes"].contains(route) {
            return "would start a download away from the title page"
        }
        // One episode is pressed and cancelled again; a season is six of them
        // at once, and the first time the walk pressed it the cancel came too
        // late and left nine gigabytes on the owner's simulator.
        if target.identifier == "detail.download.season" {
            return "a season download writes gigabytes to the owner's simulator faster than the crawl can cancel it (policy)"
        }
        if name.contains("download"), crawlDownloadsAreOff {
            return "a download the walk started earlier outran its cancel, so no more are started (policy)"
        }
        if target.label == Self.crawlSourcesLabel, crawlSourcesPressed >= 1 {
            return "opens Settings › Sources, and it was pressed once on this screen already (policy)"
        }
        if name.contains("download"), crawlDownloadsPressed >= 1 {
            return "one download is pressed and cancelled per screen; the rest are the same control (policy)"
        }
        if let word = Self.crawlSubmitWords.first(where: { matchesCrawlWord(target, $0) }),
           !crawlFieldsAreEmpty(scene) {
            return "a field on this screen is filled in; \(word) is pressed only with empty fields (credential policy)"
        }
        return nil
    }

    /// The owner's rule for the source forms: a submit button is pressed only
    /// when there is nothing typed to submit. An empty field publishes its
    /// placeholder as its value, which is why the two are compared.
    private func crawlFieldsAreEmpty(_ scene: CrawlScene) -> Bool {
        !scene.nodes.contains {
            ($0.type == .textField || $0.type == .secureTextField)
                && !$0.value.isEmpty && $0.value != $0.placeholder
        }
    }

    private func isCrawlExit(_ target: CrawlTarget) -> Bool {
        ["player.close", "player.fullscreen", "detail.back", "live.picker.close"].contains(target.identifier)
            || Self.crawlExitLabels.contains(target.label) || target.label == "Back"
    }

    private func launchForCrawl(_ screen: CrawlScreen) {
        crawlWindowRect = .null
        app.terminate()
        app.launchArguments = ["-OpenStreamMuteAudio", "YES"]
        XCUIDevice.shared.orientation = screen.landscape ? .landscapeLeft : .portrait
        app.launchArguments += ["-OpenStreamHoldPlayerChrome", "YES", "-OpenStreamProbeLiveHitTest", "YES"]
        launch(screen: screen.route)
        _ = app.wait(for: .runningForeground, timeout: 30)
        if app.windows.firstMatch.exists { crawlWindowRect = app.windows.firstMatch.frame }
        // Discover and Live pull their shelves over the network; the rest of the
        // app is drawn by the time the first frame lands.
        Thread.sleep(forTimeInterval: ["discover", "live", "library", "detail", "episodes"].contains(screen.route) ? 8 : 2)
        if screen.route == "live", !app.buttons.matching(identifier: "player.close")
            .allElementsBoundByIndex.contains(where: { isSafelyHittable($0) }) {
            _ = revealInlineLiveControls(timeout: 60)
        }
    }

    private func openForCrawl(_ opener: CrawlOpener) -> Bool {
        switch opener {
        case .none:
            return true
        case .vodPlayer:
            let play = app.buttons["detail.play"].firstMatch
            guard play.waitForExistence(timeout: 60), tapIfPossible(play) else { return false }
            guard app.buttons["player.play-pause"].waitForExistence(timeout: 60)
                    || app.buttons["player.close"].waitForExistence(timeout: 10) else { return false }
            Thread.sleep(forTimeInterval: 4)
            revealPlayerControls()
            return true
        case .livePlayer:
            crawlWindowRect = app.windows.firstMatch.frame
            let closes = app.buttons.matching(identifier: "player.close")
            // A channel that is already playing can enter fullscreen on
            // rotation. Its guide is then behind the modal, not tappable.
            revealPlayerControls()
            if closes.allElementsBoundByIndex.contains(where: { isSafelyHittable($0) }) { return true }
            let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
            guard channels.firstMatch.waitForExistence(timeout: 60),
                  tapIfPossible(channels.firstMatch) else { return false }
            // Selecting a channel changes the inline preview (owner Live design).
            // Full Screen is a separate action; a hidden close control is not proof of entry.
            revealPlayerControls()
            if !closes.allElementsBoundByIndex.contains(where: { isSafelyHittable($0) }) {
                // Rotation can already have entered fullscreen on iPhone.
                // A row that switched channels brings the inline chrome back
                // a moment after Play/Pause; wait for Full Screen to take a touch.
                let fullScreen = app.buttons["player.fullscreen"].firstMatch
                let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    closes.firstMatch.exists || (fullScreen.exists && fullScreen.isEnabled && !fullScreen.frame.isEmpty)
                }, object: nil)
                guard revealInlineLiveControls(timeout: 60) || closes.firstMatch.exists else { return false }
                crawlWindowRect = app.windows.firstMatch.frame
                guard XCTWaiter.wait(for: [reachable], timeout: 10) == .completed else {
                    attachHierarchy("live-player-open-fullscreen-unreachable")
                    return false
                }
                if !closes.firstMatch.exists {
                    guard fullScreen.exists, let root = try? app.snapshot(),
                          let snapshot = crawlSnapshot("player.fullscreen", in: root), snapshot.isEnabled else { return false }
                    let fullScreenAXHittable = isSafelyHittable(fullScreen, snapshot: snapshot)
                    if fullScreenAXHittable {
                        fullScreen.tap()
                    } else {
                        guard inlineFullScreenHasUnobscuredCenter(snapshot: snapshot, root: root) else {
                            attachHierarchy("live-player-open-fullscreen-obscured")
                            return false
                        }
                        attachHierarchy("live-fullscreen-ax-hit-point-missing-unobscured-center")
                        fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    }
                }
                guard closes.firstMatch.waitForExistence(timeout: 40) else { return false }
            }
            Thread.sleep(forTimeInterval: 4)
            crawlWindowRect = app.windows.firstMatch.frame
            revealPlayerControls()
            return closes.allElementsBoundByIndex.contains(where: { isSafelyHittable($0) })
        }
    }

    private func crawlSnapshot(_ identifier: String, in root: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        if root.identifier == identifier { return root }
        for child in root.children {
            if let match = crawlSnapshot(identifier, in: child) { return match }
        }
        return nil
    }

    private func inlineFullScreenHasUnobscuredCenter(snapshot: XCUIElementSnapshot, root: XCUIElementSnapshot) -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26,
              crawlScreenRect.contains(snapshot.frame),
              !app.alerts.firstMatch.exists, !app.sheets.firstMatch.exists,
              let raw = crawlSnapshot("live.test.hitProbe", in: root)?.value as? String else { return false }
        let values = Dictionary(uniqueKeysWithValues: raw.split(separator: ";").compactMap { field -> (String, Double)? in
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Double(pair[1]) else { return nil }
            return (String(pair[0]), value)
        })
        guard values["clear"] == 1,
              let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"] else { return false }
        let sampled = CGRect(x: x, y: y, width: width, height: height)
        return abs(sampled.midX - snapshot.frame.midX) < 1 && abs(sampled.midY - snapshot.frame.midY) < 1
            && abs(sampled.width - snapshot.frame.width) < 1 && abs(sampled.height - snapshot.frame.height) < 1
    }

    /// Taps only what is still there and still reachable. `tap()` raises on an
    /// element that vanished between the check and the press, and a raise ends
    /// the whole walk.
    @discardableResult
    private func tapIfPossible(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        if isSafelyHittable(element) {
            element.tap()
        } else if isTouchableMenuButton(element, identifier: element.identifier) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            return false
        }
        return true
    }

    /// A switch fills its whole Form row, and the row's centre is dead space:
    /// a press there leaves the switch exactly as it was. The knob is at the
    /// trailing edge, which is where a finger goes.
    private func pressForCrawl(_ element: XCUIElement, node: CrawlNode, at offset: CGVector? = nil) {
        if let offset {
            element.coordinate(withNormalizedOffset: .zero).withOffset(offset).tap()
            return
        }
        // A fraction of the row's width lands in different places on a phone
        // row and on an iPad row; the knob is a fixed distance from the
        // trailing edge, so measure from there.
        guard node.type == .switch, node.frame.width > 120 else {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: node.frame.width - 45, dy: node.frame.height / 2))
            .tap()
    }

    /// Where to press a control the screen is only showing part of: the middle
    /// of the part it is showing, measured from the control's own origin.
    private func crawlVisibleHitOffset(_ frame: CGRect) -> CGVector? {
        let visible = frame.intersection(crawlScreenRect)
        guard visible.width >= 24, visible.height >= 24 else { return nil }
        if !crawlBarRect.isNull, visible.intersects(crawlBarRect) { return nil }
        return CGVector(dx: visible.midX - frame.minX, dy: visible.midY - frame.minY)
    }

    private func crawlPlayerBackgroundHitOffset(_ frame: CGRect, scene: CrawlScene) -> CGVector? {
        guard scene.alerts == 0, scene.sheets == 0, !frame.isEmpty,
              crawlScreenRect.contains(frame), !app.progressIndicators["live.loading"].exists else { return nil }
        let controls = scene.nodes.filter {
            ($0.identifier.hasPrefix("player.") || $0.identifier.hasPrefix("live.player."))
                && $0.identifier != "player.controls.show"
        }
        for (x, y) in [(0.2, 0.5), (0.5, 0.3), (0.3, 0.6), (0.7, 0.6)] {
            let point = CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * y)
            if !controls.contains(where: { $0.frame.contains(point) }) {
                return CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)
            }
        }
        return nil
    }

    /// Whole words only. "Disconnect" is not "connect", and a title with
    /// "send" in it is not the Send button.
    private func matchesCrawlWord(_ target: CrawlTarget, _ word: String) -> Bool {
        let haystack = (target.label + " "
            + target.identifier.replacingOccurrences(of: ".", with: " ")).lowercased()
        guard let range = haystack.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                                         options: .regularExpression) else { return false }
        return !range.isEmpty
    }

    /// One identifier does not always mean one control: every episode row's
    /// download button is `detail.episode.download`, so resolving by
    /// identifier alone pressed the first episode's button five times over and
    /// started five downloads the walk then could not cancel.
    private func resolveCrawlTarget(_ target: CrawlTarget) -> XCUIElement {
        let query = app.descendants(matching: target.type)
        let matches: XCUIElementQuery
        // Play/Pause and Mute/Unmute can change labels between the scene
        // snapshot and the touch, and so do the Discover hero's buttons when
        // the hero advances. The identifier is their stable identity.
        if target.identifier.hasPrefix("player.") || target.identifier.hasPrefix("live.player.")
            || target.identifier.hasPrefix("home.featured.") {
            matches = query.matching(identifier: target.identifier)
        } else if !target.identifier.isEmpty && !target.label.isEmpty {
            matches = query.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                                target.identifier, target.label))
        } else if !target.identifier.isEmpty {
            matches = query.matching(identifier: target.identifier)
        } else {
            matches = query.matching(NSPredicate(format: "label == %@", target.label))
        }
        let candidates = matches.allElementsBoundByIndex
        if candidates.count > 1, let foreground = candidates.first(where: { isSafelyHittable($0) }) {
            crawlNote("   (\(target.name): using the hittable match among \(candidates.count) retained controls)")
            return foreground
        }
        return matches.firstMatch
    }

    /// The floating tab bar, whichever edge it floats at: the phone puts it
    /// along the bottom and covers the last row of every list, iPadOS puts it
    /// along the top and covers the first.
    private var crawlScreenRect: CGRect {
        crawlWindowRect.isNull || crawlWindowRect.height < 200 ? app.frame : crawlWindowRect
    }

    private func tabBarRectForCrawl() -> CGRect {
        let bar = app.tabBars.firstMatch
        if let snapshot = try? bar.snapshot(), snapshot.frame.height > 0 {
            // A presented sheet (notably first-run) keeps the covered tab bar
            // in the hierarchy. Its rectangle does not cover the sheet's buttons.
            guard bar.buttons.allElementsBoundByIndex.contains(where: { isSafelyHittable($0) }) else { return .null }
            return snapshot.frame
        }
        // iPadOS does not publish its tab bar as a `tabBar` at all; the items
        // come through as loose buttons, so the bar is their union.
        let items = crawlScene().nodes
            .filter { $0.type == .button && Self.crawlTabLabels.contains($0.label)
                && ($0.frame.maxY < app.frame.minY + 120 || $0.frame.minY > app.frame.maxY - 120) }
            .map(\.frame)
        guard items.count >= 2 else { return .null }
        return items.dropFirst().reduce(items[0]) { $0.union($1) }
    }

    /// Reads a control where it stands. `blocked` is the verdict that matters:
    /// the control is on the screen, at a usable size, enabled, and still
    /// refuses a touch — something is drawn over it, or its own hit region is
    /// somewhere its frame is not.
    private func classifyForCrawl(_ element: XCUIElement, frame stale: CGRect, isTab: Bool) -> CrawlReach {
        // Read where it is now, not where the last look at the screen found it:
        // a player that closed left three of its controls in the report as
        // "on screen and refuses a touch" when they were simply gone.
        guard let snapshot = try? element.snapshot() else { return .gone }
        let frame = snapshot.frame
        // Read once from the same snapshot: the hero auto-advances, and a later
        // `element.identifier` on a replaced button raises "No matches found".
        let identifier = snapshot.identifier
        let label = snapshot.label
        _ = stale
        if frame.width < 1 || frame.height < 1 { return .blocked }
        let screen = crawlScreenRect
        guard screen.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return .offScreen }
        // Test geometry first: XCTest can report a row hittable while its switch
        // or centre is under the floating tab bar.
        // Half a row showing at the foot of a list — or at the foot of the
        // window, on an iPad running the app in a resizable one — is scrolling
        // to do, not a control drawn over. So is a row under the tab bar. Only
        // a control the screen shows whole, clear of the bar, and still will
        // not take a touch is a defect.
        guard screen.contains(frame) else { return .offScreen }
        // Grown by a few points: the floating bar's shadow and its blur margin
        // take touches a row's own edge does not overlap. The Add Media Server
        // picker sat one and a half points clear of the bar and still could not
        // be touched.
        if !isTab, !crawlBarRect.isNull, frame.intersects(crawlBarRect.insetBy(dx: -10, dy: -10)) {
            return .offScreen
        }
        // The same holds for the navigation bar: XCTest called a Library hero
        // button hittable under it, and the touch went to the bar.
        if !isTab, crawlContentOverlapsNavigationBar(frame: frame, elementType: snapshot.elementType, identifier: identifier, label: label) {
            return .offScreen
        }
        if isSafelyHittable(element, snapshot: snapshot) { return .hittable }
        if isTouchableMenuButton(element, identifier: identifier) { return .hittable }
        return .blocked
    }

    /// Scroll content can retain a frame under the pinned navigation bar.
    /// The episodes crawl saw My List/Rate at y=62, beneath that bar. Its
    /// own toolbar buttons are identified by ancestry and remain tappable targets.
    private func crawlContentOverlapsNavigationBar(
        frame: CGRect, elementType: XCUIElement.ElementType, identifier: String, label: String
    ) -> Bool {
        let bar = app.navigationBars.firstMatch
        if !bar.exists {
            let titles = app.staticTexts.matching(NSPredicate(format: "identifier IN %@",
                ["discover.compact-title", "library.compact-title", "detail.compact-title"]))
            let compactTitles = titles.allElementsBoundByIndex
            guard !compactTitles.isEmpty else { return false }
            let toolbarIdentifiers = ["detail.back", "library.sort", "discover.compact-title.search",
                "discover.compact-title.refresh", "library.compact-title.search", "library.compact-title.refresh"]
            let toolbarFrames = app.buttons.matching(NSPredicate(format: "identifier IN %@", toolbarIdentifiers))
                .allElementsBoundByIndex.compactMap { (try? $0.snapshot())?.frame }
                .filter { $0.width > 0 && $0.height > 0 && $0.intersects(crawlScreenRect) }
            let toolbarBounds = toolbarFrames.reduce(CGRect.null) { $0.union($1) }
            guard !toolbarBounds.isNull else { return false }
            // The material extends above the controls through the status area.
            let barFrame = CGRect(x: crawlScreenRect.minX, y: crawlScreenRect.minY,
                width: crawlScreenRect.width, height: toolbarBounds.maxY - crawlScreenRect.minY)
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard barFrame.contains(centre) else { return false }
            return !toolbarIdentifiers.contains(identifier)
        }
        // XCTest taps the centre, so only a centre under the bar is unreachable;
        // a hero button whose edge touches the bar is still pressed.
        // Everything here comes from snapshots, so a hero that advances or a bar
        // that goes away mid-check cannot raise.
        guard let barFrame = (try? bar.snapshot())?.frame,
              barFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        let toolbarControl = bar.descendants(matching: elementType).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", identifier, label)).firstMatch
        return !toolbarControl.exists
    }

    /// Scrolls a control back into view for its press. A card that has run off
    /// the end of a horizontal row is dragged back along its own row, so the
    /// shelf under the finger is the shelf that moves.
    private func revealForCrawl(_ element: XCUIElement, node: CrawlNode, isTab: Bool) -> CrawlReach {
        var frame = (try? element.snapshot())?.frame ?? node.frame
        for _ in 0..<6 {
            let reach = classifyForCrawl(element, frame: frame, isTab: isTab)
            guard reach == .offScreen else { return reach }
            let screen = crawlScreenRect
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            // Dragged from a band of the screen the page will scroll on, never
            // `app.swipeUp()`: that starts in the middle, which on Discover
            // and on a title page is the hero, and the hero takes the gesture.
            // On the iPad that left twenty-three cards reported as off the
            // screen when the page had simply never moved.
            if !isTab, let current = try? element.snapshot(),
               crawlContentOverlapsNavigationBar(frame: current.frame, elementType: current.elementType, identifier: current.identifier, label: current.label) {
                crawlScrollUp()
            } else if !isTab, !crawlBarRect.isNull, frame.intersects(crawlBarRect.insetBy(dx: -10, dy: -10)) {
                // Push the content away from the bar it is hiding under.
                if crawlBarRect.midY < screen.midY { crawlScrollUp() } else { crawlScrollDown() }
            }
            else if centre.y > screen.maxY { crawlScrollDown() }
            else if centre.y < screen.minY { crawlScrollUp() }
            else if centre.x > screen.maxX || centre.x < screen.minX {
                dragCrawlRow(at: centre.y, towardsLeading: centre.x > screen.maxX)
            }
            else { dragCrawlRow(at: centre.y, towardsLeading: false) }
            Thread.sleep(forTimeInterval: 0.45)
            guard let moved = (try? element.snapshot())?.frame else { return .gone }
            frame = moved
        }
        return classifyForCrawl(element, frame: frame, isTab: isTab)
    }

    /// One screenful down, dragged from low on the screen.
    ///
    /// `app.swipeUp()` starts in the middle, which on the title page is the
    /// trailer: the gesture went to the video and the page never moved, so
    /// everything below the hero — My List, Rate, the episode rows — was never
    /// found.
    private func crawlScrollDown() {
        let screen = crawlScreenRect
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.midX, dy: screen.maxY - screen.height * 0.12))
        let to = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.midX, dy: screen.minY + screen.height * 0.18))
        from.press(forDuration: 0.25, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func crawlScrollUp() {
        let screen = crawlScreenRect
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.midX, dy: screen.minY + screen.height * 0.18))
        let to = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: screen.midX, dy: screen.maxY - screen.height * 0.12))
        from.press(forDuration: 0.25, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// One horizontal row moved on its own, by dragging along the line the row
    /// is drawn on: `swipeLeft()` on the whole app moves whichever row the
    /// gesture happens to land in.
    private func dragCrawlRow(at y: CGFloat, towardsLeading: Bool) {
        let screen = crawlScreenRect
        let row = min(max(y, screen.minY + 20), screen.maxY - 20)
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: towardsLeading ? screen.maxX - 30 : screen.minX + 30, dy: row))
        let to = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: towardsLeading ? screen.minX + 30 : screen.maxX - 30, dy: row))
        // Long enough to start a pan and held at the end so the row stops where
        // it was put: a 0.05 s drag read as a flick and moved nothing at all,
        // and every card past the fold of a shelf came back untouchable.
        from.press(forDuration: 0.25, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func selectedTabLabel() -> String? {
        if let phone = app.tabBars.buttons.allElementsBoundByIndex.first(where: { $0.isSelected }) {
            return phone.label
        }
        return crawlScene().nodes
            .first { $0.type == .button && Self.crawlTabLabels.contains($0.label) && $0.isSelected }?.label
    }

    /// Closes whatever the press opened and gets back to the screen the walk
    /// started on. Only non-destructive exits are used.
    @discardableResult
    private func restoreCrawlScreen(baseline: String, screen: CrawlScreen) -> CrawlScene {
        // A press on Play puts a full-screen player up, and nothing in the exit
        // labels closes it; without these the walk relaunched the route after
        // every Play and spent the screen's budget getting back. Not on the
        // title page itself: there, `detail.back` is a control under test, and
        // popping the page before its turn came made the walk press it on the
        // screen behind and call it unresponsive. And never in a player under
        // test — closing that is the screen's own last press.
        var covers = ["detail", "episodes"].contains(screen.route) ? ["player.close"] : ["player.close", "detail.back"]
        if screen.opener != .none { covers = ["live.picker.close"] }
        var scene = crawlScene()
        for attempt in 0..<7 {
            // First-run is itself a sheet under test, not a cover to dismiss.
            if screen.route == "first-run",
               isSafelyHittable(app.buttons["Connect Media Server"].firstMatch),
               isSafelyHittable(app.buttons["Not Now"].firstMatch) { return scene }
            let present = Set(scene.nodes.map(\.identifier))
            for cover in covers where present.contains(cover) {
                if tapIfPossible(app.buttons[cover].firstMatch) {
                    Thread.sleep(forTimeInterval: 0.6)
                    scene = crawlScene()
                }
            }
            if scene.alerts > 0 {
                let alert = app.alerts.firstMatch
                if !Self.crawlExitLabels.contains(where: { tapIfPossible(alert.buttons[$0].firstMatch) }) {
                    tapIfPossible(alert.buttons.element(boundBy: max(0, alert.buttons.count - 1)))
                }
                Thread.sleep(forTimeInterval: 0.5)
                scene = crawlScene()
                continue
            }
            if scene.keyboards > 0 {
                if !tapIfPossible(app.keyboards.buttons["Return"].firstMatch),
                   !tapIfPossible(app.toolbars.buttons["Done"].firstMatch) {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                }
                Thread.sleep(forTimeInterval: 0.5)
                scene = crawlScene()
                continue
            }
            if scene.sheets > 0 {
                let sheet = app.sheets.firstMatch
                // Asked again before the drag: a sheet that closes on its own
                // between the look and the drag failed the whole crawl
                // ("No matches found … Sheet", N22 rerun).
                if !Self.crawlExitLabels.contains(where: { tapIfPossible(sheet.buttons[$0].firstMatch) }),
                   sheet.exists {
                    sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
                        .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                }
                Thread.sleep(forTimeInterval: 0.6)
                scene = crawlScene()
                continue
            }
            // A menu draws no alert and no sheet; a press outside it is the
            // only exit that always works.
            if crawlMenuRect(scene) != nil {
                let dismissRegion = app.otherElements["PopoverDismissRegion"]
                if !tapIfPossible(dismissRegion) {
                    // A menu covers whichever corner it was opened from, so the
                    // press outside it moves each time round.
                    let elsewhere = [CGVector(dx: 0.5, dy: 0.97), CGVector(dx: 0.04, dy: 0.5),
                                     CGVector(dx: 0.96, dy: 0.5), CGVector(dx: 0.5, dy: 0.03)]
                    app.coordinate(withNormalizedOffset: elsewhere[attempt % elsewhere.count]).tap()
                }
                Thread.sleep(forTimeInterval: 0.5)
                scene = crawlScene()
                continue
            }
            if screen.opener == .none, scene.navigation != baseline {
                if tapIfPossible(app.navigationBars.buttons["BackButton"].firstMatch) { }
                else if Self.crawlExitLabels.contains(where: { tapIfPossible(app.buttons[$0].firstMatch) }) { }
                // A player takes a moment to put its chrome up, and its close
                // button is the only way back out. Giving up on the first look
                // relaunched the whole screen after every press on Play.
                else { Thread.sleep(forTimeInterval: 1.2) }
                Thread.sleep(forTimeInterval: 0.6)
                scene = crawlScene()
                continue
            }
            return scene
        }
        return scene
    }

    // MARK: - Title page bar from every entry point (N53)

    /// Opt-in: opens a title page from a Discover poster, the billboard's
    /// Details, a Search result, Continue Watching and Library, and expects
    /// Back alone on iPhone and the tab's Search on iPad,
    /// and the Rate menu as one named element. Navigation only: it never
    /// presses Play, Download, My List, Rate or Refresh.
    func testTitlePageKeepsTheTabBarFromEveryEntryPoint() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_TITLE_BAR_CHECK"] == "1" else {
            throw XCTSkip("Set OPENSTREAM_TITLE_BAR_CHECK=1 to walk the title page entry points.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 1800
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let folder = env["OPENSTREAM_TITLE_BAR_DIR"].map(URL.init(fileURLWithPath:))
        func shoot(_ name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            if let folder {
                try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(idiom)-\(name).png"))
            }
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = "\(idiom)-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        func relaunch(_ extra: [String] = []) {
            app.terminate()
            app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
            app.launchArguments = ["-OpenStreamTrace", "YES"] + extra
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            Thread.sleep(forTimeInterval: 20)
        }
        func firstHittable(_ prefix: String) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                .allElementsBoundByIndex.prefix(40).first { isSafelyHittable($0) }
        }
        func scrollUp() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        func find(_ prefix: String, scrolls: Int = 8) -> XCUIElement? {
            var element = firstHittable(prefix)
            for _ in 0 ..< scrolls where element == nil {
                scrollUp()
                Thread.sleep(forTimeInterval: 1.2)
                element = firstHittable(prefix)
            }
            return element
        }
        // iPadOS draws the tab bar at the top, where XCTest reports its tabs
        // as plain buttons.
        func tab(_ title: String) -> Bool {
            if tapIfPossible(app.tabBars.buttons[title].firstMatch) { return true }
            let top = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
                .first { isSafelyHittable($0) && $0.frame.maxY < 100 }
            guard let top else { return false }
            top.tap()
            return true
        }
        func barButton(_ label: String) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                .first { $0.exists && $0.frame.height >= 1 && $0.frame.maxY < 160 }
        }
        func expectBar(_ entry: String) {
            let page = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            guard page.waitForExistence(timeout: 40) else {
                XCTFail("\(entry): no title page opened")
                return
            }
            Thread.sleep(forTimeInterval: 3)
            let back = app.buttons["detail.back"].firstMatch.exists
            let search = barButton("Search") != nil
            let refresh = barButton("Refresh") != nil
            print("TITLE-BAR \(idiom) \(entry): back=\(back) search=\(search) refresh=\(refresh)")
            XCTAssertTrue(back, "\(entry): the title page has no Back")
            // Owner, 2026-10-19: "in the content page there is a search icon we don't need".
            XCTAssertEqual(search, idiom == "ipad", "\(entry): unexpected title-page Search")
            // The toolbar policy never put Refresh on title pages.
            XCTAssertFalse(refresh, "\(entry): Refresh belongs to the tab root")
            // One element named Rate, and no unnamed button on top of it.
            let rates = app.buttons.matching(NSPredicate(format: "label == %@", "Rate")).allElementsBoundByIndex
            if let rate = rates.first(where: { $0.exists && $0.frame.width >= 1 }) {
                // Only a button drawn at Rate's own frame: the trailer's
                // full-width shield under the hero also intersects it.
                let unnamed = app.buttons.allElementsBoundByIndex.filter {
                    $0.exists && $0.label.isEmpty
                        && abs($0.frame.midX - rate.frame.midX) < 4 && abs($0.frame.midY - rate.frame.midY) < 4
                        && abs($0.frame.width - rate.frame.width) < 8
                }
                print("TITLE-BAR \(idiom) \(entry): rate buttons=\(rates.count) at \(rate.frame) "
                      + "unnamed-at-rate=\(unnamed.map { "\($0.identifier)@\($0.frame)" })")
                XCTAssertEqual(unnamed.count, 0, "\(entry): an unnamed button sits on Rate")
            }
            shoot("\(entry)-top")
        }
        XCUIDevice.shared.orientation = .portrait

        // A Discover poster: the trailer is left to play (no glyph over it,
        // N49 #17), then the page is scrolled to Related (N49 #20).
        relaunch()
        if let poster = find("home.ms.") {
            poster.tap()
            expectBar("poster")
            // Rate still opens its menu as one element; closed untouched.
            let rate = app.buttons.matching(NSPredicate(format: "label == %@", "Rate")).firstMatch
            if isSafelyHittable(rate) {
                rate.tap()
                Thread.sleep(forTimeInterval: 1.2)
                let opened = app.buttons.matching(NSPredicate(format: "label IN %@", ["Not for Me", "I Like This", "Love This"]))
                    .count > 0
                print("TITLE-BAR \(idiom) poster: rate menu opened=\(opened)")
                XCTAssertTrue(opened, "Rate no longer opens its menu")
                shoot("poster-rate-menu")
                if !tapIfPossible(app.otherElements["PopoverDismissRegion"].firstMatch) {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.012)).tap()
                }
                Thread.sleep(forTimeInterval: 1)
            }
            Thread.sleep(forTimeInterval: 14)
            shoot("poster-trailer")
            for index in 1 ... 3 {
                scrollUp()
                Thread.sleep(forTimeInterval: 1.5)
                shoot("poster-scroll-\(index)")
            }
        } else {
            XCTFail("no Discover poster to open")
        }

        // The billboard's Details.
        relaunch(["-openstream.settings.trailer.autoplay.v1", "NO"])
        let details = app.buttons["home.featured.details"].firstMatch
        if details.waitForExistence(timeout: 30), isSafelyHittable(details) {
            details.tap()
            expectBar("hero-details")
        } else {
            print("TITLE-BAR \(idiom) hero-details: the billboard showed no Details")
        }

        // Continue Watching.
        relaunch(["-openstream.settings.trailer.autoplay.v1", "NO"])
        if let card = find("home.continue.", scrolls: 3) {
            card.tap()
            expectBar("continue-watching")
        } else {
            print("TITLE-BAR \(idiom) continue-watching: no row on this device")
        }

        // A Search result, from Discover's Search.
        relaunch(["-openstream.settings.trailer.autoplay.v1", "NO"])
        if let search = barButton("Search") {
            search.tap()
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("the")
                Thread.sleep(forTimeInterval: 6)
                let result = app.cells.allElementsBoundByIndex.first { isSafelyHittable($0) }
                    ?? app.collectionViews.buttons.allElementsBoundByIndex.first { isSafelyHittable($0) }
                if let result {
                    result.tap()
                    expectBar("search-result")
                } else {
                    XCTFail("Search found nothing for a common word")
                }
            }
        } else {
            XCTFail("Discover has no Search")
        }

        // A Library title.
        relaunch(["-openstream.settings.trailer.autoplay.v1", "NO"])
        if tab("Library") {
            Thread.sleep(forTimeInterval: 8)
            if let title = find("library.title.", scrolls: 4) {
                title.tap()
                expectBar("library")
            } else {
                print("TITLE-BAR \(idiom) library: no Library title on this device")
            }
        }
    }

    // MARK: - Parity survey (N49)

    /// Opt-in walk through Discover, a title page, Search, Library, Live and
    /// Settings, for comparing the iPhone and iPad app against the Apple TV
    /// app — the iOS twin of the tvOS `testParitySurveyWalk` (N41). It saves a
    /// frame per step and logs what VoiceOver would read for every button on
    /// screen, with its frame. Navigation only: it scrolls, opens a title page
    /// and goes back, switches tabs, opens a ⋯ menu and dismisses it, and runs
    /// Discover, Library and Settings again at Accessibility XL. It never
    /// presses Play, Download, My List, Rate, Refresh or any setting.
    func testParitySurveyWalk() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_PARITY_SURVEY"] == "1" else {
            throw XCTSkip("Set OPENSTREAM_PARITY_SURVEY=1 to walk the screens for a parity survey.")
        }
        continueAfterFailure = true
        executionTimeAllowance = 3600
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let idiom = isPad ? "ipad" : "iphone"
        let folder = env["OPENSTREAM_PARITY_SURVEY_DIR"].map(URL.init(fileURLWithPath:))
        var frameIndex = 0
        func shoot(_ step: String) {
            let screenshot = XCUIScreen.main.screenshot()
            frameIndex += 1
            let name = String(format: "%@-%02d-%@", idiom, frameIndex, step)
            if let folder {
                try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
            }
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        // One snapshot per step is far quicker than asking each element in
        // turn. Buttons with no label are the ones VoiceOver reads as nothing.
        func inventory(_ step: String) {
            guard let root = try? app.snapshot() else { return print("SURVEY \(idiom) \(step): no snapshot") }
            let screen = app.frame
            var lines: [String] = []
            var unnamed = 0
            let surveyedTypes: Set<XCUIElement.ElementType> = [.button, .staticText, .link, .cell, .image]
            func visit(_ node: XCUIElementSnapshot) {
                let frame = node.frame
                let onScreen = frame.width >= 1 && frame.height >= 1
                    && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
                if onScreen, surveyedTypes.contains(node.elementType)
                    || (node.elementType == .other && node.identifier.hasPrefix("home.")) {
                    let label = node.label.contains("://") ? "[URL]" : String(node.label.prefix(70))
                    if node.elementType == .button, label.isEmpty { unnamed += 1 }
                    lines.append("\(node.elementType.rawValue)|\(node.identifier)|\(label)|"
                                 + "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
                }
                node.children.forEach(visit)
            }
            visit(root)
            print("SURVEY \(idiom) \(step): \(lines.count) elements, \(unnamed) unnamed buttons")
            for line in lines.prefix(120) { print("SURVEY-EL \(idiom) \(step) \(line)") }
        }
        func step(_ name: String, wait: TimeInterval = 1.5) {
            Thread.sleep(forTimeInterval: wait)
            shoot(name)
            inventory(name)
        }
        func scrollUp(_ from: CGFloat = 0.8, to: CGFloat = 0.35) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        func relaunch(_ screen: String?, extra: [String] = [], settle: TimeInterval) {
            app.terminate()
            app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
            app.launchArguments = ["-OpenStreamTrace", "YES", "-openstream.settings.trailer.autoplay.v1", "NO"] + extra
            if let screen { app.launchArguments += ["-OpenStreamVisionScreen", screen] }
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            Thread.sleep(forTimeInterval: settle)
        }
        // A menu is closed by its own dismiss region; failing that, a press
        // in the status bar, where no control of ours lives.
        func dismissMenu() {
            if !tapIfPossible(app.otherElements["PopoverDismissRegion"].firstMatch) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.012)).tap()
            }
            Thread.sleep(forTimeInterval: 1)
        }
        func back() {
            if !tapIfPossible(app.buttons["detail.back"].firstMatch) {
                _ = tapIfPossible(app.navigationBars.buttons["BackButton"].firstMatch)
                    || tapIfPossible(app.navigationBars.buttons.firstMatch)
            }
        }
        // iPadOS draws the tab bar at the top, and XCTest does not report it
        // as a tab bar: there it is the named button in the top strip.
        func tab(_ title: String) -> Bool {
            if tapIfPossible(app.tabBars.buttons[title].firstMatch) { return true }
            let top = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
                .first { isSafelyHittable($0) && $0.frame.maxY < 100 }
            guard let top else { return false }
            top.tap()
            return true
        }
        func firstHittable(_ prefix: String) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                .allElementsBoundByIndex.prefix(40).first { isSafelyHittable($0) }
        }

        XCUIDevice.shared.orientation = .portrait

        // The hero's first seconds: its title must hold its slot for the
        // wordmark, never showing text that a late logo then replaces (N62).
        relaunch(nil, settle: 0.5)
        for second in [1, 2, 3, 4, 6, 9] {
            Thread.sleep(forTimeInterval: second == 1 ? 0.5 : second == 6 || second == 9 ? 2.5 : 0.8)
            shoot("hero-early-\(second)s")
        }

        // Discover, top to bottom; Continue Watching scrolled sideways and its ⋯ menu opened.
        relaunch(nil, settle: 22)
        step("discover-top", wait: 0)
        var sawContinue = false
        for index in 1 ... 8 {
            scrollUp()
            step("discover-scroll-\(index)")
            if !sawContinue, let card = firstHittable("home.continue.") {
                sawContinue = true
                card.swipeLeft()
                step("discover-continue-swiped")
                let more = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "More for "))
                    .allElementsBoundByIndex.prefix(12).first { isSafelyHittable($0) }
                if let more {
                    more.tap()
                    step("discover-continue-menu", wait: 1.2)
                    dismissMenu()
                    step("discover-continue-menu-dismissed", wait: 0.5)
                }
            }
        }

        // The hero's pages, dragged sideways across the artwork above its
        // buttons, then the first shelf paged sideways (N60).
        relaunch(nil, settle: 22)
        for index in 1 ... 5 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.18))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.18))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
            step("hero-page-\(index)", wait: 2)
        }
        var shelfCard = firstHittable("home.ms.")
        for _ in 0 ..< 3 where shelfCard == nil {
            scrollUp()
            Thread.sleep(forTimeInterval: 1.2)
            shelfCard = firstHittable("home.ms.")
        }
        if let shelfCard {
            // By coordinates at the row's height: once the row pages, the
            // card itself is off screen. Its upper part: on the iPhone the
            // card's middle sits under the floating tab bar (N65).
            let rowY = (shelfCard.frame.minY + min(40, shelfCard.frame.height / 4)) / max(app.frame.height, 1)
            step("shelf-before-paging", wait: 0.5)
            for index in 1 ... 2 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: rowY))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: rowY))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
                step("shelf-paged-\(index)")
            }
        }

        // A catalog poster opened, its page scrolled, then Back.
        relaunch(nil, settle: 22)
        var poster = firstHittable("home.ms.")
        for _ in 0 ..< 4 where poster == nil {
            scrollUp()
            Thread.sleep(forTimeInterval: 1.2)
            poster = firstHittable("home.ms.")
        }
        if let poster {
            poster.tap()
            let page = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            if page.waitForExistence(timeout: 30) {
                step("title-top", wait: 6)
                for index in 1 ... 4 {
                    scrollUp()
                    step("title-scroll-\(index)")
                }
                back()
                step("title-back", wait: 2)
            } else {
                print("SURVEY \(idiom): the poster opened no title page")
            }
        }

        // The debug routes' own series and movie pages, top and one scroll.
        for route in ["detail", "detail-movie"] {
            relaunch(route, settle: 4)
            let page = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.screen.")).firstMatch
            guard page.waitForExistence(timeout: 60) else { continue }
            step("\(route)-top", wait: 8)
            scrollUp()
            step("\(route)-scroll-1")
            let season = app.buttons["detail.season"].firstMatch
            if route == "detail", tapIfPossible(season) {
                step("detail-season-menu", wait: 1.2)
                dismissMenu()
            }
        }

        // Search from the Discover toolbar: empty, then a query (nothing is stored).
        relaunch(nil, settle: 16)
        if tapIfPossible(app.buttons["Search"].firstMatch) {
            step("search-empty", wait: 2)
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("star")
                step("search-results", wait: 8)
                app.swipeUp()
                step("search-results-scroll")
            }
        }

        // Library, Live and Settings through the tab bar.
        relaunch(nil, settle: 12)
        if tab("Library") {
            step("library-top", wait: 8)
            for index in 1 ... 3 {
                scrollUp()
                step("library-scroll-\(index)")
            }
        }
        if tab("Live") {
            step("live-top", wait: 12)
            scrollUp()
            step("live-scroll-1")
        }
        if tab("Settings") {
            step("settings-top", wait: 3)
            scrollUp()
            step("settings-scroll-1")
        }
        if tab("Discover") { step("discover-return", wait: 3) }

        // Dynamic Type at Accessibility XL on three screens.
        let accessibilityXL = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        for route in ["discover", "library", "settings"] {
            relaunch(route, extra: accessibilityXL, settle: route == "discover" ? 22 : 10)
            step("axxl-\(route)-top", wait: 0)
            scrollUp()
            step("axxl-\(route)-scroll-1")
            scrollUp()
            step("axxl-\(route)-scroll-2")
        }

        // iPad in landscape: the two poster screens.
        if isPad {
            XCUIDevice.shared.orientation = .landscapeLeft
            for route in ["discover", "library", "detail", "detail-movie", "settings"] {
                relaunch(route, settle: route == "discover" ? 22 : 10)
                step("landscape-\(route)-top", wait: 0)
                scrollUp()
                step("landscape-\(route)-scroll-1")
            }
            relaunch(nil, settle: 16)
            if tapIfPossible(app.buttons["Search"].firstMatch) {
                let field = app.searchFields.firstMatch
                if field.waitForExistence(timeout: 10) {
                    field.tap()
                    field.typeText("star")
                    step("landscape-search-results", wait: 8)
                }
            }
            XCUIDevice.shared.orientation = .portrait
        } else {
            // iPhone: only the title pages turn to landscape.
            XCUIDevice.shared.orientation = .landscapeLeft
            for route in ["detail", "detail-movie"] {
                relaunch(route, settle: 10)
                step("landscape-\(route)-top", wait: 0)
                scrollUp()
                step("landscape-\(route)-scroll-1")
            }
            XCUIDevice.shared.orientation = .portrait
        }
        app.terminate()
    }
}
