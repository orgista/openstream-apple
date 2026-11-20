import Foundation
import Testing
@testable import OpenStreamApple

struct AppleChannelPresentationTests {
    @Test(arguments: [
        ("CA: AMC", "AMC"), ("US|BBC One", "BBC One"), ("UK | Sky News", "Sky News"),
        ("[CA] CBC News", "CBC News"), ("(US) Discovery", "Discovery"),
        ("CA: US| HBO", "HBO"), ("  ca : TV5  ", "TV5"),
        ("BBC: News", "BBC: News"), ("C-SPAN", "C-SPAN"), ("USA Network", "USA Network"),
        ("USA: HBO", "HBO"), ("CAN| CBC", "CBC"),
        ("TV: Land", "TV: Land"), ("ID: Investigation Discovery", "ID: Investigation Discovery"),
        ("BT: Sport", "BT: Sport"), ("AT: Home", "AT: Home"),
        ("Channel 4", "Channel 4"), ("CA:", "CA:"), ("CA: US|", "CA: US|"),
        ("", "Channel"), ("   ", "Channel")
    ])
    func displayNamesRemoveOnlyCountryTags(input: String, expected: String) {
        #expect(AppleChannelPresentation.displayName(input) == expected)
    }

    @Test(arguments: ["CAR", "ES", "IRE", "PH", "PR"])
    func ownerPlaylistRegionTagsAreRemoved(prefix: String) {
        for name in ["\(prefix): AMC", "\(prefix)| AMC", "[\(prefix)] AMC", "(\(prefix)) AMC"] {
            #expect(AppleChannelPresentation.displayName(name) == "AMC")
        }
        #expect(AppleChannelPresentation.displayName("CA: \(prefix)| AMC") == "AMC")
        #expect(AppleChannelPresentation.displayName("\(prefix):") == "\(prefix):")
    }

    @Test(arguments: ["EPL", "MLB", "NBA", "NHL", "UCL", "UHD", "FR", "DE"])
    func sportsQualityAndUnseenCountryPrefixesRemain(prefix: String) {
        #expect(AppleChannelPresentation.displayName("\(prefix): Channel") == "\(prefix): Channel")
        #expect(AppleChannelPresentation.displayName("\(prefix)| Channel") == "\(prefix)| Channel")
    }

    @Test(arguments: [
        ("AMC", "AMC"), ("Discovery Channel", "DC"),
        ("Sky Sports News", "SSN"), ("C-SPAN", "CS"), ("", "TV")
    ])
    func monogramsDescribeTheChannel(input: String, expected: String) {
        #expect(AppleChannelPresentation.monogram(input) == expected)
    }

    @Test func playlistAndCachedChannelsKeepTheirProviderLogoAndIdentity() throws {
        let source = UUID()
        let playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-id="amc" tvg-logo="https://fixture.example/amc.png",CA: AMC
        https://fixture.example/amc.ts
        #EXTINF:-1 tvg-id="discovery",US| Discovery Channel
        https://fixture.example/discovery.ts
        """
        let channels = try AppleIPTVClient.parseM3U(Data(playlist.utf8), sourceID: source,
            baseURL: #require(URL(string: "https://fixture.example/list.m3u")))
        let restored = try JSONDecoder().decode([AppleIPTVChannel].self, from: JSONEncoder().encode(channels))
        #expect(restored == channels)
        #expect(restored.map(\.name) == ["CA: AMC", "US| Discovery Channel"])
        #expect(restored.map(\.displayName) == ["AMC", "Discovery Channel"])
        #expect(restored.first?.logoURL == URL(string: "https://fixture.example/amc.png"))
        #expect(restored.last?.logoURL == nil)
        #expect(restored.map(\.guideID) == ["amc", "discovery"])
        #expect(restored.map(\.id) == channels.map(\.id))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(channels[0])) as? [String: Any])
        #expect(encoded["displayName"] == nil)
        let rail = AppleTVGuideRailCellModel(channelID: channels[0].id, name: channels[0].displayName,
            number: 7, isFavorite: true)
        #expect(rail.name == "AMC")
        #expect(rail.channelID == channels[0].id)
        let entry = AppleLiveChannelPickerEntry(channel: channels[0], nowTitle: "Evening Film", isCurrent: false)
        #expect(entry.accessibilityLabel == "AMC, Evening Film")
    }

    @Test func logosStayClearUntilLoadedAndUseMonogramsOnlyForMissingOrFailedArt() throws {
        let logo = try #require(URL(string: "https://fixture.example/channel.png"))
        let other = try #require(URL(string: "https://fixture.example/other.png"))
        #expect(AppleChannelPresentation.logoState(url: logo, loadedURL: nil, failedURL: nil) == .loading)
        #expect(AppleChannelPresentation.logoState(url: logo, loadedURL: logo, failedURL: nil) == .image)
        #expect(AppleChannelPresentation.logoState(url: nil, loadedURL: nil, failedURL: nil) == .fallback)
        #expect(AppleChannelPresentation.logoState(url: logo, loadedURL: nil, failedURL: logo) == .fallback)
        #expect(AppleChannelPresentation.logoState(url: other, loadedURL: logo, failedURL: logo) == .loading)
    }

    @Test @MainActor func derivedIdentityAndAllPlaylistFieldsSurviveCodableRoundTrip() throws {
        let sourceID = UUID()
        let playlist = """
        #EXTM3U url-tvg="https://fixture.example/guide.xml"
        #EXTINF:-1 group-title="Movies" tvg-logo="https://fixture.example/amc.png",CA: AMC
        #EXTVLCOPT:http-user-agent=Fixture Agent
        #EXTVLCOPT:http-referrer=https://fixture.example/player
        #EXTVLCOPT:http-origin=https://fixture.example
        https://fixture.example/amc.ts
        """
        let baseURL = try #require(URL(string: "https://fixture.example/list.m3u"))
        let channels = try AppleIPTVClient.parseM3U(Data(playlist.utf8), sourceID: sourceID, baseURL: baseURL)
        var channel = try #require(channels.first)
        try #require(channel.guideID == nil)
        channel.probedMediaKind = .hlsPlaylist
        channel.wrapsInCaptionMaster = false
        channel.catchUpDays = 3
        channel.catchUpTimeZoneID = "America/Chicago"
        channel.catchUp = .init(style: .append, source: "?utc={utc}")
        channel.channelNumber = 12
        channel.guideDefaultOffsetHours = -1
        channel.guideShiftHours = 0.5
        let suite = "channel-identity-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppleSettingsStore(defaults: defaults)
        settings.favoriteChannelIDs = [channel.id]
        settings.hiddenLiveChannelIDs = [channel.id]
        let restored = try JSONDecoder().decode(AppleIPTVChannel.self, from: JSONEncoder().encode(channel))
        #expect(restored == channel)
        #expect(restored.id == channel.id)
        #expect(restored.guideID == channel.guideID)
        #expect(restored.displayName == "AMC")
        #expect(settings.favoriteChannelIDs.contains(restored.id))
        #expect(settings.hiddenLiveChannelIDs.contains(restored.id))
    }

    @Test @MainActor func liveRequestsSearchAndSystemFavoritesUseTheCleanName() throws {
        let source = AppleSource(id: UUID(), kind: .liveTV, name: "Fixture",
            url: try #require(URL(string: "https://fixture.example/list.m3u")), isEnabled: true)
        let channel = AppleIPTVChannel(id: "derived-channel", sourceID: source.id, name: "CA: CBS",
            streamURL: try #require(URL(string: "https://fixture.example/cbs.ts")))
        #expect(AppleMediaIngestion.channelRecord(source: source, channel: channel).title == "CBS")
        #expect(AppleNowPlayingMetadata(request: channel.playbackRequest()).title == "CBS")
        #expect(AppleLiveSystemChannels.item(channel)?.title == "CBS")
        #expect(AppleSharedChannelSourceChoice.choices(for: [channel], sourceNames: [:]).first?.title == "CBS")
        let cached = AppleMediaRecord(kind: .channel, title: "CA: CBS",
            availability: [.init(instanceID: source.id, capability: .direct, itemReference: channel.id)])
        let match = try #require(AppleCatalogSearchMatch.indexed(cached, sources: [source]))
        let row = AppleCatalogSearchRow(record: cached, match: match)
        #expect(row.displayTitle == "CBS")
        #expect(row.match.item.name == "CBS")
        #expect(row.id == cached.id)
    }
}
