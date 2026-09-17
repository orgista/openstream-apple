import Foundation
import Testing
@testable import OpenStreamApple

/// The owner's French "Généralistes" playlist (2026-09-17), given with "it should
/// be able to accept a larger amount at once… add these and test them all".
///
/// Every `#EXTINF` line is verbatim — ids, names, the `Généralistes` group, the
/// Wikimedia logos, the `url-tvg` EPG header. The stream URLs are **not**: the
/// originals carry a provider path token, so each is replaced with
/// `https://fixture.example/fr/<n>`. Nothing the parser or the guide cares about
/// lives in the URL beyond it being playable.
@Suite("French Généralistes playlist")
struct AppleFrenchPlaylistTests {
    private let source = UUID()

    private func playlist() throws -> [AppleIPTVChannel] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/french-generalistes.m3u")
        let data = try Data(contentsOf: url)
        return try AppleIPTVClient.parseM3U(data, sourceID: source, baseURL: URL(string: "https://fixture.example/")!)
    }

    /// All 28 arrive — none dropped, none merged. Names carry the accents.
    @Test func everyChannelParses() throws {
        let channels = try playlist()
        #expect(channels.count == 28, "expected 28, parsed \(channels.count)")
        #expect(Set(channels.map(\.id)).count == 28, "ids collided")
        #expect(channels.map(\.name).contains("LA CHAÎNE L’ÉQUIPE"))
        #expect(channels.map(\.name).contains("RMC DÉCOUVERTE"))
        #expect(channels.allSatisfy { $0.group == "Généralistes" })
    }

    /// The `url-tvg` header is the EPG the tester asked for; the parser must keep it.
    @Test func theEPGURLIsKept() throws {
        let channels = try playlist()
        let epg = URL(string: "https://www.open-epg.com/files/france.xml")
        #expect(channels.allSatisfy { $0.guideURL == epg })
        #expect(channels.first { $0.name == "TF1" }?.guideID == "TF1.fr")
    }

    /// The tester's bug, on the real playlist: under All with the default
    /// Premier Guide package, a French list must show all 28, not the one or
    /// two that happen to share a name with a US lineup.
    @Test func allShowsTheWholePlaylistUnderPremierGuide() throws {
        let channels = try playlist()
        let entries = try AppleChannelLineupPresets.premierUS()
        let snapshot = AppleLiveChannelSnapshot.build(
            groups: [.init(name: "All", channels: channels)], package: .premierGuide,
            custom: .init(), entries: entries, favoriteIDs: [], category: "All")
        #expect(snapshot.channelIDs.count == 28, "All showed \(snapshot.channelIDs.count) of 28")
    }
}
