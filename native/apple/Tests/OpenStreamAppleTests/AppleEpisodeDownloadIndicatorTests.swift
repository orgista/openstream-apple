import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleEpisodeDownloadIndicatorTests {
    typealias State = AppleOfflineDownloadCoordinator.State
    let title = "S1 E1 · First Response"

    @Test func resolvingThisEpisodeReadsPreparing() {
        let indicator = AppleEpisodeDownloadIndicator.resolve(
            episodeTitle: title, coordinatorState: .resolving(item: title, destination: "x"), isDownloaded: false)
        #expect(indicator == .preparing)
        #expect(indicator.accessibilityLabel(episodeTitle: title) == "Preparing \(title)")
    }

    @Test func downloadingCarriesThePercentage() {
        let state = State.downloading(item: title, destination: "x", received: 250, expected: 1_000)
        let indicator = AppleEpisodeDownloadIndicator.resolve(episodeTitle: title, coordinatorState: state, isDownloaded: false)
        #expect(indicator == .downloading(fraction: 0.25))
        #expect(indicator.accessibilityLabel(episodeTitle: title) == "Downloading \(title), 25%")
    }

    @Test func unknownSizeHasNoPercentage() {
        let state = State.downloading(item: title, destination: "x", received: 250, expected: nil)
        let indicator = AppleEpisodeDownloadIndicator.resolve(episodeTitle: title, coordinatorState: state, isDownloaded: false)
        #expect(indicator == .downloading(fraction: nil))
        #expect(indicator.accessibilityLabel(episodeTitle: title) == "Downloading \(title)")
    }

    @Test func anotherEpisodesDownloadLeavesThisRowIdleLooking() {
        let state = State.downloading(item: "S1 E2 · The South Tower", destination: "x", received: 1, expected: 2)
        let indicator = AppleEpisodeDownloadIndicator.resolve(episodeTitle: title, coordinatorState: state, isDownloaded: false)
        #expect(indicator == .otherInProgress)
        #expect(indicator.accessibilityLabel(episodeTitle: title) == "Download \(title)")
    }

    @Test func storedEpisodeWinsOverCoordinatorState() {
        let indicator = AppleEpisodeDownloadIndicator.resolve(
            episodeTitle: title, coordinatorState: .idle, isDownloaded: true)
        #expect(indicator == .downloaded)
        #expect(indicator.accessibilityLabel(episodeTitle: title) == "Downloaded \(title)")
    }

    @Test func failedAndCancelledFallBackToIdle() {
        for state in [State.failed(item: title, message: "m"), .cancelled(item: title), .completed(item: title, destination: URL(fileURLWithPath: "/x"), bytes: 1, container: "mp4")] {
            #expect(AppleEpisodeDownloadIndicator.resolve(episodeTitle: title, coordinatorState: state, isDownloaded: false) == .idle)
        }
    }
}
