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

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTopShelfShowsRealContentWhenTheAppIconIsFocused() {
        // 1. Run the app so the snapshot on disk is current rather than
        //    whatever the last session happened to leave behind.
        let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        app.launchArguments += ["-OpenStreamTrace", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60), "the app never came to the foreground")
        // The publisher runs off the catalog/media stores once they load.
        Thread.sleep(forTimeInterval: 25)
        attach("01-app-running")

        // 2. Home, then leftmost, then step right until OpenStream has focus.
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
        let wanted = ["Continue Watching", "Top Picks"] + expected
        let hit = wanted.filter { needle in
            texts.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        print("TOPSHELF matched: \(hit)")
        XCTAssertFalse(hit.isEmpty, "the Top Shelf showed none of \(wanted) — it is empty or stale")
        // Deliberately no `press(.home)` here: the run ends with the shelf on
        // screen so a `simctl io screenshot` from outside catches the same frame.
    }

    private func focusedLabel() -> String? {
        for host in [pineBoard, headBoard] {
            let focused = host.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { continue }
            let label = focused.label
            if !label.isEmpty { return label }
        }
        return nil
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
