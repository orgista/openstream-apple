// AppleChannelLineupPresetsTests.swift
// OpenStreamAppleTests
// Done / hooks needed: none
import Testing
import Foundation
@testable import OpenStreamApple

struct AppleChannelLineupPresetsTests {

    @Test("Tests JSON Loading and preset logic")
    func testCompleteUS() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        #expect(entries.count >= 300)
    }

    @Test("Tests Exact name match")
    func testMatchExactName() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let match = AppleChannelLineupPresets.match(channelName: "ESPN", in: entries)
        #expect(match?.number == 206)
    }

    @Test("Tests alias match")
    func testMatchAlias() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let match = AppleChannelLineupPresets.match(channelName: "ESPN HD", in: entries)
        #expect(match?.number == 206)
    }

    @Test("Tests normalization US prefix")
    func testMatchUSPrefix() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let match = AppleChannelLineupPresets.match(channelName: "US: CNN", in: entries)
        #expect(match?.number == 202)
    }

    @Test("Tests normalization suffix")
    func testMatchEastSuffix() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let match = AppleChannelLineupPresets.match(channelName: "HBO East", in: entries)
        #expect(match?.number == 501)
    }
    
    @Test("Tests normalization of punctuation")
    func testMatchPunctuation() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        // 205 is Sports Mix in the real guide; Fox News Channel is 360.
        let match = AppleChannelLineupPresets.match(channelName: "Fox-News!", in: entries)
        #expect(match?.number == 360)
    }

    @Test("Tests local matching")
    func testLocalMatches() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let chicagoMatches = AppleChannelLineupPresets.localMatches(zip: "60614", entries: entries)
        // Should include locals (which apply to all markets according to our simple model, or specifically Chicago)
        // AND the RSNs for Chicago
        let rsn = chicagoMatches.first { $0.number == 665 }
        #expect(rsn?.name == "NBC Sports Chicago")
        
        // Should not include Dallas RSN
        let dallasRSN = chicagoMatches.first { $0.number == 602 }
        #expect(dallasRSN == nil)
    }

    @Test("Unknown name returns nil")
    func testUnknownName() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        let match = AppleChannelLineupPresets.match(channelName: "Some Random Unknown Channel", in: entries)
        #expect(match == nil)
    }
    @Test func legacyPackageDecodesAsCompleteGuide() throws {
        let package = try JSONDecoder().decode(AppleLiveChannelPackage.self, from: Data("\"premierGuide\"".utf8))
        #expect(package == .completeGuide)
        #expect(package.title == "Complete Guide")
        #expect(try JSONEncoder().encode(package) == Data("\"completeGuide\"".utf8))
    }

    @Test(arguments: [0, 1, 7, 8, 9, 19, 20, 21])
    func automaticPackageUsesTheSnapshotConfidenceThreshold(count: Int) throws {
        let entries = Array(try AppleChannelLineupPresets.completeUS().prefix(count))
        let channels = entries.map {
            AppleIPTVChannel(id: String($0.number), sourceID: UUID(), name: $0.name, group: "All",
                             streamURL: URL(string: "https://fixture.example/channel.ts")!)
        }
        #expect(AppleLiveChannelPackage.defaultPackage(for: channels) ==
                (count >= AppleLiveChannelSnapshot.minimumLineupMatches ? .completeGuide : .everything))
        #expect(AppleLiveChannelPackage.defaultPackage(for: Array(repeating: channels.first, count: 30).compactMap { $0 }) == .everything)
    }

    @Test func unrelatedPlaylistKeepsItsChannelsUnderEverything() throws {
        let channels = (1...40).map {
            AppleIPTVChannel(id: String($0), sourceID: UUID(), name: "Kanal \($0)", group: "All",
                             streamURL: URL(string: "https://fixture.example/\($0).ts")!)
        }
        let package = AppleLiveChannelPackage.defaultPackage(for: channels)
        #expect(package == .everything)
        let snapshot = AppleLiveChannelSnapshot.build(groups: [.init(name: "All", channels: channels)],
            package: package, custom: .init(), entries: try AppleChannelLineupPresets.completeUS(),
            favoriteIDs: [], category: "All")
        #expect(Set(snapshot.channelIDs) == Set(channels.map(\.id)))
    }

    @Test func lineupCannotCreatePlaylistChannels() throws {
        let entries = try AppleChannelLineupPresets.completeUS()
        #expect(AppleChannelProjection.completeGuideGroups(from: [], entries: entries).isEmpty)
        let snapshot = AppleLiveChannelSnapshot.build(groups: [], package: .completeGuide, custom: .init(),
                                                      entries: entries, favoriteIDs: [], category: "All")
        #expect(snapshot.channels.isEmpty)
    }

    @Test func sourceStringLiteralsHaveNoOldPackageBranding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let literals = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        let forbidden = try NSRegularExpression(pattern: #"\b(?:Premier|DIRECTV)\b"#, options: .caseInsensitive)
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for match in literals.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let literal = ns.substring(with: match.range)
                #expect(forbidden.firstMatch(in: literal, range: NSRange(location: 0, length: (literal as NSString).length)) == nil,
                        "Old package branding in \(file.lastPathComponent): \(literal)")
            }
        }
    }
}
