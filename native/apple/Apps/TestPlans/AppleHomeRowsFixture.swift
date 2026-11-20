import XCTest

@MainActor
extension OpenStreamUITestCase {
    func launchHomeRowSettingsFixture(_ app: XCUIApplication, screen: String = "discover", charts: Bool = false,
                                     appearance: String? = nil) throws {
        guard let raw = ProcessInfo.processInfo.environment["OPENSTREAM_HOME_ROWS_BASE"],
              !raw.isEmpty, !raw.hasPrefix("$(") else {
            throw XCTSkip("Requires Tests/Fixtures/home_rows_proof.py's loopback fixture")
        }
        let base = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(base.host, "127.0.0.1")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("home-settings-\(UUID()).json")
        let source = ["kind": "mediaServer", "server": "jellyfin", "name": "Fixture Server", "url": raw + "/jf",
                      "username": "fixture", "password": "fixture-password"]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [source],
            "settings": ["tmdbAPIKey": "fixture"]]).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        app.launchArguments = Self.stubbedLaunchArguments + ["-OpenStreamDevSources", file.path,
            "-OpenStreamVisionScreen", screen, "-OpenStreamStubLiveBase", raw,
            "-openstream.settings.discover.top10Lists.v1", charts ? "YES" : "NO",
            "-openstream.reset.cloudRestoreHeld.v1", "YES", "-openstream.settings.trailer.autoplay.v1", "NO"]
        if screen == "settings" { app.launchArguments += ["-OpenStreamSettingsPane", "homeRows"] }
        if let appearance { app.launchArguments += ["-OpenStreamDebugColorScheme", appearance] }
        app.launch()
        if screen == "discover" {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.featured.details")
                .firstMatch.waitForExistence(timeout: 60))
        }
    }
}

#if os(iOS)
@MainActor
final class AppleHomeServicesFixtureUITests: OpenStreamUITestCase {
    func testServicePageInLightAppearance() throws {
        let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
        defer { app.terminate() }
        try launchHomeRowSettingsFixture(app, appearance: "light")
        let service = app.buttons["home.service.netflix"]
        for _ in 0..<20 {
            if service.exists && service.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(service.exists && service.isHittable)
        service.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.service.page.netflix")
            .firstMatch.waitForExistence(timeout: 20))
        let picker = app.segmentedControls["home.service.types"]
        XCTAssertTrue(picker.buttons["Movies"].isSelected)
        picker.buttons["Shows"].tap()
        XCTAssertTrue(picker.buttons["Shows"].isSelected)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.service.title."))
            .firstMatch.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "services-light-ios"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif

@MainActor
final class AppleHomeServicesOwnerUITests: OpenStreamUITestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.orgista.openstream")
    private let servicePrefix = "home.service."

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["OPENSTREAM_SERVICE_OWNER_CHECK"] == "1" else {
            throw XCTSkip("Requires the protected owner-content run.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 600
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testServiceRowPageAndReturnWithOwnerLibraries() throws {
        app.launchArguments = ["-OpenStreamVisionScreen", "discover", "-OpenStreamTrace", "YES",
            "-OpenStreamMuteAudio", "YES", "-openstream.settings.trailer.autoplay.v1", "NO",
            "-openstream.firstRunGuidanceSeen", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
            servicePrefix, "home.service.title."))
        #if os(tvOS)
        let remote = XCUIRemote.shared
        var serviceControls = [any XCUIElementSnapshot]()
        for _ in 0..<35 {
            serviceControls = try serviceSnapshots()
            if serviceControls.contains(where: \.hasFocus) { break }
            remote.press(.down)
            _ = buttons.firstMatch.waitForExistence(timeout: 3)
        }
        let first = try XCTUnwrap(serviceControls.first)
        if !first.hasFocus { capture("services-row-missing-tvos") }
        XCTAssertTrue(first.hasFocus, "First entry into Services must land on its first button")
        let netflix = app.buttons["home.service.netflix"]
        if netflix.exists {
            for _ in 0..<10 {
                let controls = try serviceSnapshots()
                guard let target = controls.firstIndex(where: { $0.identifier == netflix.identifier }),
                      let focused = controls.firstIndex(where: \.hasFocus), target != focused else { break }
                remote.press(focused < target ? .right : .left)
            }
        } else if buttons.count > 1 {
            remote.press(.right)
        }
        serviceControls = try serviceSnapshots()
        let selectedID = try XCTUnwrap(serviceControls.first(where: \.hasFocus)?.identifier)
        let selected = app.buttons[selectedID]
        let selectedName = selected.label
        capture("services-row-tvos")
        print("SERVICES row \(serviceControls.map { $0.identifier + "=" + $0.label }.joined(separator: " | "))")
        remote.press(.down)
        XCTAssertFalse(selected.hasFocus)
        remote.press(.up)
        XCTAssertTrue(waitForFocus(selected), "A row must remember focus when entered from another column")
        remote.press(.select)
        #else
        var selectedServiceID: String?
        for _ in 0..<40 {
            let controls = buttons.allElementsBoundByIndex
            if let visibleIndex = controls.firstIndex(where: isVisible) {
                let visible = controls[visibleIndex]
                if let targetIndex = controls.firstIndex(where: { $0.identifier == "home.service.netflix" }) {
                    let netflix = controls[targetIndex]
                    if isVisible(netflix) {
                        selectedServiceID = netflix.identifier
                        break
                    }
                    if targetIndex < visibleIndex { visible.swipeRight() }
                    else { visible.swipeLeft() }
                } else {
                    selectedServiceID = visible.identifier
                    break
                }
            } else {
                let row = app.descendants(matching: .any).matching(identifier: "home.row.services").firstMatch
                let frame = row.exists ? row.frame : .zero
                if !frame.isEmpty && frame.midY < app.frame.midY { app.swipeDown() }
                else { app.swipeUp() }
            }
            _ = buttons.firstMatch.waitForExistence(timeout: 3)
        }
        if selectedServiceID == nil { capture("services-row-missing-ios") }
        let selectedID = try XCTUnwrap(selectedServiceID, "No Services row from the signed-in server")
        let selected = app.buttons[selectedID]
        if !selected.exists || !isVisible(selected) { capture("services-row-missing-ios") }
        XCTAssertTrue(selected.exists && isVisible(selected), "No Services row from the signed-in server")
        capture("services-row-ios")
        print("SERVICES row \(buttons.allElementsBoundByIndex.map { $0.identifier + "=" + $0.label }.joined(separator: " | "))")
        app.buttons[selectedID].tap()
        #endif
        let serviceID = String(selectedID.dropFirst(servicePrefix.count))
        let firstPageCapacity = serviceID == "netflix" ? 80 : 40
        let page = app.descendants(matching: .any).matching(identifier: "home.service.page." + serviceID).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        #if os(tvOS)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", selectedName)).count, 1)
        #endif
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.service.title."))
        XCTAssertTrue(posters.firstMatch.waitForExistence(timeout: 30))
        let picker = app.descendants(matching: .any).matching(identifier: "home.service.types").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "The owner's selected service has both movie and show libraries")
        let firstPoster = posters.firstMatch.frame
        let firstLine = posters.allElementsBoundByIndex.filter { abs($0.frame.minY - firstPoster.minY) < 2 }
        #if os(tvOS)
        XCTAssertTrue(picker.hasFocus || picker.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus))
        remote.press(.down)
        XCTAssertTrue(posters.allElementsBoundByIndex.contains(where: \.hasFocus), "Down from the picker must enter the grid")
        capture("services-page-tvos")
        #else
        capture("services-page-ios")
        #endif
        #if os(tvOS)
        XCTAssertEqual(firstLine.count, 5)
        XCTAssertEqual(firstPoster.width, 300, accuracy: 1)
        XCTAssertEqual(firstPoster.height, 450, accuracy: 1)
        let initialIDs = Set(try buttonSnapshots(prefix: "home.service.title.").map(\.identifier))
        var seenIDs = initialIDs
        var pagedIDs = Set<String>()
        for _ in 0..<40 {
            remote.press(.down)
            let currentPosters = try buttonSnapshots(prefix: "home.service.title.")
            for poster in currentPosters where seenIDs.insert(poster.identifier).inserted {
                if seenIDs.count > firstPageCapacity { pagedIDs.insert(poster.identifier) }
            }
            if currentPosters.contains(where: { $0.hasFocus && pagedIDs.contains($0.identifier) }) { break }
        }
        print("SERVICES unique titles=\(seenIDs.count)")
        XCTAssertGreaterThan(seenIDs.count, firstPageCapacity, "The walk must exceed the combined first pages of the service libraries")
        let pagedPoster = try XCTUnwrap(try buttonSnapshots(prefix: "home.service.title.").first(where: \.hasFocus))
        XCTAssertTrue(pagedIDs.contains(pagedPoster.identifier), "Focus must reach a title first observed beyond the combined first pages")
        let pagedID = pagedPoster.identifier
        let pagedFrame = try settledFrame(app.buttons[pagedID])
        print("SERVICES paging sentinel=\(pagedID) frame=\(pagedFrame)")
        capture("services-paged-tvos")
        remote.press(.home)
        returnFromBackground()
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        let reloadedPoster = app.buttons[pagedID]
        XCTAssertTrue(waitForFocus(reloadedPoster), "Foreground reload must keep the paged poster focused")
        let reloadedFrame = try settledFrame(reloadedPoster)
        print("SERVICES reloaded sentinel=\(pagedID) frame=\(reloadedFrame)")
        capture("services-reloaded-tvos")
        XCTAssertTrue(app.frame.contains(reloadedFrame), "Foreground reload must keep the focused paged poster fully visible")
        remote.press(.menu)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !page.exists }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(waitForFocus(app.buttons[selectedID]), "Menu must return to the same service button")
        capture("services-return-tvos")
        #else
        XCTAssertEqual(firstLine.count, 3)
        let shows = app.segmentedControls["home.service.types"].buttons["Shows"]
        XCTAssertTrue(shows.exists)
        shows.tap()
        let selectionChanged = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            shows.exists && shows.isSelected
        }, object: nil)], timeout: 15) == .completed
        if !selectionChanged { capture("services-shows-missing-ios") }
        XCTAssertTrue(selectionChanged, "Shows must become selected")
        XCTAssertTrue(posters.firstMatch.waitForExistence(timeout: 20))
        capture("services-shows-ios")
        let initialIDs = Set(posters.allElementsBoundByIndex.map(\.identifier))
        var seenIDs = initialIDs
        var pagedIDs = Set<String>()
        for _ in 0..<40 {
            app.swipeUp()
            pagedIDs.formUnion(recordPagedIDs(posters, seen: &seenIDs, firstPageCapacity: firstPageCapacity))
            if posters.allElementsBoundByIndex.contains(where: { pagedIDs.contains($0.identifier) && isVisible($0) }) { break }
        }
        print("SERVICES unique titles=\(seenIDs.count)")
        XCTAssertGreaterThan(seenIDs.count, firstPageCapacity, "The walk must exceed the combined first pages of the service libraries")
        let pagedPoster = try XCTUnwrap(posters.allElementsBoundByIndex.last(where: { pagedIDs.contains($0.identifier) && isVisible($0) }))
        let pagedID = pagedPoster.identifier
        let pagedFrame = pagedPoster.frame
        capture("services-paged-ios")
        XCUIDevice.shared.press(.home)
        returnFromBackground()
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        let reloadedPoster = app.buttons[pagedID]
        XCTAssertTrue(reloadedPoster.waitForExistence(timeout: 30))
        XCTAssertTrue(reloadedPoster.isHittable, "Foreground reload must keep the paged poster visible")
        XCTAssertEqual(reloadedPoster.frame.minY, pagedFrame.minY, accuracy: 2)
        capture("services-reloaded-ios")
        print("SERVICES paging sentinel=\(pagedID) frame=\(reloadedPoster.frame)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons[selectedID].waitForExistence(timeout: 15))
        capture("services-return-ios")
        #endif
        print("SERVICES page \(serviceID) firstLine=\(firstLine.count) poster=\(firstPoster)")
    }

    private func isVisible(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        return !frame.isEmpty && app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) && element.isHittable
    }

    private func recordPagedIDs(_ posters: XCUIElementQuery, seen: inout Set<String>, firstPageCapacity: Int) -> Set<String> {
        var paged = Set<String>()
        for poster in posters.allElementsBoundByIndex where seen.insert(poster.identifier).inserted {
            if seen.count > firstPageCapacity { paged.insert(poster.identifier) }
        }
        return paged
    }

    private func returnFromBackground() {
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 15), .completed)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
    }

    #if os(tvOS)
    private func settledFrame(_ element: XCUIElement) throws -> CGRect {
        let clock = ContinuousClock()
        var candidate: CGRect?
        var stableSince = clock.now
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists && element.hasFocus else {
                candidate = nil
                return false
            }
            let current = element.frame
            if let candidate, !current.isEmpty,
               abs(current.minX - candidate.minX) < 0.5,
               abs(current.minY - candidate.minY) < 0.5,
               abs(current.width - candidate.width) < 0.5,
               abs(current.height - candidate.height) < 0.5 {
                return stableSince.duration(to: clock.now) >= .seconds(2)
            }
            candidate = current
            stableSince = clock.now
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed,
            "The focused poster must settle before measuring its position")
        return try XCTUnwrap(candidate)
    }

    private func serviceSnapshots() throws -> [any XCUIElementSnapshot] {
        try buttonSnapshots(prefix: servicePrefix).filter { !$0.identifier.hasPrefix("home.service.title.") }
    }

    private func buttonSnapshots(prefix: String) throws -> [any XCUIElementSnapshot] {
        var pending = [try app.snapshot()]
        var buttons = [any XCUIElementSnapshot]()
        while let element = pending.popLast() {
            if element.elementType == .button && element.identifier.hasPrefix(prefix) {
                buttons.append(element)
            }
            pending.append(contentsOf: element.children.reversed())
        }
        return buttons
    }

    private func waitForFocus(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.hasFocus }, object: nil)], timeout: 10) == .completed
    }
    #endif

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
