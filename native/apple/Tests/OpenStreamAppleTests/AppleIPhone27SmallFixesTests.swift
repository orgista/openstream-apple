import Foundation
import Testing
@testable import OpenStreamApple

/// The small iPhone 27 v2 re-run fixes that have a rule behind them.
@Suite struct AppleIPhone27SmallFixesTests {
    // MARK: Add Service

    @Test func storesChannelsAndAggregatorsAreNotServices() {
        for name in ["JustWatch TV", "Amazon Video", "Apple TV Store", "HBO Max Amazon Channel",
                     "Paramount Plus Apple TV Channel", "Google Play Movies", "Fandango At Home", "YouTube"] {
            #expect(!AppleWatchProviderPolicy.isStreamingService(name), "\(name)")
        }
        for name in ["Netflix", "Hulu", "fuboTV", "Crunchyroll", "Max", "Peacock Premium", "YouTube TV"] {
            #expect(AppleWatchProviderPolicy.isStreamingService(name), "\(name)")
        }
    }

    /// TMDB's US order from the re-run, then Max, Paramount+ and Peacock
    /// further down: the menu now leads with the services people subscribe to.
    @Test func theMenuLeadsWithTheBigSubscriptionServices() {
        let names = ["Netflix", "Hulu", "Amazon Prime Video", "Apple TV", "Disney Plus", "JustWatch TV",
                     "Amazon Video", "Apple TV Store", "fuboTV", "HBO Max Amazon Channel", "Crunchyroll",
                     "Sling TV", "Philo", "Tubi TV", "Pluto TV", "Max", "Paramount Plus", "Peacock Premium"]
        let directory = names.enumerated().map { AppleWatchProvider(id: $0.offset + 1, name: $0.element, offer: .subscription) }
        let menu = AppleWatchProviderPolicy.addable(directory, enabledProviderIDs: [1]).map(\.name)
        #expect(menu == ["Hulu", "Amazon Prime Video", "Apple TV", "Disney Plus", "Max", "Paramount Plus",
                         "Peacock Premium", "fuboTV", "Crunchyroll", "Sling TV"])
    }

    // MARK: Subtitle Languages

    @Test func theLanguagesPageOnlyScrollsForALanguageBelowTheFirstScreen() {
        #expect(AppleSubtitleLanguages.initialScrollTarget(selected: ["eng"]) == nil)
        #expect(AppleSubtitleLanguages.initialScrollTarget(selected: []) == nil)
        let late = AppleSubtitleLanguages.all.last!.code
        #expect(AppleSubtitleLanguages.initialScrollTarget(selected: [late]) == late)
    }

    // MARK: Error copy

    @Test func theLiveErrorHasOneFullStop() {
        let message = AppleIPTVError.unreachable("The request timed out.").errorDescription ?? ""
        #expect(!message.contains(".."))
        #expect(message.hasPrefix("Could not reach the IPTV panel: The request timed out. Check"))
    }

    @Test func engineInternalsBecomeAPlainSentence() {
        let raw = "HLSVideoEngine: open failed (Demuxer: open failed (Invalid data found when processing input (-1094995529)))"
        // Before playback an open failure is not evidence of truncation (V13);
        // the container probe decides that. Mid-stream it is.
        #expect(AppleTruncatedMediaProbe.readableEngineMessage(raw, midStream: false)
                == AppleTruncatedMediaProbe.openFailedMessage)
        #expect(AppleTruncatedMediaProbe.readableEngineMessage(raw, midStream: true)
                == AppleTruncatedMediaProbe.droppedMessage)
        #expect(AppleTruncatedMediaProbe.droppedMessage.hasPrefix("The file ended early or the connection dropped"))
        #expect(AppleTruncatedMediaProbe.readableEngineMessage("The server is busy.", midStream: false)
                == "The server is busy.")
    }

    @Test func searchShowsTheSameAddonNameAsTheRows() {
        #expect(AppleCatalogShelfPolicy.displaySourceName("AIOMetadata  | ElfHosted") == "AIOMetadata")
    }
}
