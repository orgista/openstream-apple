import XCTest
import CoreGraphics
import ImageIO
#if os(macOS)
import AppKit
#elseif !os(tvOS)
import UIKit
#endif

/// Runs only with the demo launch environment supplied by the local test runner.
/// No demo address or credential is stored in the project or test plan.
@MainActor
final class AppStoreScreenshotUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    private var serverAdded = false
    private var liveAdded = false
    private var downloadAttempted = false
    private var emptyDownloadsVerified = false
    private var demoHost = ""
    private var playlistHost = ""
    private var playing = false
    private var captureURL: URL?

    private var uiSurface: XCUIElement {
        #if os(visionOS)
        // The tab ornament can be first; scroll the content window instead.
        app.windows.allElementsBoundByIndex.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        } ?? app.windows.firstMatch
        #elseif os(macOS)
        app.windows.firstMatch
        #else
        app
        #endif
    }

    private func cleanupDemo() throws {
        continueAfterFailure = true
        defer { app.terminate() }
        if serverAdded || liveAdded || downloadAttempted {
            if liveAdded || playing { app.terminate(); app.launch(); playing = false }
            else if app.state != .runningForeground { app.launch() }
            if playing { try playerControl("player.close"); playing = false }
            try removeDemoDownloads()
            try removeDemoSources()
        }
    }

    private func revealPlayerControls() {
        guard !element("player.close").exists else { return }
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #else
        let surface = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "player.controls.show")).allElementsBoundByIndex.first { $0.isHittable }
        if let surface { surface.tap() }
        else { uiSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap() }
        #endif
    }

    private func playerControl(_ identifier: String) throws {
        #if os(tvOS)
        if identifier == "player.close" {
            for _ in 0..<3 {
                XCUIRemote.shared.press(.menu)
                Thread.sleep(forTimeInterval: 1)
                if element("detail.play").isHittable { break }
            }
            return
        }
        #endif
        revealPlayerControls()
        if identifier == "player.close", !element(identifier).exists {
            // Live's hidden-background tap opens its channel picker.
            try activate(element("live.picker.back"))
        } else {
            try activate(element(identifier))
        }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func activate(_ target: XCUIElement) throws {
        guard target.waitForExistence(timeout: 30) else {
            XCTFail("Expected navigation control is absent")
            throw NavigationFailure.unreachable
        }
        #if os(tvOS)
        var focusTrace: [String] = []
        for step in 0..<60 {
            if target.hasFocus { XCUIRemote.shared.press(.select); Thread.sleep(forTimeInterval: 0.7); return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
                .allElementsBoundByIndex.filter { $0.frame.width > 0 && $0.frame.height > 0 }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            focusTrace.append("step \(step): \(focused?.identifier ?? "none") \(focused?.frame ?? .zero) target \(target.identifier) \(target.frame)")
            if let focused {
                let from = focused.frame, to = target.frame
                if to.width > 0, to.height > 0,
                   from.contains(CGPoint(x: to.midX, y: to.midY)),
                   (focused.elementType == .cell || focused.elementType == .button),
                   from.height <= to.height * 4 {
                    XCUIRemote.shared.press(.select)
                    Thread.sleep(forTimeInterval: 0.7)
                    return
                }
                if from.midY < 150 && to.midY > 150 {
                    XCUIRemote.shared.press(.down)
                } else if from.width >= 350, from.maxX <= 520, to.minX > 520 {
                    XCUIRemote.shared.press(.right)
                } else if to.width >= 350, to.maxX <= 520, from.minX > 520 {
                    XCUIRemote.shared.press(.left)
                } else if abs(to.midY - from.midY) > 35 {
                    XCUIRemote.shared.press(to.midY > from.midY ? .down : .up)
                } else if from.maxX < to.minX - 20 {
                    XCUIRemote.shared.press(.right)
                } else if from.minX > to.maxX + 20 {
                    XCUIRemote.shared.press(.left)
                } else {
                    XCUIRemote.shared.press(to.midX > from.midX ? .right : .left)
                }
            } else {
                XCUIRemote.shared.press(step % 2 == 0 ? .up : .right)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        capture("failure-focus")
        let focus = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
            .allElementsBoundByIndex.map { "\($0.elementType.rawValue) \($0.identifier) \($0.frame)" }.joined(separator: "\n")
        let proof = XCTAttachment(string: focusTrace.joined(separator: "\n") + "\n" + focus + "\nTarget: \(target.frame)")
        proof.name = "proof-focus-geometry"; proof.lifetime = .keepAlways; add(proof)
        XCTFail("Remote could not reach the requested control")
        throw NavigationFailure.unreachable
        #else
        if !target.isHittable {
            #if os(iOS)
            uiSurface.swipeUp()
            #endif
        }
        target.tap()
        #endif
    }

    private func tab(_ name: String) throws {
        #if os(tvOS)
        for _ in 0..<6 { XCUIRemote.shared.press(.up); Thread.sleep(forTimeInterval: 0.3) }
        #endif
        let target = app.descendants(matching: .any).matching(NSPredicate(format:
            "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)", name,
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.tab.rawValue,
            XCUIElement.ElementType.radioButton.rawValue)).firstMatch
        try activate(target)
        #if os(tvOS)
        Thread.sleep(forTimeInterval: 3)
        #endif
    }

    private func back() {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        let back = app.navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        #endif
    }

    private func verifyPinnedLivePicture() throws {
        #if os(iOS)
        try verifyPicture(in: CGRect(x: 0.1, y: 0.14, width: 0.8, height: 0.18))
        #endif
    }

    private func verifyPicture(in region: CGRect) throws {
        // The selected fixture frame is bright; an error-free black player must fail.
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let picture = try XCTUnwrap(image.cropping(to: CGRect(
            x: Double(image.width) * region.minX, y: Double(image.height) * region.minY,
            width: Double(image.width) * region.width, height: Double(image.height) * region.height)))
        var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
        let mean = try pixels.withUnsafeMutableBytes { buffer -> Double in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 64, height: 32,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(picture, in: CGRect(x: 0, y: 0, width: 64, height: 32))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).reduce(0.0) {
                $0 + Double(bytes[$1]) + Double(bytes[$1 + 1]) + Double(bytes[$1 + 2])
            } / Double(64 * 32 * 3)
        }
        XCTAssertGreaterThan(mean, 10, "The fixture's video picture is black")
    }

    private func waitForPlayer(timeout: TimeInterval) {
        #if os(tvOS)
        // TV closes with Menu and its native player has no app Close identifier.
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == false"),
                                                 object: element("detail.play"))
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: timeout), .completed)
        #else
        XCTAssertTrue(element("player.close").waitForExistence(timeout: timeout))
        #endif
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 2)
        #if os(macOS)
        let screenProof = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenProof.name = "proof-screen-" + name
        screenProof.lifetime = .keepAlways
        add(screenProof)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #elseif os(visionOS)
        // XCUIScreen.main on this runtime returns a 1×1 placeholder. The
        // foreground runner supplies the native compositor PNG at this exact
        // checkpoint, before the test continues to another scene.
        guard let captureURL else { XCTFail("The Vision capture service is absent"); return }
        let attachment: XCTAttachment
        do {
            let data = try send(URLRequest(url: captureURL))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let picture = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(picture.width, 3840)
            XCTAssertEqual(picture.height, 2160)
            attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        } catch { XCTFail("The native Vision screenshot could not be captured"); return }
        #else
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fill(_ identifier: String, _ value: String) throws {
        let secure = app.secureTextFields.matching(identifier: identifier).firstMatch
        let identified = app.textFields.matching(identifier: identifier).firstMatch
        let fallback = ["sources.live.name": "Name", "sources.live.endpoint": "Playlist URL"][identifier]
        let text = identified.exists ? identified : (fallback.map { app.textFields[$0] } ?? identified)
        let field = secure.exists ? secure : text
        try activate(field)
        field.typeText(value)
        if !secure.exists {
            XCTAssertEqual(field.value as? String, value, "The input field dropped characters")
        }
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #endif
    }

    private func sources() throws {
        try tab("Settings")
        #if os(tvOS)
        try activate(button("Sources"))
        Thread.sleep(forTimeInterval: 2)
        #else
        if button("Media Server").exists { return }
        for _ in 0..<3 where !button("Sources").exists { back() }
        #if os(iOS)
        for _ in 0..<4 where !button("Sources").exists { uiSurface.swipeDown() }
        #endif
        try activate(button("Sources"))
        #endif
    }

    func testAppStorePass() throws {
        // XCTest awaits this block even when immediate failure aborts the test body.
        // The async block preserves the UI helpers' MainActor isolation.
        addTeardownBlock { @MainActor [self] () async throws in try cleanupDemo() }
        let processEnvironment = ProcessInfo.processInfo.environment
        var env = processEnvironment
        if let hex = processEnvironment["OPENSTREAM_DEMO_CONFIG_HEX"] {
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { offset -> UInt8? in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: 2)
                return UInt8(hex[start..<end], radix: 16)
            }
            env = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: String])
        }
        guard let server = env["OPENSTREAM_DEMO_SERVER"],
              let user = env["OPENSTREAM_DEMO_USER"],
              let password = env["OPENSTREAM_DEMO_PASSWORD"],
              let playlist = env["OPENSTREAM_TEST_M3U"] else {
            throw XCTSkip("The private demo launch environment is required")
        }
        continueAfterFailure = false
        XCTAssertTrue(server.contains("://"), "The demo server environment lost its URL scheme delimiter")
        XCTAssertFalse(password.isEmpty, "The demo password environment is empty")
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
                               "-openstream.backup.icloud.enabled.v1", "NO"]
        app.launchEnvironment = ["OPENSTREAM_DEMO_SERVER": server, "OPENSTREAM_DEMO_USER": user,
                                 "OPENSTREAM_DEMO_PASSWORD": password, "OPENSTREAM_TEST_M3U": playlist]
        captureURL = env["OPENSTREAM_DEMO_CAPTURE_URL"].flatMap(URL.init(string:))
        demoHost = URL(string: server)?.host ?? ""
        playlistHost = URL(string: playlist)?.host ?? ""
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        #if os(macOS)
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
        let size = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1437, dy: 897))
        corner.press(forDuration: 0.1, thenDragTo: size)
        #endif
        if button("Not Now").waitForExistence(timeout: 8) { try activate(button("Not Now")) }
        if env["OPENSTREAM_DEMO_CLEAN_STALE"] == "YES" {
            serverAdded = true
            liveAdded = true
            try removeDemoSources()
            app.terminate()
            app.launch()
        }
        XCTAssertFalse(app.staticTexts["Couldn't Load Your Catalogs"].exists)
        XCTAssertTrue(app.staticTexts["No Sources"].waitForExistence(timeout: 30), "The demo pass requires an empty supported source list")
        capture("proof-welcome")
        try activate(element("emptyState.footnote"))
        #if os(tvOS)
        // tvOS can expose sheet text as a combined accessibility label.
        let noContent = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Add your own sources.")).firstMatch
        if !noContent.waitForExistence(timeout: 15) { capture("failure-attribution") }
        XCTAssertTrue(noContent.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "JustWatch")).firstMatch.exists)
        #else
        XCTAssertTrue(element("settings.about.noContent").waitForExistence(timeout: 15))
        XCTAssertTrue(element("settings.about.justwatch").exists)
        #endif
        capture("proof-credits")
        try activate(button("Done"))
        try sources()
        capture("07-sources")
        #if os(iOS)
        back()
        for _ in 0..<4 where !button("Storage").exists { uiSurface.swipeUp() }
        try activate(button("Storage"))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(button("Delete All Downloads").isEnabled, "Demo downloads require an initially empty download store")
        emptyDownloadsVerified = true
        back()
        try sources()
        #endif
        try activate(button("Media Server"))
        try fill("sources.mediaServer.name", "Home Server")
        try fill("sources.mediaServer.url", server)
        #if os(tvOS)
        let quick = element("sources.mediaServer.quickConnect")
        XCTAssertTrue(quick.waitForExistence(timeout: 15))
        try activate(quick)
        let code = element("sources.mediaServer.quickConnect.code")
        XCTAssertTrue(code.waitForExistence(timeout: 15))
        let token = try authenticate(server: server, user: user, password: password)
        var parts = URLComponents(string: server + "/QuickConnect/Authorize")!
        parts.queryItems = [URLQueryItem(name: "code", value: code.label.filter(\.isNumber))]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        try send(request)
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: code)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 45), .completed, "Quick Connect did not save the source")
        #else
        try fill("sources.mediaServer.username", user)
        try fill("sources.mediaServer.password", password)
        #if os(iOS)
        app.toolbars.buttons["Done"].firstMatch.tapIfPresent()
        #endif
        XCTAssertEqual(app.textFields.matching(identifier: "sources.mediaServer.url").firstMatch.value as? String, server)
        try activate(element("sources.mediaServer.save"))
        #endif
        serverAdded = true
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("sources.mediaServer.save"))
        let saveResult = XCTWaiter.wait(for: [saved], timeout: 45)
        if saveResult != .completed { capture("failure-source-save") }
        XCTAssertEqual(saveResult, .completed, "Source save did not dismiss the form")
        app.terminate()
        app.launch()
        try tab("Discover")
        let movies = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.ms.' AND label CONTAINS[c] 'Big Buck Bunny'"))
        let movie = movies.firstMatch
        var visibleMovie: XCUIElement? {
            let visible = movies.allElementsBoundByIndex.filter {
                $0.frame.width > 0 && uiSurface.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            #if os(tvOS)
            return visible.first(where: { $0.hasFocus }) ?? visible.first
            #else
            return visible.first
            #endif
        }
        let firstPoster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.ms.'")).firstMatch
        #if os(tvOS)
        for _ in 0..<8 where !firstPoster.exists {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.7)
        }
        #endif
        XCTAssertTrue(firstPoster.waitForExistence(timeout: 90), "Saved server did not produce its library after relaunch")
        Thread.sleep(forTimeInterval: 8)
        #if os(iOS)
        // Show the populated library rails together in the portrait store shot.
        uiSurface.swipeUp()
        #endif
        capture("01-discover")
        #if os(tvOS)
        for _ in 0..<3 { XCUIRemote.shared.press(.down); Thread.sleep(forTimeInterval: 0.5) }
        #else
        // The billboard and Continue Watching can place Latest below the viewport.
        // A swipe at its offscreen Y hits the system gesture area instead of the shelf.
        for _ in 0..<8 where firstPoster.frame.midY > uiSurface.frame.maxY - 120 || firstPoster.frame.width == 0 {
            uiSurface.swipeUp()
        }
        #endif
        let shelfY = min(max(firstPoster.frame.midY, uiSurface.frame.minY + 160), uiSurface.frame.maxY - 160)
        for _ in 0..<12 {
            if visibleMovie != nil { break }
            #if os(tvOS)
            XCUIRemote.shared.press(.right)
            #else
            uiSurface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: uiSurface.frame.width * 0.9, dy: shelfY - uiSurface.frame.minY))
                .press(forDuration: 0.05, thenDragTo: uiSurface.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: uiSurface.frame.width * 0.1, dy: shelfY - uiSurface.frame.minY)))
            #endif
        }
        XCTAssertTrue(movie.exists, "The demo movie is absent from the shelf")
        // Pin the identifier: a lazy firstMatch query changes when another shelf
        // scrolls into view, even while the remote is approaching its target.
        let chosenMovie = visibleMovie ?? movie
        try activate(element(chosenMovie.identifier))
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        XCTAssertFalse(element("detail.play").label.isEmpty)
        capture("02-title")
        try activate(element("detail.play"))
        playing = true
        waitForPlayer(timeout: 45)
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        Thread.sleep(forTimeInterval: 20)
        #if os(tvOS)
        XCUIRemote.shared.press(.playPause)
        #else
        revealPlayerControls()
        #endif
        if element("player.play-pause").exists, element("player.play-pause").label == "Pause" {
            #if os(tvOS)
            try playerControl("player.play-pause")
            #else
            element("player.play-pause").tap()
            #endif
        }
        capture("04-player")
        #if os(tvOS)
        try verifyPicture(in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        for _ in 0..<6 { XCUIRemote.shared.press(.right); Thread.sleep(forTimeInterval: 0.5) }
        XCUIRemote.shared.press(.select)
        Thread.sleep(forTimeInterval: 3)
        #else
        revealPlayerControls()
        XCTAssertFalse(element("player.play-pause").label.isEmpty)
        if element("player.skip-forward").exists {
            for _ in 0..<3 { try playerControl("player.skip-forward") }
        }
        #endif
        try playerControl("player.close")
        playing = false
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 30))
        let resume = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Resume'"), object: element("detail.play"))
        let resumed = XCTWaiter.wait(for: [resume], timeout: 15)
        if resumed != .completed { capture("failure-resume") }
        XCTAssertEqual(resumed, .completed, "Playback did not retain a resume position")
        try activate(element("detail.play"))
        playing = true
        waitForPlayer(timeout: 30)
        try playerControl("player.close")
        playing = false
        #if os(iOS)
        let download = element("detail.download")
        XCTAssertTrue(download.waitForExistence(timeout: 30))
        downloadAttempted = true
        try activate(download)
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Downloaded'"), object: download)
        let downloaded = XCTWaiter.wait(for: [complete], timeout: 180)
        if downloaded != .completed { capture("failure-download") }
        XCTAssertEqual(downloaded, .completed, "The demo download did not complete")
        try activate(element("detail.play"))
        playing = true
        waitForPlayer(timeout: 45)
        Thread.sleep(forTimeInterval: 3)
        try playerControl("player.close")
        playing = false
        #endif
        back()
        try tab("Library")
        try tab("Discover")
        #if os(tvOS)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        #else
        for _ in 0..<4 { uiSurface.swipeDown() }
        uiSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: uiSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        #endif
        Thread.sleep(forTimeInterval: 3)
        capture("06-continue-watching")
        try sources()
        let addLive = app.buttons.matching(NSPredicate(format:
            "label == %@ AND NOT (identifier BEGINSWITH %@)", "Live TV", "settings.section.")).firstMatch
        try activate(addLive)
        #if os(tvOS)
        try activate(element("sources.live.type.m3u"))
        #else
        let typePicker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Xtream Account")).firstMatch
        try activate(typePicker)
        try activate(button("M3U Playlist"))
        #endif
        try fill("sources.live.name", "Open Movies")
        try fill("sources.live.endpoint", playlist)
        #if os(iOS)
        app.toolbars.buttons["Done"].firstMatch.tapIfPresent()
        #endif
        try activate(element("sources.live.save"))
        liveAdded = true
        try tab("Live")
        Thread.sleep(forTimeInterval: 8)
        let channel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'guide.play.' AND label CONTAINS[c] 'Spring'")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "The fixture guide has no playable channels")
        XCTAssertFalse(channel.label.isEmpty)
        try activate(channel)
        // Spring's opening has a dark title fade near 18–20 seconds.
        // Wait for the film scene before returning to the pinned player.
        Thread.sleep(forTimeInterval: 30)
        XCTAssertFalse(element("live.failure").exists)
        XCTAssertFalse(app.staticTexts["Playback Failed"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Live playback presented an error alert")
        #if os(visionOS)
        capture("05-live")
        // The channel plays in the window's player stage, not AVKit's modal
        // (which XCTest could not leave): its close button returns to Live.
        try playerControl("player.close")
        #endif
        #if os(tvOS)
        for _ in 0..<3 where !channel.isHittable {
            XCUIRemote.shared.press(.menu)
            Thread.sleep(forTimeInterval: 1)
        }
        #elseif !os(macOS) && !os(visionOS)
        if element("live.picker.back").exists { try activate(element("live.picker.back")) }
        else { try playerControl("player.close") }
        #endif
        Thread.sleep(forTimeInterval: 3)
        #if !os(visionOS)
        try verifyPinnedLivePicture()
        capture("05-live")
        #endif
        try tab("Settings")
        #if !os(tvOS)
        back()
        #endif
        // Settings can retain the Sources subpage, which includes private addresses.
        // Its screenshot is captured after the demo sources are removed below.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'add-on'")).firstMatch.exists)
        // Cleanup uses the same source editor as the owner; it never resets the app.
        try removeDemoDownloads()
        try removeDemoSources()
        try tab("Settings")
        #if !os(tvOS)
        back()
        #endif
        capture("09-settings")
        #if os(visionOS)
        for _ in 0..<8 where !button("About").exists { app.collectionViews.firstMatch.swipeUp() }
        #elseif !os(tvOS)
        for _ in 0..<4 where !button("About").exists { uiSurface.swipeUp() }
        #endif
        try activate(button("About"))
        #if os(tvOS)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Source Code")).firstMatch.waitForExistence(timeout: 15))
        #else
        XCTAssertTrue(element("settings.about.sourceCode").waitForExistence(timeout: 15))
        #endif
        try activate(button("Third-Party Notices"))
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "AetherEngine")).firstMatch.waitForExistence(timeout: 15))
        capture("proof-third-party-notices")
        back()
    }

    // MARK: Release-candidate pass (what App Review sees)

    /// A clean install of the App Store flavour, driven the way the review
    /// notes tell a reviewer: first launch, the no-content line, Add Live TV
    /// with Apple's public sample playlist (pasted, or typed as an address on
    /// Apple TV), a channel playing, then every top-level Settings page, each
    /// scanned for add-on wording. Runs only with `OPENSTREAM_RC=1` (pass
    /// `TEST_RUNNER_OPENSTREAM_RC=1`); Apple TV also needs
    /// `OPENSTREAM_RC_M3U_URL`, a URL serving the same playlist. Leaves the
    /// playlist behind: the runner deletes the app afterwards.
    func testReviewerReleaseCandidate() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OPENSTREAM_RC"] == "1" else { throw XCTSkip("The release-candidate pass runs only with OPENSTREAM_RC=1") }
        continueAfterFailure = true
        captureURL = env["OPENSTREAM_DEMO_CAPTURE_URL"].flatMap(URL.init(string:))
        app.launchArguments = ["-OpenStreamMuteAudio", "YES", "-OpenStreamTrace", "YES",
                               "-openstream.backup.icloud.enabled.v1", "NO"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        Thread.sleep(forTimeInterval: 4)
        rcCapture("01-first-launch")
        if button("Not Now").waitForExistence(timeout: 8) { try activate(button("Not Now")) }
        XCTAssertTrue(app.staticTexts["No Sources"].waitForExistence(timeout: 30), "First launch is not empty")
        rcCapture("02-no-sources")
        try activate(element("emptyState.footnote"))
        let noContent = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "doesn't provide any content")).firstMatch
        XCTAssertTrue(noContent.waitForExistence(timeout: 15), "No Sources has no no-content line behind its (i)")
        rcCapture("03-no-content-line")
        try activate(button("Done"))

        try sources()
        rcCapture("04-sources")
        let addLive = app.buttons.matching(NSPredicate(format:
            "label == %@ AND NOT (identifier BEGINSWITH %@)", "Live TV", "settings.section.")).firstMatch
        try activate(addLive)
        #if os(tvOS)
        try activate(element("sources.live.type.m3u"))
        try fill("sources.live.name", "Apple Samples")
        let address = try XCTUnwrap(env["OPENSTREAM_RC_M3U_URL"], "Apple TV needs OPENSTREAM_RC_M3U_URL")
        try fill("sources.live.endpoint", address)
        #else
        try activate(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Xtream Account")).firstMatch)
        try activate(button("M3U Playlist"))
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.reviewPlaylist, forType: .string)
        #else
        UIPasteboard.general.string = Self.reviewPlaylist
        #endif
        let paste = element("sources.live.paste")
        #if os(iOS)
        for _ in 0..<3 where !paste.isHittable { uiSurface.swipeUp() }
        #endif
        try activate(paste)
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Pasted Playlist")).firstMatch.waitForExistence(timeout: 10),
            "Paste did not take the playlist")
        #endif
        rcCapture("05-add-live-tv")
        try activate(element("sources.live.save"))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("sources.live.save"))
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 60), .completed, "Add Live TV did not save")
        rcCapture("06-sources-with-playlist")

        try tab("Live")
        Thread.sleep(forTimeInterval: 8)
        rcCapture("07-live")
        let channel = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'guide.play.' AND label CONTAINS[c] 'Apple Sample (fMP4)'")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 30), "The sample playlist shows no channel")
        try activate(channel)
        Thread.sleep(forTimeInterval: 20)
        XCTAssertFalse(element("live.failure").exists, "The sample channel failed")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Live playback presented an alert")
        rcCapture("08-live-playing")
        #if os(tvOS) || os(iOS)
        // Apple's sample is a bright test card in the middle of the screen.
        try verifyPicture(in: CGRect(x: 0.3, y: 0.42, width: 0.4, height: 0.12))
        #endif

        #if os(tvOS)
        // A relaunch resumes the last channel full screen; Menu leaves it.
        for _ in 0..<3 where !channel.isHittable { XCUIRemote.shared.press(.menu); Thread.sleep(forTimeInterval: 1) }
        #else
        // Settings from a fresh launch: the player covers the tab bar.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 45))
        Thread.sleep(forTimeInterval: 3)
        #endif
        try tab("Settings")
        #if os(tvOS)
        for section in ["sources", "channels", "restrictions", "liveTV", "discover", "services",
                        "playback", "privacy", "storage", "about"] {
            try activate(element("settings.section." + section))
            Thread.sleep(forTimeInterval: 2)
            rcCapture("10-settings-" + section)
        }
        #else
        for _ in 0..<3 where !button("Sources").exists { back() }
        rcCapture("10-settings")
        var visited: Set<String> = []
        let list = app.collectionViews.firstMatch
        for _ in 0..<18 {
            let rows = list.buttons.allElementsBoundByIndex
                .filter { $0.isHittable && !$0.label.isEmpty }
                .map(\.label)
                .filter { !visited.contains($0) && !Self.rcSkippedRows.contains($0) && !Self.tabTitles.contains($0) }
                .filter { label in !["Reset", "Erase", "Delete", "Sign Out", "Sync Now"].contains { label.contains($0) } }
            guard let label = rows.first else {
                list.swipeUp()
                continue
            }
            visited.insert(label)
            try activate(button(label))
            Thread.sleep(forTimeInterval: 2)
            rcCapture("10-settings-" + label.filter { $0.isLetter || $0.isNumber })
            back()
            Thread.sleep(forTimeInterval: 1)
        }
        #endif
    }

    private static let tabTitles: Set<String> = ["Search", "Discover", "Library", "Live", "Settings"]
    /// Rows that act instead of opening a page.
    private static let rcSkippedRows: Set<String> = ["Back", "Done", "Close", "Sync Now", "Erase This Device", "Reset"]
    private static let reviewPlaylist = """
        #EXTM3U
        #EXTINF:-1 group-title="Samples",Apple Sample (HLS)
        https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8
        #EXTINF:-1 group-title="Samples",Apple Sample (fMP4)
        https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8
        #EXTINF:-1 group-title="Samples",Apple Sample (HEVC)
        https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8
        #EXTINF:-1 group-title="Samples",Apple Sample (Dolby Vision)
        https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8
        #EXTINF:-1 group-title="Open Movies",Big Buck Bunny (Blender Foundation, CC BY)
        https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
        """

    /// A screenshot plus a scan of everything on screen for add-on wording.
    private func rcCapture(_ name: String) {
        capture(name)
        let text = app.debugDescription.lowercased()
        for word in ["stremio", "add-on", "addon", "torrent", "magnet", "debrid", "infohash", "premiumize", "torbox"]
            where text.contains(word) {
            XCTFail("\(name) shows \"\(word)\"")
        }
    }

    private func removeDemoDownloads() throws {
        #if os(iOS)
        guard emptyDownloadsVerified, downloadAttempted else { return }
        try tab("Settings")
        for _ in 0..<3 where !button("Storage").exists { back() }
        for _ in 0..<4 where !button("Storage").exists { uiSurface.swipeUp() }
        try activate(button("Storage"))
        Thread.sleep(forTimeInterval: 2)
        let remove = button("Delete All Downloads")
        if remove.isEnabled {
            try activate(remove)
            try activate(app.alerts.buttons["Delete"])
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: remove)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 30), .completed)
        }
        downloadAttempted = false
        back()
        #endif
    }

    private func removeDemoSources() throws {
        for name in [serverAdded ? "Home Server" : nil, liveAdded ? "Open Movies" : nil].compactMap({ $0 }) {
            try sources()
            let host = name == "Home Server" ? demoHost : playlistHost
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, host)).firstMatch
            #if !os(tvOS)
            for _ in 0..<4 where !row.exists { uiSurface.swipeUp() }
            #endif
            if row.waitForExistence(timeout: 5) {
                try activate(row)
                #if !os(tvOS)
                for _ in 0..<4 where !button("Delete Source").exists && !button("Remove Source").exists { uiSurface.swipeUp() }
                #endif
                let remove = button("Remove Source")
                if remove.exists { try activate(remove) }
                else if button("Delete Source").exists { try activate(button("Delete Source")) }
                let confirm = button("Remove")
                if confirm.waitForExistence(timeout: 2) { try activate(confirm) }
                else if button("Delete").waitForExistence(timeout: 2) { try activate(button("Delete")) }
                let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
                XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed, "The demo source was not removed")
            }
            if name == "Home Server" { serverAdded = false } else { liveAdded = false }
        }
    }

    private func authenticate(server: String, user: String, password: String) throws -> String {
        var request = URLRequest(url: URL(string: server + "/" + "Users/AuthenticateByName")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaBrowser Client=\"OpenStream UITests\", Device=\"Simulator\", DeviceId=\"screenshots\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": user, "Pw": password])
        let data = try send(request)
        return try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["AccessToken"] as? String)
    }

    @discardableResult private func send(_ request: URLRequest) throws -> Data {
        // XCTest's expectation keeps this synchronous UI test on its actor while
        // URLSession performs the request. Credentials never enter attachments.
        let done = expectation(description: "Demo server answered")
        let result = ResponseBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            result.set(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return try result.value()
    }
    private enum NavigationFailure: Error { case unreachable }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var status: Int?
    private var error: Error?
    func set(data: Data?, status: Int?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        self.data = data; self.status = status; self.error = error
    }
    func value() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        guard status == 200 || status == 204, let data else { throw URLError(.badServerResponse) }
        return data
    }
}

#if !os(tvOS)
private extension XCUIElement {
    func tapIfPresent() { if exists { tap() } }
}
#endif
