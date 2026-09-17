import Foundation
import Testing
@testable import OpenStreamApple

/// "It should be able to accept a larger amount at once" (owner, 2026-09-17).
/// Generated playlists in the shape of the owner's French one, so the numbers
/// mean something: ~245 bytes per entry, accents, a group, a logo, an EPG id.
@Suite("M3U at volume")
struct AppleM3UVolumeTests {
    private let source = UUID()

    private func playlist(entries: Int) -> Data {
        var lines = ["#EXTM3U url-tvg=\"https://www.open-epg.com/files/france.xml\""]
        for i in 1...entries {
            lines.append("#EXTINF:-1 tvg-id=\"Chaine\(i).fr\" tvg-name=\"CHAÎNE \(i) FHD\" group-title=\"Généralistes\" tvg-logo=\"https://thumb.wikimedia.org/wikipedia/commons/thumb/0/00/Logo_\(i).svg/1280px-Logo_\(i).svg.png\",CHAÎNE \(i)")
            lines.append("https://fixture.example/fr/\(i)")
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func parse(_ data: Data) throws -> [AppleIPTVChannel] {
        try AppleIPTVClient.parseM3U(data, sourceID: source, baseURL: URL(string: "https://fixture.example/")!)
    }

    /// Two thousand channels — a big provider, or two merged — arrive whole.
    @Test func twoThousandChannelsParseWhole() throws {
        let channels = try parse(playlist(entries: 2_000))
        #expect(channels.count == 2_000, "parsed \(channels.count) of 2000")
        #expect(Set(channels.map(\.id)).count == 2_000, "ids collided")
        #expect(channels.last?.name == "CHAÎNE 2000")
    }

    /// The owner's real provider is 9,376. The old cap of 10,000 sat 624 above
    /// it; a refresh or a merge crossed it and the tail vanished. This pins the
    /// new headroom: 12,000 must parse whole.
    @Test func twelveThousandChannelsParseWhole() throws {
        let channels = try parse(playlist(entries: 12_000))
        #expect(channels.count == 12_000, "parsed \(channels.count) of 12000 — the cap is biting a realistic provider")
    }

    /// The cap is still a cap: past it the parser stops cleanly rather than
    /// growing without bound. Whatever the number is, exactly that many survive.
    @Test func theCapIsHonouredNotExceeded() throws {
        let cap = AppleIPTVClient.maximumChannels
        let channels = try parse(playlist(entries: cap + 50))
        #expect(channels.count == cap, "expected exactly the cap (\(cap)), got \(channels.count)")
    }

    /// The two ceilings must agree: the byte budget has to be able to carry at
    /// least `maximumChannels` entries of a real playlist, or the channel cap
    /// is unreachable and the byte error fires first with a worse message.
    @Test func theByteCeilingCanCarryTheChannelCap() {
        let bytesPerEntry = playlist(entries: 100).count / 100
        let entriesTheBytesAllow = AppleIPTVClient.maximumResponseBytes / bytesPerEntry
        #expect(entriesTheBytesAllow >= AppleIPTVClient.maximumChannels,
                "12 MB carries \(entriesTheBytesAllow) entries of ~\(bytesPerEntry) B; the channel cap is \(AppleIPTVClient.maximumChannels)")
    }
}
