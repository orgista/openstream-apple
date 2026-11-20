import XCTest

/// Apple TV Top Shelf, verified on the simulator with no hardware remote.
///
/// A previous pre-ship pass reported the shelf "unverifiable without a
/// physical remote". `XCUIRemote` sends the same HID events the Siri Remote
/// does, so the home screen is drivable from here: launch the app once so
/// `AppleTopShelfPublisher` writes `topshelf-v1.json` into the app group,
/// press Home, walk focus onto the OpenStream icon, and look at what the
/// shelf renders.
@MainActor
final class AppleTVTopShelfUITests: OpenStreamUITestCase {
    private var remote: XCUIRemote { .shared }
    /// tvOS renders the home screen and the Top Shelf in PineBoard; HeadBoard
    /// is the surrounding springboard. Both are queried — whichever exposes
    /// the shelf wins, and the other is only dumped for diagnosis.
    private let pineBoard = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
    private let headBoard = XCUIApplication(bundleIdentifier: "com.apple.HeadBoard")

    /// Discover → Stub Movie Five (first in the server's Latest row) → Play,
    /// fifteen seconds of it, then back to Discover.
    private func watchPartOfAFixtureTitle(in app: XCUIApplication) {
        func focus(_ predicate: NSPredicate, pressing direction: XCUIRemote.Button) -> Bool {
            let target = app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "hasFocus == true"), predicate])).firstMatch
            for _ in 0 ..< 12 where !target.exists {
                remote.press(direction)
                _ = target.waitForExistence(timeout: 1.5)
            }
            return target.exists
        }
        XCTAssertTrue(focus(Self.serverShelfItem("jf-movie-5"), pressing: .down), "the fixture title never took focus")
        remote.press(.select)
        XCTAssertTrue(focus(NSPredicate(format: "identifier == 'detail.play'"), pressing: .right), "Play never took focus")
        remote.press(.select)
        let ready = app.descendants(matching: .any)["player.playback.ready"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 60), "the fixture title never played")
        Thread.sleep(forTimeInterval: 15)
        remote.press(.menu)
        Thread.sleep(forTimeInterval: 2)
        remote.press(.menu)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTopShelfShowsRealContentWhenTheAppIconIsFocused() {
        // 1. Run the app so the snapshot on disk is current rather than
        //    whatever the last session happened to leave behind.
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app never came to the foreground")
        // The shelf lists what was watched here. On the fixtures, watch part of
        // a title from the fixture Jellyfin first (`Tests/Fixtures/serve.py`).
        if ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false {
            watchPartOfAFixtureTitle(in: app)
        }
        Thread.sleep(forTimeInterval: 25)
        attach("01-app-running")

        // 2. Home, then leftmost, then step right until OpenStream has focus.
        // A device whose TV button opens the Apple TV app (test Apple TV) lands there
        // first; a second press goes on to the home screen, which ignores it.
        remote.press(.home)
        Thread.sleep(forTimeInterval: 4)
        remote.press(.home)
        Thread.sleep(forTimeInterval: 4)
        attach("02-home-screen")
        for _ in 0..<8 { remote.press(.left); Thread.sleep(forTimeInterval: 0.4) }
        remote.press(.up)
        Thread.sleep(forTimeInterval: 2)

        var focusedOnOpenStream = false
        for step in 0..<8 {
            let focused = focusedLabel()
            print("TOPSHELF focus step \(step): \(focused ?? "<none>")")
            if focused?.localizedCaseInsensitiveContains("oStream") == true,
               focused?.localizedCaseInsensitiveContains("UITests") != true {
                focusedOnOpenStream = true
                break
            }
            remote.press(.right)
            Thread.sleep(forTimeInterval: 1.5)
        }
        // Give the extension time to be launched and to hand back content.
        Thread.sleep(forTimeInterval: 8)
        attach("03-top-shelf")
        print("TOPSHELF focused element: \(focusedLabel() ?? "<none>")")

        // 3. What the shelf actually put on screen.
        let texts = homeScreenTexts()
        print("TOPSHELF visible strings (\(texts.count)): \(texts.joined(separator: " | "))")
        print("TOPSHELF PineBoard tree:\n\(pineBoard.debugDescription)")

        XCTAssertTrue(focusedOnOpenStream, "never managed to focus the oStream icon on the home screen")
        let expected = ProcessInfo.processInfo.environment["OPENSTREAM_TOPSHELF_EXPECT"]?
            .split(separator: "\u{1f}").map(String.init) ?? []
        // The full-screen carousel (owner 2026-10-15): PineBoard exposes the
        // pages' titles and its own swipe-up affordance, not the context titles.
        let isCarousel = texts.contains("top-shelf/swipe-up-affordance/label")
        // The stubbed title exists only on the simulator's fixtures; a device
        // runs its own sources.
        let stubbed = ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false
        let wanted = (stubbed ? ["Stub Movie"] : []) + expected
        let hit = wanted.filter { needle in
            texts.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        print("TOPSHELF carousel: \(isCarousel) matched: \(hit)")
        XCTAssertTrue(isCarousel, "the Top Shelf is not the full-screen carousel")
        XCTAssertTrue(wanted.isEmpty || !hit.isEmpty, "the Top Shelf showed none of \(wanted) — it is empty or stale")

        // 4. Swipe up: the carousel takes the whole screen, and Right moves
        //    to the next page (owner 2026-10-16: "swipe for full screen not working").
        remote.press(.up)
        let fullScreen = waitForHomeScreen {
            // An empty read is a failed snapshot, not a full-screen shelf.
            !$0.isEmpty && !$0.contains("top-shelf/swipe-up-affordance/label")
        }
        attach("04-full-screen")
        print("TOPSHELF full-screen strings (\(fullScreen.count)): \(fullScreen.joined(separator: " | "))")
        XCTAssertFalse(fullScreen.isEmpty || fullScreen.contains("top-shelf/swipe-up-affordance/label"),
                       "Up did not take the shelf full screen")
        remote.press(.right)
        let nextPage = waitForHomeScreen { $0.contains { $0.hasPrefix("page ") } }
        attach("05-next-page")
        print("TOPSHELF next-page strings: \(nextPage.joined(separator: " | "))")
        XCTAssertTrue(nextPage.contains { $0.hasPrefix("page ") }, "Right did not page the full-screen carousel")
        // Deliberately no `press(.home)` here: the run ends with the shelf on
        // screen so a `simctl io screenshot` from outside catches the same frame.
    }

    // MARK: - Reserved characters in a share path

    /// An episode whose folder and file name carry `&` and `'`
    /// (`OPENSTREAM_RESERVED_SMB`, a dev-sources entry for a share holding
    /// "Show & Co's Name/Season 1/Show & Co's Name - S01E01 - A Title.mkv")
    /// plays through the SMB bridge and is a series episode in Now Playing.
    func testShareEpisodeWithReservedCharactersPlaysUnderItsSeries() throws {
        let episode = try shareFilm(source: "OPENSTREAM_RESERVED_SMB", title: "Show & Co's Name")
        let mark = openStreamTraceMark()
        let app = playShareFilmFromTheStart(episode, seconds: 6)
        attach("reserved-name-playing")
        let lines = mark.lines(of: attachTrace("reserved-name"))
        XCTAssertTrue(lines.contains { $0.contains("networkShare") && $0.contains("A Title.mkv") && $0.contains(" attempt ") })
        XCTAssertTrue(lines.contains { $0.contains("first frame") }, "no first frame")
        XCTAssertTrue(lines.contains { $0.contains("now playing title=\"S1, E1 · A Title\" series=true") },
                      "Now Playing is not the episode under its series")
        XCTAssertFalse(lines.contains { $0.contains("not on the share") || $0.contains("failure playback") })
        closePlayer(app)
    }

    // MARK: - Resume from the Home screen

    /// A film on a throwaway SMB share (`OPENSTREAM_RESUME_SMB`, a dev-sources
    /// entry) as the Library lists it, `OPENSTREAM_RESUME_TITLE` or Verity.
    private struct ShareFilm {
        let title: String
        let base = ["-OpenStreamTrace", "YES", "-OpenStreamMuteAudio", "YES",
                    "-openstream.firstRunGuidanceSeen", "YES", "-openstream.settings.metadata.enabled.v1", "NO"]
        let sourcesFile: URL
    }

    private func shareFilm(source key: String = "OPENSTREAM_RESUME_SMB", title: String? = nil) throws -> ShareFilm {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment[key],
              let source = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw XCTSkip("Requires \(key)") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("resume-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return ShareFilm(title: title ?? environment["OPENSTREAM_RESUME_TITLE"] ?? "Verity", sourcesFile: file)
    }

    /// Fresh app with only the share, its film played from the title page for
    /// `seconds`; the player is still up.
    private func playShareFilmFromTheStart(_ film: ShareFilm, seconds: TimeInterval) -> XCUIApplication {
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = film.base + ["-OpenStreamDevSources", film.sourcesFile.path, "-OpenStreamResetOnLaunch", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        Thread.sleep(forTimeInterval: 8)
        remote.press(.right)
        // The Library's poster, wherever it sits in the row: Down reaches the
        // row, then Left or Right its column.
        let named = NSPredicate(format: "identifier == %@", "library.title.\(film.title)")
        XCTAssertTrue(app.descendants(matching: .any).matching(named).firstMatch.waitForExistence(timeout: 90),
                      "the share's film never reached the Library")
        guard focus(named, in: app, pressing: .down) || focus(named, in: app, pressing: .left)
                || focus(named, in: app, pressing: .right) else {
            XCTFail("the film never took focus")
            return app
        }
        remote.press(.select)
        XCTAssertTrue(focus(NSPredicate(format: "identifier == 'detail.play'"), in: app, pressing: .right))
        remote.press(.select)
        XCTAssertTrue(playerReady(app).waitForExistence(timeout: 60), "the film never played")
        Thread.sleep(forTimeInterval: seconds)
        return app
    }

    private func playerReady(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["player.playback.ready"].firstMatch
    }

    /// Menu out of the player, so the next play can only come from what the
    /// step does.
    private func closePlayer(_ app: XCUIApplication) {
        // The first Menu can land on visible controls and only hide them.
        for _ in 0 ..< 2 where playerReady(app).exists {
            remote.press(.menu)
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: playerReady(app))
            _ = XCTWaiter().wait(for: [gone], timeout: 6)
        }
        guard playerReady(app).exists else { return }
        attachTrace("player-did-not-close")
        attach("player-did-not-close")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "player-did-not-close-tree"; tree.lifetime = .keepAlways; add(tree)
        XCTFail("the player did not close")
    }

    @discardableResult
    private func attachTrace(_ name: String) -> [String] {
        let trace = (try? currentOpenStreamTrace()) ?? []
        let log = XCTAttachment(string: trace.joined(separator: "\n"))
        log.name = "\(name)-trace"; log.lifetime = .keepAlways; add(log)
        return trace
    }

    /// Play on the shelf, the title page's Resume, and Play from cold: each
    /// continues from the saved position. The shelf item's play action is its
    /// URL (`TopShelfProvider`); without metadata the film has no art and the
    /// shelf draws no art-less tile, so the URL is sent directly.
    func testShareFilmResumesFromTheTopShelfAndTheTitlePage() throws {
        let film = try shareFilm()
        let app = playShareFilmFromTheStart(film, seconds: 25)
        closePlayer(app)
        // Home: the app is suspended, not quit, and publishes the shelf.
        remote.press(.home)
        let link = try XCTUnwrap(shelfPlayLink(film.title), "the film is not on the shelf's Continue Watching")
        var mark = openStreamTraceMark()
        XCUIDevice.shared.system.open(link)
        assertResumed(app, film, step: "shelf-warm", after: mark, viaLink: true)

        // The same link again, with the page the first one opened still up.
        closePlayer(app)
        remote.press(.home)
        Thread.sleep(forTimeInterval: 3)
        mark = openStreamTraceMark()
        XCUIDevice.shared.system.open(link)
        assertResumed(app, film, step: "shelf-again", after: mark, viaLink: true)

        // Cold: the link launches the app. The share is saved by now, so the
        // launch carries only the trace and mute switches.
        closePlayer(app)
        app.terminate()
        app.launchArguments = film.base
        mark = openStreamTraceMark()
        app.open(link)
        assertResumed(app, film, step: "shelf-cold", after: mark, viaLink: true, cold: true)

        closePlayer(app)
        app.terminate()
        app.launch()
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.continue.'"), in: app, pressing: .down),
                      "Continue Watching never took focus")
        remote.press(.select)
        let resume = NSPredicate(format: "identifier == 'detail.play' AND label BEGINSWITH 'Resume'")
        XCTAssertTrue(focus(resume, in: app, pressing: .right), "the title page does not offer Resume")
        mark = openStreamTraceMark()
        remote.press(.select)
        assertResumed(app, film, step: "title-page", after: mark, viaLink: false)
    }

    /// Other ways back to a film: the app killed mid-playback, the shelf after
    /// the app sat suspended for more than ten minutes, and the shelf after the
    /// share stopped answering for a while (`OPENSTREAM_RESUME_SMBD_PID`: the fixture server, paused with
    /// SIGSTOP as a NAS that went to sleep).
    func testShareFilmResumesAfterAKillASuspensionAndAnOutage() throws {
        let film = try shareFilm()
        let suspended = Double(ProcessInfo.processInfo.environment["OPENSTREAM_RESUME_SUSPEND_SECONDS"] ?? "") ?? 660
        // The suspension alone outlasts the test plan's 10-minute allowance.
        executionTimeAllowance = suspended + 600
        let app = playShareFilmFromTheStart(film, seconds: 40)
        // Killed with the player up: only the periodic saves remain.
        app.terminate()
        app.launchArguments = film.base
        app.launch()
        XCTAssertTrue(focus(NSPredicate(format: "identifier BEGINSWITH 'home.continue.'"), in: app, pressing: .down),
                      "Continue Watching never took focus after the kill")
        remote.press(.select)
        let resume = NSPredicate(format: "identifier == 'detail.play' AND label BEGINSWITH 'Resume'")
        XCTAssertTrue(focus(resume, in: app, pressing: .right), "no Resume after the kill")
        var mark = openStreamTraceMark()
        remote.press(.select)
        assertResumed(app, film, step: "after-kill", after: mark, viaLink: false)

        closePlayer(app)
        remote.press(.home)
        let link = try XCTUnwrap(shelfPlayLink(film.title), "the film is not on the shelf's Continue Watching")
        Thread.sleep(forTimeInterval: suspended)
        mark = openStreamTraceMark()
        XCUIDevice.shared.system.open(link)
        assertResumed(app, film, step: "after-suspension", after: mark, viaLink: true)

        guard let pid = ProcessInfo.processInfo.environment["OPENSTREAM_RESUME_SMBD_PID"].flatMap(Int32.init) else {
            throw XCTSkip("Requires OPENSTREAM_RESUME_SMBD_PID for the outage step")
        }
        closePlayer(app)
        remote.press(.home)
        XCTAssertEqual(kill(pid, SIGSTOP), 0, "could not pause the share's server")
        Thread.sleep(forTimeInterval: 45)
        XCTAssertEqual(kill(pid, SIGCONT), 0, "could not resume the share's server")
        mark = openStreamTraceMark()
        XCUIDevice.shared.system.open(link)
        assertResumed(app, film, step: "after-outage", after: mark, viaLink: true)
    }

    /// A media-server film's shelf link, warm and cold: the fixture
    /// Jellyfin's Stub Movie Five from the shelf's Top Picks row. Its
    /// clip runs 15 s, under the 30 s that counts as finished
    /// (`AppleCompletionPolicy`), so this fixture can play but never resume.
    func testServerFilmPlaysFromItsShelfLink() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_STUB_DIR"]?.isEmpty == false else {
            throw XCTSkip("Requires the fixture server")
        }
        let app = OpenStreamTestApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments = Self.stubbedLaunchArguments
        configureFixtureLaunch(app)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
        remote.press(.home)
        let link = try XCTUnwrap(shelfPlayLink("Stub Movie Five", in: "topPicks"), "the server film is not on the shelf")
        let ready = playerReady(app)
        for step in ["server-warm", "server-cold"] {
            let cold = step == "server-cold"
            let mark: OpenStreamTraceMark
            if cold {
                // The link launches the app, with the fixture switches but no reset.
                app.terminate()
                var arguments = Self.stubbedLaunchArguments
                if let reset = arguments.firstIndex(of: "-OpenStreamResetOnLaunch") { arguments.removeSubrange(reset ... reset + 1) }
                app.launchArguments = arguments
                configureFixtureLaunch(app)
                mark = openStreamTraceMark()
                app.open(link)
            } else {
                mark = openStreamTraceMark()
                XCUIDevice.shared.system.open(link)
            }
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30) && ready.waitForExistence(timeout: 60),
                          "\(step): the film did not play")
            attach(step)
            let trace = attachTrace(step)
            assertLaunch(trace, after: mark, step: step, cold: cold, switch: "OpenStreamStubNetwork")
            XCTAssertTrue(mark.lines(of: trace).contains { $0.contains("detail route \"Stub Movie Five\" action=play") },
                          "\(step): the link did not route to the film")
            XCTAssertFalse(app.alerts["Playback Unavailable"].exists, "\(step): Playback Unavailable")
            closePlayer(app)
            remote.press(.home)
        }
    }

    /// `title`'s play URL in the shelf's `list`, once the app has published it.
    private func shelfPlayLink(_ title: String, in list: String = "continueWatching") -> URL? {
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 2)
            let items = (try? openStreamShelfSnapshot()[list]) as? [[String: Any]] ?? []
            if let link = (items.first { ($0["title"] as? String)?.hasPrefix(title) == true }?["playURL"] as? String)
                .flatMap(URL.init) {
                return link
            }
        }
        return nil
    }

    private func focus(_ predicate: NSPredicate, in app: XCUIApplication, pressing direction: XCUIRemote.Button) -> Bool {
        let target = app.descendants(matching: .any).matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "hasFocus == true"), predicate])).firstMatch
        for _ in 0 ..< 14 where !target.exists {
            remote.press(direction)
            _ = target.waitForExistence(timeout: 1.5)
        }
        return target.exists
    }

    /// The step played the film again from past where it was, with no
    /// "Playback Unavailable"; a link step must have gone through the
    /// deep-link route (`detail route "<title>…" action=play`).
    private func assertResumed(_ app: XCUIApplication, _ film: ShareFilm, step: String, after mark: OpenStreamTraceMark,
                               viaLink: Bool, cold: Bool = false) {
        let opened = app.wait(for: .runningForeground, timeout: 30)
        let played = playerReady(app).waitForExistence(timeout: 90)
        Thread.sleep(forTimeInterval: 2)
        attach("resume-\(step)")
        let trace = attachTrace("resume-\(step)")
        assertLaunch(trace, after: mark, step: step, cold: cold, switch: "OpenStreamMuteAudio")
        XCTAssertTrue(opened && played, "\(step): the film did not play")
        XCTAssertFalse(app.alerts["Playback Unavailable"].exists, "\(step): Playback Unavailable")
        let start = openStreamPlayStart(of: film.title, in: trace, after: mark, viaLink: viaLink)
        XCTAssertGreaterThan(start ?? -1, 15, "\(step): \(start == nil ? "no play for this step" : "played from the start")")
    }

    /// A cold step's trace is a new launch that got the test's arguments
    /// (`launch arguments: …` lists them, `switch` among them); any other
    /// step stays in the session the mark was taken in.
    private func assertLaunch(_ trace: [String], after mark: OpenStreamTraceMark, step: String, cold: Bool,
                              switch name: String) {
        guard cold else {
            XCTAssertFalse(mark.isNewSession(trace), "\(step): the app was relaunched")
            return
        }
        XCTAssertTrue(mark.isNewSession(trace), "\(step): the link did not launch the app")
        XCTAssertTrue(trace.contains { $0.contains("launch arguments:") && $0.contains(name) },
                      "\(step): the link's launch did not get the test's arguments")
    }

    /// From a snapshot: a query on a host with no accessibility server
    /// (hardware) fails the test, a snapshot only throws.
    private func focusedLabel() -> String? {
        for host in [pineBoard, headBoard] {
            guard let snapshot = try? host.snapshot() else { continue }
            var stack = [snapshot]
            while let node = stack.popLast() {
                if node.hasFocus, !node.label.isEmpty { return node.label }
                stack.append(contentsOf: node.children)
            }
        }
        return nil
    }

    /// The home screen's strings once `matches` holds, or the last ones read
    /// when `timeout` runs out (the caller's assertion then fails on them).
    private func waitForHomeScreen(_ matches: ([String]) -> Bool, timeout: TimeInterval = 8) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var texts = homeScreenTexts()
        while !matches(texts), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            texts = homeScreenTexts()
        }
        return texts
    }

    /// One snapshot of the whole tree per host. Walking `allElementsBoundByIndex`
    /// re-queries per element and the home screen mutates under it — the first
    /// run of this test died on "Failed to get matching snapshot", not on
    /// anything the shelf did.
    private func homeScreenTexts() -> [String] {
        var out: [String] = []
        for host in [pineBoard, headBoard] {
            guard let snapshot = try? host.snapshot() else { continue }
            var stack = [snapshot]
            while let node = stack.popLast() {
                if !node.label.isEmpty { out.append(node.label) }
                if !node.identifier.isEmpty { out.append(node.identifier) }
                if let value = node.value as? String, !value.isEmpty { out.append(value) }
                stack.append(contentsOf: node.children)
            }
        }
        return Array(Set(out)).sorted()
    }
}
