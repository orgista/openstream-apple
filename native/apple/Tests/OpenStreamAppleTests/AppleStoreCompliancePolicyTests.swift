import Foundation
import Testing
@testable import OpenStreamApple

/// Owner decisions of 2026-10-01 from the App Store compliance audit (B4–B6):
/// no service brands on Discover rows, Top 10 lists off by default, and no
/// channel lineup in the shipped app.
@Suite("App Store compliance policy")
struct AppleStoreCompliancePolicyTests {
    private struct NoCredentials: AppleCredentialStoring {
        func string(for account: String) throws -> String? { nil }
        func set(_ value: String, for account: String) throws {}
        func remove(_ account: String) throws {}
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "openstream.tests.compliance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }


    @Test("App UI names oStream; OpenStream is reserved for credits and identifiers")
    func visibleAppNameIsOStream() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources/OpenStreamApple")
        let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        // Disk paths, wire identifiers and log output retain compatibility.
        let compatibilityLiterals: Set<String> = [
            "OpenStream", "OpenStream/BackgroundDownloads", "OpenStream Diagnostics.txt",
            "OpenStream/1.0 Apple",
            "OpenStream/", "OpenStream/ (+https://orgista.com/support)",
            "OpenStream/Offline", "OpenStream/Metadata", "OpenStream/LiveChannels",
            "OpenStream/Playlists", "OpenStream/ChannelHealth",
        ]
        let credits: Set<String> = [
            "Playback engine, release 6.66.0, linked as dynamic frameworks. OpenStream's fork with its changes: ",
        ]
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in walker where file.pathExtension == "swift" {
            scanned += 1
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("*"),
                      !code.hasPrefix("print("), !code.hasPrefix("appleTrace(") else { continue }
                for literal in AppleUserFacingBrandingTests.stringLiterals(in: line)
                    where literal.range(of: #"\bOpenStream\b"#, options: .regularExpression) != nil {
                    if credits.contains(literal) { continue }
                    if compatibilityLiterals.contains(literal),
                       code.contains("appending") || code.contains("fileName") || code.contains("User-Agent")
                        || code.contains("userAgent:") || code.contains("X-Application")
                        || file.lastPathComponent == "AppleWikidataStreamingIDs.swift" { continue }
                    if ["X-OpenStream-Session", "X-OpenStream-Client"].contains(literal), code.contains("forHTTPHeaderField") { continue }
                    if file.lastPathComponent == "AppleDiagnosticsReport.swift", literal == "OpenStream  ()" { continue }
                    if literal.hasPrefix("[OpenStream]") || literal.hasPrefix("OpenStream diagnostics [") { continue }
                    offenders.append("\(file.lastPathComponent):\(number + 1): \(literal)")
                }
                // HTML within multiline Swift strings is also user-visible UI.
                if file.lastPathComponent == "AppleWebManagementPage.swift",
                   !code.hasPrefix("//"), code.range(of: #">OpenStream<|aria-label=\\?"OpenStream"#, options: .regularExpression) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1): HTML app name")
                }
            }
        }
        #expect(scanned > 100)
        #expect(offenders.isEmpty, "Old app name: \(offenders.joined(separator: "; "))")
    }

    // MARK: B5 — Top 10 lists off by default

    @MainActor
    @Test("Top 10 lists are off until the viewer turns them on")
    func top10ListsDefaultOff() {
        let defaults = freshDefaults()
        let store = AppleSettingsStore(defaults: defaults, keychain: NoCredentials())
        #expect(store.top10ListsEnabled == false)
        store.top10ListsEnabled = true
        #expect(AppleSettingsStore(defaults: defaults, keychain: NoCredentials()).top10ListsEnabled == true)
    }

    @Test("No channel lineup ships in the resource bundle")
    func resourceBundleContainsNoChannelLineup() throws {
        let products = Bundle(for: AppleSettingsStore.self).bundleURL.deletingLastPathComponent()
        let bundles = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
        let root = try #require(bundles.first { $0.lastPathComponent == "OpenStreamApple_OpenStreamApple.bundle" })
        let paths = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in paths {
            #expect(url.lastPathComponent != "ChannelLineup")
            #expect(url.lastPathComponent != "complete-us.json")
            #expect(url.pathExtension != "oslineup")
        }
    }

    @Test("A missing lineup falls back to the viewer's playlist")
    func unavailableLineupFallsBackToPlaylist() throws {
        // Without a lineup, the Complete Guide groups nothing by number and the
        // snapshot shows every playlist channel, named and logo'd by the playlist.
        let channels = [
            AppleIPTVChannel(id: "1", sourceID: UUID(), name: "ESPN", group: "Sports",
                             logoURL: URL(string: "http://x/espn.png"), streamURL: URL(string: "http://x/1")!),
            AppleIPTVChannel(id: "2", sourceID: UUID(), name: "Local News 7", group: "News",
                             streamURL: URL(string: "http://x/2")!),
        ]
        let groups = AppleChannelProjection.completeGuideGroups(from: channels, entries: [])
        #expect(groups.map(\.name) == ["News", "Sports"])
        #expect(Set(groups.flatMap(\.channels).map(\.id)) == ["1", "2"])
        let snapshot = AppleLiveChannelSnapshot.build(groups: groups, package: .completeGuide, custom: .init(),
                                                      entries: [], favoriteIDs: [], category: "All")
        #expect(snapshot.channels.map(\.id) == ["2", "1"])
        #expect(snapshot.channels.first(where: { $0.id == "1" })?.logoURL == URL(string: "http://x/espn.png"))
        // The playlist's own groups still give the chips (Apple TV pass 2026-10-02).
        #expect(snapshot.categories == ["All", "Favorites", "News", "Sports"])
    }

    @Test("Package picker titles are the same in every build")
    func packageChoicesFollowTheLineup() throws {
        #expect(AppleLiveChannelPackage.available(entries: []).map(\.title) == ["Everything", "Custom"])
        #expect(AppleLiveChannelPackage.available(entries: try fixtureLineup().channels).map(\.title) == ["Complete Guide", "Everything", "Custom"])
        #expect(AppleLiveChannelPackage.defaultPackage(for: []) == .everything)
    }
}
