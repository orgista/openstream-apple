import XCTest

/// Base for every UI test class: a failed test leaves a full-screen
/// screenshot in the result bundle, taken before the subclass tears the app
/// down, so a red run can be read without re-running it.
@MainActor
class OpenStreamUITestCase: XCTestCase {
    override func tearDownWithError() throws {
        if let run = testRun, run.totalFailureCount > 0 {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "failure-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        try super.tearDownWithError()
    }

    /// The stub fixtures beside the test plans (`Apps/TestPlans/Stubs`): from
    /// the plan's `OPENSTREAM_STUB_DIR`, else resolved from this file's path.
    static var stubDirectory: String {
        if let path = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"], !path.isEmpty { return path }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestPlans/Stubs").path
    }

    /// Launch arguments for a stubbed, silent, traced run.
    static var stubbedLaunchArguments: [String] {
        ["-OpenStreamStubNetwork", stubDirectory, "-OpenStreamResetOnLaunch", "YES",
         "-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES"]
    }

    /// A fixture Jellyfin title on a Discover shelf (`Tests/Fixtures/serve.py`, /jf):
    /// `home.ms.<shelf>.ms:<source>:<item>`.
    static func serverShelfItem(_ itemID: String) -> NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH 'home.ms.' AND identifier ENDSWITH %@", ":" + itemID)
    }

    /// `-OpenStreamDevSources` with only a TMDB key, so a stubbed run can search
    /// (`TestPlans/Stubs/api.themoviedb.org`). The app deletes the file once read.
    func tmdbFixtureKeyLaunchArguments() throws -> [String] {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tmdb-fixture-\(UUID().uuidString).json")
        try Data(#"{"version":1,"sources":[],"settings":{"tmdbAPIKey":"fixture"}}"#.utf8).write(to: file)
        return ["-OpenStreamDevSources", file.path]
    }
    /// Lazy Form rows must be built, and completely above the floating tab bar, before a tap.
    func scrollToControl(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 12) {
        for _ in 0..<limit {
            let bar = app.tabBars.firstMatch
            let bottom = bar.exists && bar.frame.minY > app.frame.midY ? bar.frame.minY - 16 : app.frame.maxY - 16
            if element.exists, element.frame.minY >= app.frame.minY + 70,
               element.frame.maxY < bottom, element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// Test-plan arguments belong to the runner. Forward fixture settings to each
    /// app launch, including tests that replace launchArguments between routes.
    func configureFixtureLaunch(_ app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false else { return }
        let mediaBase = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_MEDIA_BASE"] ?? "http://127.0.0.1:8767"
        for (key, value) in [("-OpenStreamStubNetwork", Self.stubDirectory),
                             ("-OpenStreamStubMediaBase", mediaBase),
                             ("-OpenStreamMuteAudio", "YES"), ("-OpenStreamTrace", "YES")] {
            if !app.launchArguments.contains(key) { app.launchArguments += [key, value] }
        }
    }

    func startupFixtureArguments() throws -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_STARTUP_FIXTURE_BASE"], !raw.isEmpty else {
            throw XCTSkip("Requires playback_startup_proof.py's local fixture")
        }
        let base = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(base.host, "127.0.0.1")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("startup-\(UUID()).json")
        let source = ["kind": "mediaServer", "server": "jellyfin", "name": "Rill",
                      "url": base.appendingPathComponent("jf").absoluteString,
                      "username": "fixture", "password": "fixture-password"]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ["-OpenStreamDevSources", file.path, "-OpenStreamResetOnLaunch", "YES",
                "-OpenStreamVisionScreen", "discover", "-OpenStreamMuteAudio", "YES",
                "-OpenStreamTrace", "YES", "-openstream.reset.cloudRestoreHeld.v1", "YES",
                "-openstream.settings.trailer.autoplay.v1", "NO", "-OpenStreamStubLiveBase", raw]
    }

    @discardableResult
    func startupControl(_ action: String) async throws -> [String: Bool] {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_STARTUP_FIXTURE_BASE"], !raw.isEmpty else {
            throw XCTSkip("Requires playback_startup_proof.py's local fixture")
        }
        let base = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(base.host, "127.0.0.1")
        var request = URLRequest(url: base.appendingPathComponent("startup/" + action))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Bool])
    }

    func waitForStartupRequest(_ key: String) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if try await startupControl("status")[key] == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The fixture never received \(key)")
    }

    func verifyStartupHandoff(_ app: XCUIApplication, route: String, press: @escaping @MainActor () -> Void) async throws {
        let play = app.buttons["detail.play"].firstMatch
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            play.isEnabled && play.label != "Preparing playback"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed)
        try await startupControl("reset-" + route)
        press()
        let indicator = app.activityIndicators["player.connecting"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "Play must acknowledge the press")
        let original = indicator.frame
        captureStartup(app, route: route, stage: "press", frame: original)
        try await waitForStartupRequest("resolving")
        captureStartup(app, route: route, stage: "resolving", frame: original)
        try await startupControl("release-resolution")
        try await waitForStartupRequest("engine")
        for sample in 0..<3 {
            captureStartup(app, route: route, stage: "engine-\(sample)", frame: original)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await startupControl("release-media")
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 45), "The generated fixture must show its first frame")
        XCTAssertFalse(indicator.exists, "Startup must finish at the displayed frame")
        captureStartup(app, route: route, stage: "first-frame", frame: nil)
    }

    func captureStartup(_ app: XCUIApplication, route: String, stage: String, frame: CGRect?) {
        let visible = app.activityIndicators.allElementsBoundByAccessibilityElement.filter {
            !$0.frame.isEmpty && app.frame.intersects($0.frame)
                && $0.descendants(matching: .activityIndicator).count == 0
        }
        XCTAssertEqual(visible.count, frame == nil ? 0 : 1, "\(route) \(stage): duplicate or missing indicator")
        if let frame, let current = visible.first?.frame {
            XCTAssertEqual(current.width, frame.width, accuracy: 1)
            XCTAssertEqual(current.height, frame.height, accuracy: 1)
            XCTAssertEqual(current.midX, frame.midX, accuracy: 1)
            XCTAssertEqual(current.midY, frame.midY, accuracy: 1)
            XCTAssertEqual(current.midX, app.frame.midX, accuracy: 1)
            XCTAssertEqual(current.midY, app.frame.midY, accuracy: 1)
            let geometry = XCTAttachment(string: "\(route) \(stage): \(current)")
            geometry.name = "startup-\(route)-\(stage)-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "startup-\(route)-\(stage)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
