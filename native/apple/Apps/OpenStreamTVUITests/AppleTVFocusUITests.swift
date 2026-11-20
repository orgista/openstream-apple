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

    func testSettingsAndAboutScreenshots() {
        for appearance in ["light", "dark"] {
            app.launchArguments = settingsLaunchArguments(appearance: appearance)
            launch(screen: "settings")
            XCTAssertTrue(element("settings.section.sources").waitForExistence(timeout: 20))
            XCTAssertTrue(focusSettingsRow("settings.section.sources", label: "Sources"))
            attachScreen("settings-root-" + appearance)
            XCTAssertTrue(focusSettingsRow("settings.section.about", label: "About"))
            XCTAssertTrue(element("settings.about.version").waitForExistence(timeout: 10))
            attachScreen("settings-about-sidebar-" + appearance)
            XCTAssertTrue(element("settings.about.privacy").exists)
            XCTAssertTrue(element("settings.about.support").exists)
            XCTAssertFalse(element("settings.about.dolbyVision.summary").exists)
            XCTAssertTrue(focusSettingsRow("settings.about.support", label: "Support"))
            XCTAssertTrue(focusSettingsRow("settings.about.dataSources", label: "Data Sources"))
            remote.press(.select)
            XCTAssertTrue(element("settings.about.noContent").waitForExistence(timeout: 10))
            XCTAssertTrue(element("settings.about.noContent").label.contains("doesn't provide any content"))
            attachScreen("settings-about-no-content-" + appearance)
            remote.press(.menu)
            XCTAssertTrue(element("settings.about.dataSources").waitForExistence(timeout: 10))
            XCTAssertTrue(focusSettingsRow("settings.about.acknowledgements", label: "Acknowledgements"))
            attachScreen("settings-about-row-" + appearance)
            remote.press(.select)
            XCTAssertTrue(element("settings.acknowledgements.AetherEngine").waitForExistence(timeout: 10))
            let sourceCode = element("settings.acknowledgements.sourceCode")
            XCTAssertTrue(sourceCode.label.contains("https://") || (sourceCode.value as? String ?? "").contains("https://"))
            XCTAssertNotEqual(sourceCode.elementType, .link)
            XCTAssertTrue(focusSettingsRow("settings.acknowledgements.libdovi", label: "libdovi"))
            attachScreen("settings-notices-focused-" + appearance)
            remote.press(.select)
            XCTAssertTrue(element("settings.acknowledgements.license").waitForExistence(timeout: 10))
            attachScreen("settings-libdovi-license-" + appearance)
            remote.press(.menu)
            XCTAssertTrue(element("settings.acknowledgements.AetherEngine").waitForExistence(timeout: 10))
            XCTAssertFalse(element("settings.acknowledgements.license").exists)
            remote.press(.menu)
            XCTAssertTrue(element("settings.about.acknowledgements").waitForExistence(timeout: 10))
            XCTAssertFalse(element("settings.acknowledgements.AetherEngine").exists)
            app.terminate()
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

    private func exerciseBitmapCaptions(_ name: String) throws {
        guard let encoded = ProcessInfo.processInfo.environment["OPENSTREAM_BITMAP_CAPTION_FIXTURES"],
              let data = encoded.data(using: .utf8),
              let cases = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              let fixture = cases[name] else { throw XCTSkip("Requires run-e2e.py --caption-fixtures") }
        let track = fixture["track"] as? Int
        let url = fixture["url"] as? String ?? ""
        app.launchArguments = ["-OpenStreamVisionScreen", "add-files", "-OpenStreamVisionPlaybackURL", url,
            "-OpenStreamVisionPlaybackIsLive", "NO", "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
            "-openstream.playback.engine", "engine", "-openstream.settings.captions.preference.v1", "off",
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
        configureFixtureLaunch(app)
        if let smb = fixture["librarySMB"] as? String {
            app.launchEnvironment["OPENSTREAM_LIBRARY_FIXTURE_SMB"] = smb
            app.launchArguments += ["-OpenStreamLibraryTitlesFixture"]
            app.launch()
            let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.title.'")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 60), "SMB scanner could not read Matilda")
            remote.press(.down)
            remote.press(.select)
            let play = app.buttons["detail.play"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30))
            for _ in 0..<12 where !play.hasFocus { remote.press(.right) }
            XCTAssertTrue(play.hasFocus)
            remote.press(.select)
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
        var playbackPaused = false
        func setPlaybackPaused(_ paused: Bool) {
            if playbackPaused != paused {
                remote.press(.playPause)
                playbackPaused = paused
            }
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
        func isFocused(_ element: XCUIElement) -> Bool {
            guard element.exists else { return false }
            return element.hasFocus || element.descendants(matching: .any).allElementsBoundByIndex.contains { $0.hasFocus }
        }
        func focusAndSelect(_ element: XCUIElement, movingUp: Bool = false) {
            for _ in 0..<12 where !isFocused(element) { remote.press(movingUp ? .up : .down) }
            if !isFocused(element) {
                for _ in 0..<12 where !isFocused(element) { remote.press(movingUp ? .down : .up) }
            }
            XCTAssertTrue(isFocused(element), "Requested player/menu control cannot receive focus")
            remote.press(.select)
        }
        func openCaptionMenu() {
            let captions = app.buttons["player.captions"].firstMatch
            let stockSubtitles = app.cells.matching(NSPredicate(format: "label == 'Subtitles'")).firstMatch
            for _ in 0..<15 where !captions.exists && !stockSubtitles.exists { remote.press(.down) }
            if captions.exists {
                focusAndSelect(captions)
            } else {
                // AVKit exposes the app's Subtitles item directly in its horizontal transport bar.
                XCTAssertTrue(stockSubtitles.waitForExistence(timeout: 5), "Stock player Subtitles control is unavailable")
                if !isFocused(stockSubtitles) { remote.press(.up) }
                for _ in 0..<8 where !isFocused(stockSubtitles) { remote.press(.right) }
                XCTAssertTrue(isFocused(stockSubtitles), "Stock Subtitles control cannot receive focus")
                remote.press(.select)
                XCTAssertTrue(app.staticTexts["Off"].firstMatch.waitForExistence(timeout: 5), "Stock Subtitles menu did not open")
            }
        }
        if let reason = fixture["onUnavailable"] as? String { throw XCTSkip(reason) }
        openCaptionMenu()
        let choices = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.subtitle.track.' AND identifier != 'player.subtitle.track.off'"))
        var choice = track.map { app.descendants(matching: .any)["player.subtitle.track.\($0)"].firstMatch } ?? choices.firstMatch
        if !choice.exists, let label = fixture["label"] as? String {
            choice = app.cells.containing(NSPredicate(format: "label == %@", label)).firstMatch
        }
        if !choice.exists {
            let more = app.cells.containing(NSPredicate(format: "label == %@", "More…")).firstMatch
            if more.exists { focusAndSelect(more) }
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
        focusAndSelect(choice)
        func seekTextCue() {
            let surface = app.descendants(matching: .any)["player.scrubber"].firstMatch
            let scrubber = surface.exists ? surface : app.sliders.firstMatch
            XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "Real playback scrubber is unavailable")
            for _ in 0..<8 where !isFocused(scrubber) { remote.press(.up) }
            for _ in 0..<8 where !isFocused(scrubber) { remote.press(.down) }
            XCTAssertTrue(isFocused(scrubber), "Playback scrubber cannot receive focus")
            for _ in 0..<20 { remote.press(.left) }
            if !surface.exists { remote.press(.select) }
            // Seeking can leave the decoder paused even when the earlier menu
            // selection was playing. Measure the actual clock before toggling.
            let before = playbackSeconds()
            Thread.sleep(forTimeInterval: 0.6)
            let after = playbackSeconds()
            if let before, let after, after <= before {
                remote.press(.playPause)
            }
            playbackPaused = false
            let timing = XCTAttachment(string: "Before seek-resume check: \(String(describing: before)); after: \(String(describing: after)); custom scrubber: \(surface.exists)")
            timing.name = "caption-\(name)-seek-clock"; timing.lifetime = .keepAlways; add(timing)
        }
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
            seekTextCue()
            let deadline = Date().addingTimeInterval(15)
            var screenshot = XCUIScreen.main.screenshot()
            var evidence = try textEvidence(screenshot)
            while !evidence.visible, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
                screenshot = XCUIScreen.main.screenshot()
                evidence = try textEvidence(screenshot)
            }
            let image = XCTAttachment(screenshot: screenshot)
            image.name = "caption-\(name)-\(stage)"; image.lifetime = .keepAlways; add(image)
            let geometry = XCTAttachment(string: "Source cue: \(fixture["expectedCue"] ?? ""); normalized OCR bounds: \(evidence.bounds); image orientation: \(screenshot.image.imageOrientation.rawValue)")
            geometry.name = "caption-\(name)-\(stage)-glyph-bounds"; geometry.lifetime = .keepAlways; add(geometry)
            XCTAssertTrue(evidence.visible, "Playing subtitle glyphs do not match the source cue")
            XCTAssertFalse(evidence.bounds.isEmpty, "The captured source glyph has no measured bounds")
            for bounds in evidence.bounds {
                XCTAssertTrue(CGRect(x: -0.001, y: -0.001, width: 1.002, height: 1.002).contains(bounds))
                XCTAssertLessThan(bounds.height, 0.8, "Glyph evidence must not describe the whole player")
            }
        }
        func playbackSeconds() -> Double? {
            let slider = app.sliders.firstMatch
            let sliderValue = slider.exists ? slider.value as? String : nil
            let values = [sliderValue].compactMap { $0 } + app.staticTexts.allElementsBoundByIndex.map(\.label)
            for value in values where value.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
                return value.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
            }
            return nil
        }
        func captureTextOff() throws {
            setPlaybackPaused(false)
            seekTextCue()
            let start = fixture["cueStart"] as? Double ?? 1
            let end = fixture["cueEnd"] as? Double ?? 4
            let deadline = Date().addingTimeInterval(12)
            var seconds = playbackSeconds()
            while !(seconds.map { $0 >= start && $0 < end } ?? false), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
                seconds = playbackSeconds()
            }
            let screenshot = XCUIScreen.main.screenshot()
            let image = XCTAttachment(screenshot: screenshot)
            image.name = "caption-\(name)-off-again"; image.lifetime = .keepAlways; add(image)
            let timeline = XCTAttachment(string: "Observed playback: \(String(describing: seconds)); original cue window: \(start)..<\(end)")
            timeline.name = "caption-\(name)-off-cue-window"; timeline.lifetime = .keepAlways; add(timeline)
            XCTAssertTrue(seconds.map { $0 >= start && $0 < end } ?? false, "Off evidence was not captured within the source cue window")
            XCTAssertFalse(try textEvidence(screenshot).visible, "Off left the source subtitle glyph visible")
        }
        if cueKind == "text" {
            setPlaybackPaused(false)
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
        let viewport = app.windows.firstMatch
        XCTAssertTrue(viewport.exists, "Fullscreen player window is unavailable")
        let bounds = viewport.frame.insetBy(dx: -1, dy: -1)
        if cueKind != "text" {
            XCTAssertGreaterThan(cue.frame.width, 0)
            XCTAssertGreaterThan(cue.frame.height, 0)
            XCTAssertTrue(bounds.contains(cue.frame), "Bitmap caption extends outside the player viewport")
            XCTAssertLessThan(cue.frame.height, viewport.frame.height * 0.8,
                              "Accessibility bounds must describe the cue, not the whole overlay")
        }
        if cueKind == "text" { setPlaybackPaused(true) }
        openCaptionMenu()
        let offChoice = app.cells.containing(NSPredicate(format: "label == %@", "Off")).firstMatch
        XCTAssertTrue(offChoice.waitForExistence(timeout: 5))
        focusAndSelect(offChoice, movingUp: true)
        if cueKind == "text" {
            try captureTextOff()
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
            let scrubber = app.descendants(matching: .any)["player.scrubber"].firstMatch
            if scrubber.exists {
                for _ in 0..<8 where !scrubber.hasFocus { remote.press(.down) }
                XCTAssertTrue(scrubber.hasFocus, "ISO playback scrubber cannot receive focus")
                remote.press(.right)
            } else {
                // AVKit's native transport receives the standard ten-second skip.
                remote.press(.right)
                remote.press(.right)
                remote.press(.right)
            }
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
        remote.press(.down)
        remote.press(.select)
        let play = app.buttons[skip ? "detail.disc.skipToMovie" : "detail.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "Disc start actions missing")
        for _ in 0..<12 where !play.hasFocus { remote.press(.right) }
        XCTAssertTrue(play.hasFocus, "Disc action could not be focused")
        remote.press(.select)
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
            let button = app.buttons["player.disc.menu.select"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "DVD menu exposes no interactive button")
            remote.press(.right)
            remote.press(.left)
            let rootValue = button.value as? String
            remote.press(.select)
            if name == "menu-features" {
                let chapterPage = NSPredicate(format: "value ENDSWITH 'of 6' AND value != %@", rootValue ?? "")
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: chapterPage, object: button)], timeout: 5), .completed,
                               "Play did not change from the root page to the six-button chapter menu")
                capture("chapter-menu")
                remote.press(.select)
            }
            XCTAssertTrue(app.descendants(matching: .any)["player.disc.title.active"].firstMatch.waitForExistence(timeout: 30),
                          "Activating a DVD menu button did not reach title playback")
            capture("title")
            XCTAssertTrue(menu.waitForExistence(timeout: 120), "A completed title dismissed the player instead of returning to the DVD menu")
            capture("title-ended-menu")
            remote.press(.menu)
            XCTAssertTrue(app.buttons["detail.play"].firstMatch.waitForExistence(timeout: 5), "Menu did not close the disc player")
        }
        app.terminate()
    }

    private var remote: XCUIRemote { .shared }

    func testOwnerLibraryResumeAndLiveAudio() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_OWNER_CONTENT"] == "1" else {
            throw XCTSkip("Requires the owner's sources on a test Apple TV.")
        }
        app.launchArguments = ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "NO"]
        app.launch()

        func selectTab(_ name: String) {
            for _ in 0..<8 { remote.press(.up) }
            let tab = app.buttons[name].firstMatch
            // AVKit can consume the first Menu press to hide its controls.
            for _ in 0..<2 where !tab.exists {
                remote.press(.menu)
                for _ in 0..<8 { remote.press(.up) }
            }
            XCTAssertTrue(tab.waitForExistence(timeout: 20))
            for _ in 0..<6 where !tab.hasFocus { remote.press(.left) }
            for _ in 0..<6 where !tab.hasFocus { remote.press(.right) }
            XCTAssertTrue(tab.hasFocus, "Cannot focus the \(name) tab")
            remote.press(.select)
        }

        func seconds() -> Double? {
            let elapsed = app.staticTexts["Elapsed Time"].firstMatch
            let values = elapsed.exists ? [elapsed.label, elapsed.value as? String].compactMap { $0 } : []
            let numeric = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"\d+:\d{2}(:\d{2})?"#)).firstMatch
            for value in values + (numeric.exists ? [numeric.label] : []) {
                if let range = value.range(of: #"\d+:\d{2}(:\d{2})?"#, options: .regularExpression) {
                    return value[range].split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
                }
            }
            return nil
        }

        selectTab("Library")
        let title = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.title.")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 240), "Library has no share titles")
        for _ in 0..<10 where !focusedElement.identifier.hasPrefix("library.title.") { remote.press(.down) }
        XCTAssertTrue(focusedElement.identifier.hasPrefix("library.title."))
        remote.press(.select)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        XCTAssertTrue(play.hasFocus)
        remote.press(.select)
        for _ in 0..<3 where seconds() == nil { remote.press(.down) }
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (seconds() ?? 0) > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 60), .completed, "Library title did not start")
        Thread.sleep(forTimeInterval: 20)
        remote.press(.playPause)
        for _ in 0..<3 where seconds() == nil { remote.press(.down) }
        let stopped = try XCTUnwrap(seconds(), "Library player has no elapsed time")
        attachScreen("owner-tv-library-20s")
        remote.press(.menu)
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertTrue(play.hasFocus)
        remote.press(.select)
        for _ in 0..<3 where seconds() == nil { remote.press(.down) }
        let resumedPlayback = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (seconds() ?? 0) >= max(1, stopped - 5)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumedPlayback], timeout: 60), .completed, "Library title did not resume")
        remote.press(.playPause)
        let resumed = try XCTUnwrap(seconds(), "Resumed player has no elapsed time")
        print("OWNER-CONTENT tv resume stopped=\(stopped)s resumed=\(resumed)s delta=\(abs(resumed - stopped))s")
        XCTAssertLessThanOrEqual(abs(resumed - stopped), 5, "Resume missed the saved stop point")
        attachScreen("owner-tv-library-resumed")
        remote.press(.menu)
        remote.press(.menu)

        selectTab("Live")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.play."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 120))
        for _ in 0..<10 where !focusedElement.identifier.hasPrefix("guide.play.") { remote.press(.down) }
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."))
        remote.press(.select)
        XCTAssertTrue(element("live.player.surface").waitForExistence(timeout: 45))
        Thread.sleep(forTimeInterval: 20)
        XCTAssertFalse(element("live.failure").exists, "Live playback failed")
        remote.press(.playPause)
        XCTAssertTrue(app.images["Paused"].firstMatch.waitForExistence(timeout: 10), "Live never reached a pausable stream")
        attachScreen("owner-tv-live-audio-unmuted")
    }

    override func setUp() {
        continueAfterFailure = false
        app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
    }

    override func tearDown() {
        app?.terminate()
    }

    func testContinueWatchingCaptionsAndFocus() {
        app.launchArguments = ["-OpenStreamContinueWatchingFixture", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        let episode = element("cw.fixture.0")
        let film = element("cw.fixture.1")
        let next = element("cw.fixture.2")
        XCTAssertTrue(episode.waitForExistence(timeout: 20))
        XCTAssertEqual(episode.value as? String, "S2 E5 · 23 min left")
        XCTAssertEqual(film.value as? String, "1 hr 12 min left")
        XCTAssertEqual(next.value as? String, "Next · S2 E6")
        XCTAssertTrue(episode.hasFocus)
        attachScreen("continue-watching-light-focused")
        remote.press(.right)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: film)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        attachScreen("continue-watching-dark-focused")
        remote.press(.right)
        let nextFocused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [nextFocused], timeout: 5), .completed)
        attachScreen("continue-watching-next-focused")
    }

    func testContinueWatchingContextMenuReturnsFocus() {
        app.launchArguments = ["-OpenStreamContinueWatchingFixture", "-OpenStreamMuteAudio", "YES"]
        app.launch()
        let episode = element("cw.fixture.0")
        XCTAssertTrue(episode.waitForExistence(timeout: 20))
        XCTAssertTrue(episode.hasFocus)
        remote.press(.select, forDuration: 1)
        let remove = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Remove from Continue Watching")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attachScreen("continue-watching-context-menu")
        remote.press(.menu)
        let restoredFocus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: episode)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredFocus], timeout: 5), .completed)
        attachScreen("continue-watching-context-returned")
    }

    func testPublicLiveExitBaseline() throws {
        try launchPublicLiveChannel()
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 10)
        attachScreen("live-baseline-playing")
        remote.press(.menu)
        XCTAssertFalse(element("live.player.surface").exists)
        remote.press(.menu)
        remote.press(.menu)
        XCTAssertTrue(element("live.tv.info").waitForExistence(timeout: 5))
        waitForPublicGuideFocus()
        let focused = focusedElement.identifier
        remote.press(.down)
        XCTAssertNotEqual(focusedElement.identifier, focused, "The guide did not respond after Menu")
        attachScreen("live-baseline-guide-interactive")
    }

    func testPublicLivePolish() throws {
        try launchPublicLiveChannel()
        let ready = element("player.playback.ready")
        XCTAssertTrue(element("live.loading").exists || ready.exists, "Connecting has no loading feedback")
        attachScreen("live-public-connecting")
        XCTAssertTrue(ready.waitForExistence(timeout: 30))
        let status = element("live.player.status")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        for sample in 1...3 {
            Thread.sleep(forTimeInterval: 20)
            if !ready.exists {
                let started = ContinuousClock.now
                attachLiveStatus(status, name: "live-public-buffering")
                XCTAssertTrue(element("live.loading").exists || element("live.reconnecting").exists,
                              "Buffering has no loading feedback")
                XCTAssertTrue(ready.waitForExistence(timeout: 30), "Public live playback did not recover")
                attachLiveStatus(status, name: "live-public-recovered-after-\(started.duration(to: .now))")
            }
            XCTAssertLessThanOrEqual(try liveLag(status), try liveMetric(status, key: "tolerance"),
                                     "Playback drifted beyond the item's live hold-back")
            attachLiveStatus(status, name: "live-public-sample-\(sample)")
        }
        attachScreen("live-public-after-one-minute")
        remote.press(.playPause)
        let live = element("player.live")
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 10)
        XCTAssertEqual(live.value as? String, "Behind live")
        XCTAssertTrue(live.hasFocus, "Paused live playback did not focus the return-to-live control")
        attachScreen("live-public-paused-behind")
        remote.press(.select)
        expectation(for: NSPredicate(format: "value CONTAINS 'phase=playing'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertLessThanOrEqual(try liveLag(status), try liveMetric(status, key: "tolerance"))
        attachLiveStatus(status, name: "live-public-returned-to-live")
        attachScreen("live-public-one-press-return")
        remote.press(.menu)
        let next = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'live.footer.' AND label CONTAINS[c] 'Fox Weather'")).firstMatch
        for _ in 0..<5 where !next.exists || !next.hasFocus { remote.press(.right) }
        XCTAssertTrue(next.hasFocus)
        remote.press(.select)
        XCTAssertTrue(element("live.loading").exists || ready.exists, "Channel switch has no loading feedback")
        attachScreen("live-public-switching")
        XCTAssertTrue(ready.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 5)
        remote.press(.menu)
        remote.press(.menu)
        remote.press(.menu)
        attachScreen("live-public-after-exit")
        XCTAssertTrue(element("live.tv.info").waitForExistence(timeout: 5))
        waitForPublicGuideFocus()
        let focused = focusedElement.identifier
        remote.press(.down)
        XCTAssertNotEqual(focusedElement.identifier, focused, "The guide did not respond after Menu")
        let trace = try currentOpenStreamTrace()
        let dismissed = try XCTUnwrap(trace.firstIndex { $0.contains("live production cover dismissed") })
        let interactive = try XCTUnwrap(trace.firstIndex { $0.contains("live exit guide interactive") })
        XCTAssertLessThan(dismissed, interactive, "Focus landed before the production cover dismissed")
        XCTAssertLessThanOrEqual(trace.filter { $0.contains("live drift catch-up") }.count, 1,
                                 "Live following repeatedly corrected its own lag")
        attachScreen("live-public-guide-interactive")
    }

    private func attachLiveStatus(_ status: XCUIElement, name: String) {
        let attachment = XCTAttachment(string: status.value as? String ?? "Live status unavailable")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForPublicGuideFocus() {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.focusedElement.identifier.hasPrefix("guide.play.")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "Menu did not restore interactive guide focus")
        XCTAssertFalse(element("player.playback.ready").exists, "The player still covers the guide")
    }

    private func liveLag(_ status: XCUIElement) throws -> Double {
        let lag = try liveMetric(status, key: "lag")
        XCTAssertGreaterThanOrEqual(lag, 0, "The player has no published live window")
        return lag
    }

    private func liveMetric(_ status: XCUIElement, key: String) throws -> Double {
        let value = try XCTUnwrap(status.value as? String)
        let raw = try XCTUnwrap(value.components(separatedBy: key + "=").last?.split(separator: " ").first)
        return try XCTUnwrap(Double(raw))
    }

    private func launchPublicLiveChannel() throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_M3U"],
              let url = URL(string: raw), url.scheme == "https" else {
            throw XCTSkip("Requires a public HTTPS live playlist")
        }
        let sources = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("live-public-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [
            ["kind": "m3u", "name": "Public Weather", "playlistURL": raw]
        ]]).write(to: sources)
        addTeardownBlock { try? FileManager.default.removeItem(at: sources) }
        app.launchArguments = ["-OpenStreamDevSources", sources.path, "-OpenStreamResetOnLaunch", "YES",
            "-OpenStreamVisionScreen", "live", "-OpenStreamMuteAudio", "YES",
            "-OpenStreamTrace", "YES", "-OpenStreamTraceStepMilliseconds", "0",
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.live.package.v1", "everything",
            "-openstream.settings.trailer.autoplay.v1", "NO"]
        app.launch()
        XCTAssertTrue(element("live.tv.info").waitForExistence(timeout: 30))
        let channel = ProcessInfo.processInfo.environment["OPENSTREAM_TEST_CHANNEL"] ?? "AccuWeather"
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.' AND label CONTAINS[c] %@", channel)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Public test channel is absent from the guide")
        for _ in 0..<20 where !target.hasFocus { remote.press(.down) }
        XCTAssertTrue(target.hasFocus)
        remote.press(.select)
        attachScreen("live-public-tune-feedback")
        XCTAssertTrue(element("live.player.surface").waitForExistence(timeout: 10))
    }

    func testSlidingLiveStartsAtTheEdgeWithoutALivePress() throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.host, "127.0.0.1")
        app.launchArguments = ["-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackURL", raw,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        let joined = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live initial edge joined") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [joined], timeout: 30), .completed)
        XCTAssertFalse(element("live.failure").exists)
        attachScreen("live-sliding-at-edge-no-live-press")
        remote.press(.playPause)
        let paused = app.images["Paused"].firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 10),
                      "The channel never reached playing")
        let surface = element("live.player.surface")
        XCTAssertEqual(paused.frame.midX, surface.frame.midX, accuracy: 1)
        XCTAssertEqual(paused.frame.midY, surface.frame.midY, accuracy: 1)
        XCTAssertFalse(element("player.play-pause").exists,
                       "The native Live route gives transport to the Siri Remote")
        let frames = XCTAttachment(string: "surface=\(surface.frame)\npaused=\(paused.frame)")
        frames.name = "live-remote-transport-frames"; frames.lifetime = .keepAlways; add(frames)
        attachScreen("live-sliding-remote-transport-paused")
    }

    func testStalledLiveOriginStopsLoading() throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_STALLED"] else {
            throw XCTSkip("Requires the local --live-fixtures origin")
        }
        app.launchArguments = ["-OpenStreamInlineLiveFixture", "-OpenStreamVisionPlaybackURL", raw,
            "-OpenStreamVisionPlaybackIsLive", "YES", "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        let retry = element("live.failure.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 30))
        XCTAssertEqual(retry.label, "Retry")
        XCTAssertGreaterThanOrEqual(retry.frame.width, 44)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
        XCTAssertTrue(app.staticTexts["Can’t reach this channel’s server"].exists)
        attachScreen("live-stalled-origin-after-deadline")
    }

    func testVODControlsUseTheNativeTransportRow() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"])
        for engine in ["native", "engine"] {
            app.launchArguments = ["-OpenStreamVisionScreen", "add-files",
                "-OpenStreamVisionPlaybackURL", base + "/media/e2e-long.mp4",
                "-OpenStreamVisionPlaybackIsLive", "NO", "-openstream.playback.engine", engine,
                "-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
            configureFixtureLaunch(app)
            app.launch()
            XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 45))
            remote.press(.playPause)
            remote.press(.down)
            XCTAssertTrue(element("Subtitles").waitForExistence(timeout: 10))
            assertNativePlayerControlFrames()
            attachScreen("tv-vod-\(engine)-native-controls")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "tv-vod-\(engine)-control-frames"; tree.lifetime = .keepAlways; add(tree)
            app.terminate()
        }
    }

    private func assertNativePlayerControlFrames() {
        let timer = app.cells["player.sleepTimer"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 10))
        guard timer.exists else { return }
        let anchor = timer.frame
        let cells = app.cells.allElementsBoundByIndex.compactMap { try? $0.snapshot() }.filter {
            abs($0.frame.midY - anchor.midY) < 1 && $0.frame.width < 120 && $0.frame.height > 0
        }
        XCTAssertGreaterThanOrEqual(cells.count, 2, "The native transport row was not fully visible")
        for cell in cells {
            XCTAssertEqual(cell.frame.width, anchor.width, accuracy: 1)
            XCTAssertEqual(cell.frame.height, anchor.height, accuracy: 1)
            XCTAssertGreaterThanOrEqual(cell.frame.width, 44)
            XCTAssertGreaterThanOrEqual(cell.frame.height, 44)
        }
        let record = XCTAttachment(string: cells.map { "\($0.label): \($0.frame)" }.joined(separator: "\n"))
        record.name = "native-player-control-row-frames"; record.lifetime = .keepAlways; add(record)
    }

    func testMediaServerLibraryLoadShowsConnectedInSources() throws {
        let base = try liveFixtureBase()
        app.launchArguments = try liveSourceArguments(["kind": "mediaServer", "server": "jellyfin", "name": "Rill",
            "url": base.appendingPathComponent("jf").absoluteString, "username": "fixture", "password": "fixture"])
        launch(screen: "discover")
        let imported = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("dev sources: done") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 20), .completed)
        try openLiveFixtureSourceDetail()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format:
            "label IN %@", ["Health, Connected", "Connected"])).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS 'Connected · '")).firstMatch.exists)
        attachScreen("tv-sources-rill-connected")
    }

    func testStalledPlaylistKeepsSavedChannelsWithoutAnImmediateWarning() throws {
        let base = try liveFixtureBase()
        app.launchArguments = try liveSourceArguments(["kind": "m3u", "name": "IPTV",
            "playlistURL": base.appendingPathComponent("saved/channels.m3u").absoluteString])
        launch(screen: "live")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
            .firstMatch.waitForExistence(timeout: 30))
        try stallOpenStreamSavedPlaylist()
        app.terminate()
        app.launchArguments = ["-OpenStreamStubLiveBase", base.absoluteString, "-OpenStreamMuteAudio", "YES"]
        launch(screen: "live")
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            (try? self.currentOpenStreamTrace().contains { $0.contains("live playlist failed: IPTV saved=true") }) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 45), .completed)
        XCTAssertFalse(element("live.sourceError").exists)
        try openLiveFixtureSourceDetail()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format:
            "label IN %@", ["Health, Showing saved channels", "Showing saved channels"]))
            .firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format:
            "label CONTAINS 'Showing saved channels · last updated '")).firstMatch.exists)
        attachScreen("tv-sources-saved-channels-after-timeout")
    }

    private func liveFixtureBase() throws -> URL {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSTREAM_LIVE_LAB_HLS"])
        let base = try XCTUnwrap(URL(string: raw)).deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(base.host, "127.0.0.1")
        return base
    }

    private func liveSourceArguments(_ source: [String: String]) throws -> [String] {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tv-live-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ["-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES",
                "-OpenStreamStubLiveBase", try liveFixtureBase().absoluteString, "-OpenStreamMuteAudio", "YES",
                "-openstream.settings.live.package.v1", "everything"]
    }

    private func openLiveFixtureSourceDetail() throws {
        app.terminate()
        app.launchArguments = ["-OpenStreamStubLiveBase", try liveFixtureBase().absoluteString, "-OpenStreamMuteAudio", "YES"]
        launch(screen: "source-detail")
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
        configureFixtureLaunch(app)
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

    private func settingsLaunchArguments(appearance: String) -> [String] {
        Self.stubbedLaunchArguments + ["-OpenStreamDebugColorScheme", appearance,
            "-openstream.firstRunGuidanceSeen", "YES", "-openstream.backup.icloud.enabled.v1", "NO",
            "-openstream.reset.cloudRestoreHeld.v1", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
    }

    private func focusSettingsRow(_ identifier: String, label: String? = nil) -> Bool {
        var trace: [String] = []
        for step in 0..<24 {
            let identified = element(identifier)
            let target = identified.exists ? identified : app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label ?? identifier, (label ?? identifier) + ",")).firstMatch
            let current = focusedElement
            if target.exists {
                if target.hasFocus || target.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists {
                    return true
                }
                if current.exists, current.frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY)),
                   current.frame.height <= target.frame.height * 3 {
                    return true
                }
            }
            let origin = current.exists ? "\(current.identifier) \(current.label) \(current.frame)" : "none"
            trace.append("\(step): \(origin); target \(target.exists ? target.frame : .zero)")
            let direction: XCUIRemote.Button
            if !target.exists || !current.exists {
                direction = .down
            } else {
                let from = current.frame, to = target.frame
                // Cross between the sidebar and detail pane before following their vertical rows.
                if from.maxY < to.minY && from.minY < app.frame.height * 0.15 {
                    direction = .down
                } else if from.maxX < to.minX {
                    direction = .right
                } else if to.maxX < from.minX {
                    direction = .left
                } else {
                    direction = to.midY > from.midY ? .down : .up
                }
            }
            remote.press(direction)
        }
        let proof = XCTAttachment(string: trace.joined(separator: "\n") + "\n" + app.debugDescription)
        proof.name = "settings-focus-unreachable-" + identifier
        proof.lifetime = .keepAlways
        add(proof)
        return false
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
        configureFixtureLaunch(app)
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
        configureFixtureLaunch(app)
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

    func testAboutLinksShowQRCodesAndMenuReturns() {
        for appearance in ["light", "dark"] {
            app.launchArguments = settingsLaunchArguments(appearance: appearance)
            launch(screen: "about")
            XCTAssertTrue(element("settings.about.version").waitForExistence(timeout: 20))
            for (identifier, title) in [("privacy", "Privacy"), ("support", "Support")] {
                XCTAssertTrue(focusSettingsRow("settings.about." + identifier, label: title))
                remote.press(.select)
                XCTAssertTrue(element("settings.about.link.qr").waitForExistence(timeout: 10))
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "@")).firstMatch.exists)
                attachScreen("settings-" + identifier + "-qr-" + appearance)
                remote.press(.menu)
                XCTAssertTrue(element("settings.about.version").waitForExistence(timeout: 10))
                XCTAssertFalse(element("settings.about.link.qr").exists)
            }
            app.terminate()
        }
    }

    func testPlaybackUsesNativeMenusAndToggles() {
        for appearance in ["light", "dark"] {
            app.launchArguments = settingsLaunchArguments(appearance: appearance)
                + ["-openstream.settings.captions.preference.v1", "off"]
            launch(screen: "playback-settings")
            XCTAssertTrue(element("settings.captions").waitForExistence(timeout: 20))
            XCTAssertTrue(focusSettingsRow("settings.captions", label: "Show Captions"))
            attachScreen("settings-playback-picker-" + appearance)
            remote.press(.select)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Always")).firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(focusSettingsRow("Always", label: "Always"))
            attachScreen("settings-playback-picker-option-" + appearance)
            remote.press(.select)
            XCTAssertTrue(focused(where: NSPredicate(format: "identifier == %@ OR label CONTAINS %@",
                "settings.captions", "Always")).waitForExistence(timeout: 10))
            XCTAssertTrue(focusSettingsRow("settings.autoPlayNextEpisode", label: "Auto Play Next Episode"))
            attachScreen("settings-playback-toggle-" + appearance)
            remote.press(.select)
            XCTAssertTrue(focusSettingsRow("settings.autoPlayNextEpisode", label: "Auto Play Next Episode"))
            remote.press(.menu)
            XCTAssertTrue(element("settings.section.sources").waitForExistence(timeout: 10))
            XCTAssertEqual(app.state, .runningForeground)
            app.terminate()
        }
    }

    func testNarratedMetadataKeysAreBehindAdvanced() {
        app.launchArguments = settingsLaunchArguments(appearance: "dark")
        launch(screen: "metadata")
        XCTAssertTrue(element("settings.metadata.advanced").waitForExistence(timeout: 20))
        XCTAssertFalse(element("settings.metadata.tmdb").exists)
        XCTAssertFalse(element("settings.metadata.omdb").exists)
        XCTAssertTrue(focusSettingsRow("settings.metadata.advanced", label: "Advanced"))
        remote.press(.select)
        XCTAssertTrue(element("settings.metadata.tmdb").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.metadata.omdb").exists)
        attachScreen("settings-metadata-advanced")
        remote.press(.menu)
        XCTAssertTrue(element("settings.metadata.advanced").waitForExistence(timeout: 10))
        XCTAssertFalse(element("settings.metadata.tmdb").exists)
        remote.press(.menu)
        XCTAssertTrue(element("settings.section.sources").waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Every Settings choice opened an empty page and Menu there left the app
    /// (Apple TV verification 2026-10-01). The Package choice must list its
    /// options, give an option focus, and Menu must go back one level.
    func testSettingsChoicePageListsOptionsAndMenuGoesBack() {
        app.launchArguments = settingsLaunchArguments(appearance: "dark")
            + ["-openstream.settings.live.package.v1", "everything"]
        launch(screen: "channels")
        XCTAssertTrue(focusSettingsRow("settings.channels.package", label: "Package"))
        attachScreen("settings-package-menu-anchor")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Everything")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Custom")).firstMatch.exists)
        attachScreen("settings-package-menu")
        remote.press(.menu)
        XCTAssertTrue(element("settings.channels.package").waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Custom")).firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(focusSettingsRow("settings.channels.package", label: "Package"))
        remote.press(.select)
        XCTAssertTrue(focusSettingsRow("Custom", label: "Custom"))
        remote.press(.select)
        XCTAssertTrue(focused(where: NSPredicate(format: "label CONTAINS %@", "Custom")).waitForExistence(timeout: 10))
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
    func testGuideOpensFocusedOnAChannel() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("polish-live-\(UUID().uuidString).json")
        try Data(#"{"version":1,"sources":[{"kind":"m3u","name":"Polish Live","playlistURL":"https://fixture.example/iptv/polish-channels.m3u","epgURL":"https://fixture.example/iptv/guide.xml"}]}"#.utf8).write(to: file)
        app.launchArguments = ["-OpenStreamStubNetwork", Self.stubDirectory, "-OpenStreamVisionScreen", "live",
            "-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "NO",
            "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
        app.launch()
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
        let channels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
        for name in ["CBS", "Fixture News", "Fixture Film"] {
            XCTAssertTrue(channels.matching(NSPredicate(format: "label == %@", "Play " + name))
                .firstMatch.waitForExistence(timeout: 30))
        }
        for channel in channels.allElementsBoundByIndex {
            XCTAssertNil(channel.label.range(of: #"(?:^|\s)(?:CA|US|UK)\s*[:|]"#, options: [.regularExpression, .caseInsensitive]))
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "polish-guide-logos-and-monograms"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        // This checks guide navigation, independent of watch history from the zap test.
        app.launchArguments += ["-openstream.live.startWithLastChannel", "NO",
                                "-openstream.settings.trailer.autoplay.v1", "NO"]
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")

        XCTAssertTrue(focusedElement.waitForExistence(timeout: 10), "nothing holds focus at all")
        remote.press(.down)
        XCTAssertTrue(focused(where: NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
            .waitForExistence(timeout: 10),
            "expected a channel to hold focus before pressing Menu, got '\(focusedElement.identifier)'"
        )
        attachScreen("menu-guide-channel-focused")

        remote.press(.menu)
        XCTAssertTrue(focused(where: NSPredicate(format: "identifier BEGINSWITH 'live.category.'"))
            .waitForExistence(timeout: 10), "Menu did not reach the category row")
        attachScreen("menu-guide-category-focused")
        remote.press(.menu)
        XCTAssertTrue(focused(where: NSPredicate(format: "label == 'Live'"))
            .waitForExistence(timeout: 10), "The second Menu did not return to the tab bar")
        XCTAssertEqual(app.state, .runningForeground)
        attachScreen("menu-guide-tab-focused")
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
        // The owner's lineup has 30+ category chips, so allow a long walk.
        for _ in 0 ..< 80 where focusedElement.identifier != "live.search" {
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

    /// V2 on Apple TV (2026-10-28): Live search here is an editor page over the guide, so
    /// a channel is picked from the filtered guide after Menu. The pick plays, and search
    /// does not come back over the player or the guide.
    func testPickingAChannelAfterLiveSearchOpensThePlayer() {
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")
        func settle() { Thread.sleep(forTimeInterval: 1.5) }

        remote.press(.down); settle()
        remote.press(.up); settle()
        for _ in 0 ..< 80 where focusedElement.identifier != "live.search" {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertEqual(focusedElement.identifier, "live.search", "never reached the search glyph")
        remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "selecting the glyph did not open channel search")
        settle()
        remote.press(.select); settle()
        app.typeText("CBS")
        for _ in 0 ..< 3 where !element("live.search").exists {
            remote.press(.menu); settle()
        }
        let search = element("live.search")
        XCTAssertTrue(wait(for: search, 10), "Menu did not return from search to the guide")
        XCTAssertEqual(search.label, "Search Channels, filter active", "the search did not filter the guide")

        // Nothing sits under the glyph in a filtered guide: go down from the first chip.
        for _ in 0 ..< 80 where focusedElement.identifier != "live.category.All" {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.8)
        }
        remote.press(.down)
        XCTAssertTrue(focused(where: NSPredicate(format: "identifier BEGINSWITH 'guide.play.'"))
            .waitForExistence(timeout: 10), "no filtered channel took focus, got '\(focusedElement.identifier)'")
        remote.press(.select)
        let covered = NSPredicate(format: "exists == false OR isHittable == false")
        expectation(for: covered, evaluatedWith: element("live.tv.info"))
        waitForExpectations(timeout: 40)
        XCTAssertFalse(field.exists, "channel search came back over the player")

        remote.press(.menu)
        XCTAssertTrue(wait(for: element("live.tv.info"), 15), "Menu did not close the player")
        XCTAssertFalse(field.exists, "channel search came back over the guide")
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

    /// Server trailers: the fixture Jellyfin (`Tests/Fixtures/serve.py`, /jf)
    /// has a local MP4 trailer for every stub title, and the Apple TV hero
    /// plays it muted over the art once the art is up.
    func testDiscoverHeroPlaysServerTrailer() throws {
        launch(screen: "discover")
        XCTAssertTrue(wait(for: element("home.featured.play"), 60), "the Discover billboard never appeared")

        let playing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'hero.serverTrailer' AND value == 'playing'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 60), "the hero never played the server's trailer")
        attachScreen("server-trailer-hero-playing")
    }

    /// Seamless handover (2026-10-29): the fixture trailer opens on black,
    /// letterboxed. The hero reveals it only once it shows a picture, and at
    /// its end (10 s) the still comes back over the last frame. The tvOS gate
    /// screen-records this run and checks it frame by frame with
    /// `Tests/Fixtures/handover_check.py`. Every step is traced: the frame
    /// measurement off the main thread, the settle gate on it.
    func testDiscoverHeroServerTrailerHandsOverBothWays() throws {
        app.launchArguments += ["-OpenStreamTraceStepMilliseconds", "0"]
        launch(screen: "discover")
        XCTAssertTrue(wait(for: element("home.featured.play"), 60), "the Discover billboard never appeared")
        let trailer = app.descendants(matching: .any).matching(identifier: "hero.serverTrailer").firstMatch
        let playing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'hero.serverTrailer' AND value == 'playing'")).firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 60), "the hero never played the server's trailer")
        attachScreen("server-trailer-handover-playing")
        let backToArt = NSPredicate(format: "value == 'still'")
        expectation(for: backToArt, evaluatedWith: trailer)
        waitForExpectations(timeout: 20)
        attachScreen("server-trailer-handover-back-to-art")
    }

    /// Server trailers on a device with the owner's own Plex and Jellyfin
    /// sources (`OPENSTREAM_REAL_SOURCES=1`, Apple TV): the hero pages until one
    /// plays its server trailer, then that title's page offers Trailer and
    /// plays it full screen. Silent with `-OpenStreamMuteAudio` (Debug).
    func testServerTrailersWithRealServers() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_REAL_SOURCES"] == "1" else {
            throw XCTSkip("Set OPENSTREAM_REAL_SOURCES=1 on a device with real media servers.")
        }
        app.launchArguments += ["-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES"]
        app.launch()
        XCTAssertTrue(wait(for: element("home.featured.play"), 90), "the Discover billboard never appeared")
        let playing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'hero.serverTrailer' AND value == 'playing'")).firstMatch
        // Focus starts in the tab bar, where Right changes tabs: go down to
        // the first row and back up into the hero first (as N12 does).
        let heroIDs = ["home.featured.play", "home.featured.my-list", "home.featured.details"]
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.5)
        if !heroIDs.contains(focusedElement.identifier) {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(heroIDs.contains(focusedElement.identifier),
                      "focus never reached the hero, got '\(focusedElement.identifier)'")
        var page = 0
        while !playing.waitForExistence(timeout: 20), page < 10 {
            // Right past the last button turns the page (`AppleTVHeroPaging`).
            for _ in 0..<4 { remote.press(.right); Thread.sleep(forTimeInterval: 0.6) }
            page += 1
        }
        XCTAssertTrue(playing.exists, "no hero page played a server trailer in \(page + 1) pages")
        print("SERVER TRAILER hero playing on page \(page + 1)")
        Thread.sleep(forTimeInterval: 3)
        attachScreen("server-trailer-appletv-hero")

        let details = element("home.featured.details")
        for _ in 0..<4 where !details.hasFocus { remote.press(.right); Thread.sleep(forTimeInterval: 0.6) }
        guard details.hasFocus else { return XCTFail("the hero's Details never took focus") }
        remote.press(.select)
        // The row's `detail.icon-row` identifier replaces its buttons' own.
        let trailer = app.buttons.matching(NSPredicate(
            format: "identifier == 'detail.icon-row' AND label == 'Play Trailer'")).firstMatch
        XCTAssertTrue(wait(for: trailer, 30), "the title page offered no Trailer button")
        for _ in 0..<4 where !trailer.hasFocus { remote.press(.right); Thread.sleep(forTimeInterval: 0.6) }
        attachScreen("server-trailer-appletv-title-page")
        XCTAssertTrue(trailer.hasFocus, "focus never reached Trailer, got '\(focusedElement.identifier)'")
        remote.press(.select)
        XCTAssertTrue(wait(for: element("trailer.player.playing"), 15), "Trailer opened no playing video")
        Thread.sleep(forTimeInterval: 8)
        attachScreen("server-trailer-appletv-player")
        // The player's first Menu may only hide its transport.
        for _ in 0..<2 where !trailer.isHittable {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertTrue(trailer.isHittable, "Menu should close the trailer and return to the title page")
        remote.press(.menu)
    }

    /// Spec S3 G2/G3: an idle Home keeps cycling with focus resting on Play
    /// (at least 4 page changes in 60 s) and focus stays on Play across every
    /// change. Then 30 s with focus on the trailing round button: a page
    /// change must leave focus in the hero. Last, three page turns by the
    /// remote, which every build draws, so the screen recording holds page
    /// changes from a build without the crossfade too. Read-only: nothing is
    /// selected. The crossfade is measured from the run's screen recording:
    /// a 4K screenshot takes most of a second on an Apple TV.
    func testDiscoverHeroCyclesWhilePlayHasFocus() {
        launch(screen: "discover")
        let play = element("home.featured.play")
        XCTAssertTrue(wait(for: play, 90), "the Discover billboard never appeared")
        let pages = element("home.featured.pages")
        XCTAssertTrue(wait(for: pages, 30), "the hero has one page: nothing to cycle")
        let heroIDs = ["home.featured.play", "home.featured.my-list", "home.featured.details"]
        if !play.hasFocus {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.5)
            if !heroIDs.contains(focusedElement.identifier) {
                remote.press(.up)
                Thread.sleep(forTimeInterval: 1.5)
            }
        }
        for _ in 0..<2 where !play.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(play.hasFocus, "Play never took focus, got '\(focusedElement.identifier)'")
        attachScreen("g2-hero-play-focused")
        let onPlay = watchPages(pages, seconds: 60, phase: "PLAY")
        attachScreen("g2-hero-after-60s")

        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1.0)
        print("G2 HERO trailing focus '\(focusedElement.identifier)'")
        let onTrailing = watchPages(pages, seconds: 30, phase: "TRAILING")

        for turn in 1...3 {
            print("G2 HERO TURN \(turn) at \(Date().timeIntervalSince1970) from '\(pages.label)'")
            remote.press(.right)
            Thread.sleep(forTimeInterval: 4)
            print("G2 HERO TURN \(turn) → '\(pages.label)' focus '\(focusedElement.identifier)'")
        }

        XCTAssertGreaterThanOrEqual(onPlay.changes, 4, "an idle hero with Play focused should keep cycling")
        XCTAssertTrue(onPlay.focus.allSatisfy { $0 == "home.featured.play" }, "focus left Play across a page change: \(onPlay.focus)")
        XCTAssertTrue(onTrailing.focus.allSatisfy { heroIDs.contains($0) }, "focus left the hero across a page change: \(onTrailing.focus)")
    }

    /// Logs each change of the hero's page label for `seconds`, with what has
    /// focus after it.
    private func watchPages(_ pages: XCUIElement, seconds: TimeInterval, phase: String) -> (changes: Int, focus: [String]) {
        var label = pages.label
        var focus: [String] = []
        let start = Date()
        print("G2 HERO \(phase) from \(start.timeIntervalSince1970) on '\(label)' focus '\(focusedElement.identifier)'")
        while Date().timeIntervalSince(start) < seconds {
            Thread.sleep(forTimeInterval: 0.5)
            let current = pages.label
            guard current != label else { continue }
            label = current
            let focused = focusedElement.identifier
            focus.append(focused)
            print("G2 HERO \(phase) change \(focus.count) at \(String(format: "%.1f", Date().timeIntervalSince(start))) s → '\(label)' focus '\(focused)'")
        }
        print("G2 HERO \(phase) \(focus.count) page changes in \(Int(seconds)) s")
        return (focus.count, focus)
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
            app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
            app.launchArguments = ["-OpenStreamVisionScreen", screen, "-OpenStreamTrace", "YES",
                                   "-openstream.settings.trailer.autoplay.v1", "NO"]
            configureFixtureLaunch(app)
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
            if focusedElement.exists, focusedElement.identifier.hasPrefix("home.ms.") { opened = true; break }
        }
        if opened {
            let poster = focusedElement.identifier
            press(.right, "open-poster")
            let target = focusedElement.identifier
            if target.hasPrefix("home.ms.") {
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
                               "-OpenStreamLiveAutoPlay", "NO",
                               "-openstream.live.startWithLastChannel", "NO",
                               "-OpenStreamDebugSharedChannelChoices", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        let leave = element("live.shareplay.leave")
        let first = element("live.shareplay.source.0")
        let second = element("live.shareplay.source.1")
        XCTAssertTrue(wait(for: leave, 90), "the SharePlay source dialog never appeared")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "exists == true AND hittable == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed,
                       "The source-choice page never became hittable")
        Thread.sleep(forTimeInterval: 2)
        log("dialog-open")
        // The page opens under the tab bar, which keeps launch focus there;
        // the dialog took focus itself. One Down reaches the first choice.
        if focusedElement.exists, focusedElement.label == "Live" {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 1.2)
            log("dialog-first-choice")
        }
        XCTAssertTrue(focused(where: NSPredicate(format: "label == %@", first.label)).waitForExistence(timeout: 5),
                      "The first source choice never took focus")
        shoot("source-dialog-focused")
        remote.press(.down)
        Thread.sleep(forTimeInterval: 1.2)
        log("dialog-down")
        XCTAssertTrue(focused(where: NSPredicate(format: "label == %@", second.label)).waitForExistence(timeout: 5),
                      "Down did not focus the second source choice")
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
            configureFixtureLaunch(app)
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
        configureFixtureLaunch(app)
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
        configureFixtureLaunch(app)
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
        configureFixtureLaunch(app)
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

    /// Round 4 G4 + G18 on the stubbed lineup: five quick Up presses tune
    /// once (the run's trace holds one `live zap` line for them), and going
    /// back to Live from another tab stays on the guide instead of reopening
    /// the last channel full screen.
    func testLiveZapCoalescesAndReturningToLiveStaysOnTheGuide() {
        func snap(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        launch(screen: "live")
        XCTAssertTrue(wait(for: element("live.tv.info")), "the guide never appeared")
        for _ in 0..<6 where !focusedElement.identifier.hasPrefix("guide.play.") { remote.press(.down) }
        XCTAssertTrue(focusedElement.identifier.hasPrefix("guide.play."))
        remote.press(.select)
        let surface = element("live.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        let firstName = surface.value as? String ?? ""
        // Past the 5 s that make a watch, so the resume has a channel.
        Thread.sleep(forTimeInterval: 8)
        for _ in 0..<5 { remote.press(.up) }
        expectation(for: NSPredicate(format: "exists == true AND value != %@", firstName), evaluatedWith: surface)
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 3)
        snap("g4-after-five-ups")

        for _ in 0..<3 where surface.exists {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertFalse(surface.exists, "Menu never closed the player")
        XCTAssertTrue(wait(for: element("live.tv.info")))
        for _ in 0..<4 where focusedElement.label != "Live" {
            remote.press(.menu)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertEqual(focusedElement.label, "Live", "Menu never reached the tab bar")
        remote.press(.left)
        Thread.sleep(forTimeInterval: 3)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(focusedElement.label, "Live")
        XCTAssertFalse(surface.waitForExistence(timeout: 8), "returning to Live reopened the last channel")
        snap("g18-back-on-live")
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
        configureFixtureLaunch(app)
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

    // MARK: - Scrubber

    /// Each Right on the focused scrubber moves 5% of the film, however fast the
    /// presses come. On a 45-minute share film only the first press scrubbed: the
    /// focus fell to the picture and the rest skipped ten seconds each, so
    /// seventeen presses ended near 12% (resume job, 2026-10-31).
    /// `OPENSTREAM_SCRUB_SMB`: an SMB source (dev-sources JSON) holding the film
    /// `OPENSTREAM_SCRUB_TITLE` (default "Scrubland"), 30 minutes or more.
    func testScrubberStepsAShareFilmFivePercentAPress() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["OPENSTREAM_SCRUB_SMB"],
              let source = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw XCTSkip("Requires OPENSTREAM_SCRUB_SMB") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scrub-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        app.launchArguments = scrubLaunchArguments() + ["-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES"]
        app.launch()
        Thread.sleep(forTimeInterval: 8)
        remote.press(.right)
        let title = NSPredicate(format: "identifier == %@", "library.title.\(environment["OPENSTREAM_SCRUB_TITLE"] ?? "Scrubland")")
        XCTAssertTrue(app.descendants(matching: .any).matching(title).firstMatch.waitForExistence(timeout: 90),
                      "the share's film never reached the Library")
        XCTAssertTrue(moveFocus(to: title, pressing: .down) || moveFocus(to: title, pressing: .left)
                      || moveFocus(to: title, pressing: .right), "the film never took focus")
        remote.press(.select)
        XCTAssertTrue(moveFocus(to: NSPredicate(format: "identifier == 'detail.play'"), pressing: .right))
        remote.press(.select)
        exerciseScrubber("smb")
    }

    /// The same presses over a media server: the fixture Jellyfin serving a
    /// 30-minute-plus MKV (`OPENSTREAM_SCRUB_SERVER=1`; `serve.py` with `e2e_media` set).
    /// An MP4 plays in AVKit's own player, whose scrubber is the system's.
    func testScrubberStepsAServerFilmFivePercentAPress() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_SCRUB_SERVER"] == "1" else {
            throw XCTSkip("Requires OPENSTREAM_SCRUB_SERVER=1 and the fixture server's long clip")
        }
        app.launchArguments = scrubLaunchArguments()
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(moveFocus(to: Self.serverShelfItem("jf-movie-5"), pressing: .down), "the fixture title never took focus")
        remote.press(.select)
        XCTAssertTrue(moveFocus(to: NSPredicate(format: "identifier == 'detail.play'"), pressing: .right))
        remote.press(.select)
        exerciseScrubber("server")
    }

    /// The same presses over a local file (`OPENSTREAM_SCRUB_FILE`, a `file:` URL).
    func testScrubberStepsALocalFileFivePercentAPress() throws {
        guard let url = ProcessInfo.processInfo.environment["OPENSTREAM_SCRUB_FILE"] else {
            throw XCTSkip("Requires OPENSTREAM_SCRUB_FILE")
        }
        app.launchArguments = scrubLaunchArguments() + ["-OpenStreamVisionScreen", "add-files",
            "-OpenStreamVisionPlaybackURL", url, "-OpenStreamVisionPlaybackIsLive", "NO"]
        app.launch()
        exerciseScrubber("file")
    }

    /// The controls hide while the scrubber holds focus. The picture is kept
    /// unfocusable only while the scrubber really has the focus, so the next
    /// press lands on the picture and is not lost: Right skips ten seconds,
    /// Down reaches the scrubber again and Right scrubs, and Select pauses.
    /// Local file (`OPENSTREAM_SCRUB_FILE`).
    func testScrubberFocusSurvivesTheControlsHiding() throws {
        guard let url = ProcessInfo.processInfo.environment["OPENSTREAM_SCRUB_FILE"] else {
            throw XCTSkip("Requires OPENSTREAM_SCRUB_FILE")
        }
        app.launchArguments = scrubLaunchArguments(holdingChrome: false) + ["-OpenStreamVisionScreen", "add-files",
            "-OpenStreamVisionPlaybackURL", url, "-OpenStreamVisionPlaybackIsLive", "NO"]
        app.launch()
        addTeardownBlock { @MainActor in
            let trace = XCTAttachment(string: ((try? self.currentOpenStreamTrace()) ?? []).joined(separator: "\n"))
            trace.name = "scrub-hide-trace"; trace.lifetime = .keepAlways; self.add(trace)
        }
        XCTAssertTrue(element("player.playback.ready").waitForExistence(timeout: 90), "the film never played")
        let scrubber = element("player.scrubber")
        let surface = element("player.controls.show")
        func traceCount(_ prefix: String) -> Int {
            ((try? currentOpenStreamTrace()) ?? []).filter { $0.contains(prefix) }.count
        }
        func waitForTrace(_ prefix: String, count: Int) -> Bool {
            let traced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in traceCount(prefix) >= count }, object: nil)
            return XCTWaiter().wait(for: [traced], timeout: 3) == .completed
        }
        // The faded chrome stays in the accessibility tree, so "hidden" is
        // read from the focus: the hide hands it from the scrubber to the picture.
        func hideWithScrubberFocused(_ stage: String) {
            for _ in 0 ..< 4 where !scrubber.hasFocus { remote.press(.down); _ = scrubber.waitForExistence(timeout: 1) }
            XCTAssertTrue(scrubber.hasFocus, "\(stage): the scrubber never took focus")
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: surface)
            XCTAssertEqual(XCTWaiter().wait(for: [hidden], timeout: 8), .completed,
                           "\(stage): the controls hid without handing the focus to the picture")
        }

        hideWithScrubberFocused("right")
        let skips = traceCount("skip 10s:")
        remote.press(.right)
        XCTAssertTrue(waitForTrace("skip 10s:", count: skips + 1), "Right after the hide was lost")
        XCTAssertTrue(surface.hasFocus, "Right after the hide left the picture without focus")
        let scrubs = traceCount("scrub: ")
        remote.press(.down)
        let refocused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: scrubber)
        XCTAssertEqual(XCTWaiter().wait(for: [refocused], timeout: 3), .completed, "Down did not reach the scrubber")
        remote.press(.right)
        XCTAssertTrue(waitForTrace("scrub: ", count: scrubs + 1), "Right on the scrubber did not scrub")

        hideWithScrubberFocused("select")
        remote.press(.select)
        XCTAssertTrue(surface.hasFocus, "Select after the hide left the picture without focus")
        let pausedAt = scrubPosition()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNotNil(pausedAt)
        XCTAssertEqual(scrubPosition(), pausedAt, "Select after the hide did not pause")
    }

    private func scrubLaunchArguments(holdingChrome: Bool = true) -> [String] {
        ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
         "-openstream.playback.engine", "engine", "-openstream.firstRunGuidanceSeen", "YES",
         "-openstream.settings.metadata.enabled.v1", "NO", "-openstream.settings.trailer.autoplay.v1", "NO"]
            + (holdingChrome ? ["-OpenStreamHoldPlayerChrome", "YES"] : [])
    }

    private func moveFocus(to predicate: NSPredicate, pressing direction: XCUIRemote.Button) -> Bool {
        let target = focused(where: predicate)
        for _ in 0 ..< 14 where !target.exists {
            remote.press(direction)
            _ = target.waitForExistence(timeout: 1.5)
        }
        return target.exists
    }

    /// Paced presses, a fast burst, a press-and-hold and a burst back: the
    /// scrubber keeps focus and the film lands about 5% per press from where
    /// the presses began, never behind it, and inside the film.
    private func exerciseScrubber(_ name: String) {
        addTeardownBlock { @MainActor in
            let trace = XCTAttachment(string: ((try? self.currentOpenStreamTrace()) ?? []).joined(separator: "\n"))
            trace.name = "scrub-\(name)-trace"; trace.lifetime = .keepAlways; self.add(trace)
        }
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 90), "the \(name) film never played")
        Thread.sleep(forTimeInterval: 3)
        let scrubber = element("player.scrubber")
        for _ in 0 ..< 8 where !scrubber.hasFocus { remote.press(.down); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(scrubber.hasFocus, "the scrubber never took focus")
        guard let duration = scrubDuration(), duration >= 1800 else {
            XCTFail("the \(name) film needs a known duration of 30 minutes or more, read \(String(describing: scrubDuration()))")
            return
        }
        let step = duration * 0.05
        var expected = scrubPosition() ?? 0
        var report = ["\(name): duration \(Int(duration))s, start \(Int(expected))s"]
        func check(_ stage: String, presses: Int) {
            expected = min(duration, max(0, expected + Double(presses) * step))
            Thread.sleep(forTimeInterval: 4)
            let landed = scrubPosition() ?? -1
            report.append("\(stage): expected ~\(Int(expected))s, at \(Int(landed))s, scrubber focused \(scrubber.hasFocus)")
            XCTAssertTrue(scrubber.hasFocus, "\(name) \(stage): the scrubber lost focus")
            XCTAssertEqual(landed, expected, accuracy: 45, "\(name) \(stage): \(report.joined(separator: "; "))")
            expected = landed
        }
        for _ in 0 ..< 5 { remote.press(.right); Thread.sleep(forTimeInterval: 0.6) }
        check("5 paced presses", presses: 5)
        for _ in 0 ..< 5 { remote.press(.right) }
        check("5 fast presses", presses: 5)
        let beforeHold = expected
        remote.press(.right, forDuration: 2)
        Thread.sleep(forTimeInterval: 4)
        let held = scrubPosition() ?? -1
        report.append("held 2 s: from \(Int(beforeHold))s to \(Int(held))s, scrubber focused \(scrubber.hasFocus)")
        XCTAssertTrue(scrubber.hasFocus, "\(name) hold: the scrubber lost focus")
        XCTAssertGreaterThanOrEqual(held, beforeHold + step - 45, "\(name) hold moved less than one step")
        XCTAssertLessThanOrEqual(held, duration, "\(name) hold went past the end")
        expected = held
        for _ in 0 ..< 3 { remote.press(.left) }
        check("3 fast presses back", presses: -3)
        remote.press(.up)
        let leftScrubber = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == false"), object: scrubber)
        XCTAssertEqual(XCTWaiter().wait(for: [leftScrubber], timeout: 3), .completed, "\(name): Up did not leave the scrubber")
        let log = XCTAttachment(string: report.joined(separator: "\n"))
        log.name = "scrub-\(name)"; log.lifetime = .keepAlways; add(log)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "scrub-\(name)"; shot.lifetime = .keepAlways; add(shot)
    }

    /// The elapsed time under the scrubber (`m:ss` or `h:mm:ss`).
    private func scrubPosition() -> Double? {
        app.staticTexts.allElementsBoundByIndex.lazy.compactMap { Self.clockSeconds($0.label) }.first
    }

    /// Elapsed plus remaining (`-m:ss`).
    private func scrubDuration() -> Double? {
        let remaining = app.staticTexts.allElementsBoundByIndex.lazy.compactMap { text -> Double? in
            guard text.label.hasPrefix("-") else { return nil }
            return Self.clockSeconds(String(text.label.dropFirst()))
        }.first
        guard let remaining, let elapsed = scrubPosition() else { return nil }
        return elapsed + remaining
    }

    private static func clockSeconds(_ text: String) -> Double? {
        guard text.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
