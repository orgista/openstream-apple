import Foundation
import Testing
@testable import OpenStreamApple

/// Which choices the title page's Download Options and Season Download
/// Options prompts offer (the dialog elsewhere, a page on Apple TV).
@Suite("Download option choices")
struct AppleDownloadOptionChoiceTests {
    typealias State = AppleOfflineDownloadCoordinator.State

    private static let downloading = State.downloading(item: "Film", destination: "Film.mp4", received: 10, expected: 100)
    private static let paused = State.paused(item: "Film", destination: "Film.mp4", received: 10, expected: 100)

    @Test("A running download that can pause offers Pause, then Cancel Download")
    func downloadingOffersPause() {
        let choices = AppleDownloadOptionChoice.choices(for: Self.downloading, supportsPauseResume: true, season: false)
        #expect(choices == [.pause, .cancelDownload])
    }

    @Test("A running download that cannot pause offers only Cancel Download")
    func downloadingWithoutPauseSupport() {
        let choices = AppleDownloadOptionChoice.choices(for: Self.downloading, supportsPauseResume: false, season: false)
        #expect(choices == [.cancelDownload])
    }

    @Test("A paused download offers Resume, then Cancel Download")
    func pausedOffersResume() {
        let choices = AppleDownloadOptionChoice.choices(for: Self.paused, supportsPauseResume: false, season: false)
        #expect(choices == [.resume, .cancelDownload])
    }

    @Test("Preparing and resuming downloads can still be cancelled", arguments: [
        State.resolving(item: "Film", destination: "Film.mp4"),
        State.resuming(item: "Film", destination: "Film.mp4", received: 10, expected: nil),
    ])
    func inFlightOffersCancel(state: State) {
        #expect(AppleDownloadOptionChoice.choices(for: state, supportsPauseResume: true, season: false) == [.cancelDownload])
    }

    @Test("No download of its own: nothing to offer", arguments: [
        State.idle,
        State.failed(item: "Film", message: "No source"),
        State.cancelled(item: "Film"),
    ])
    func noDownloadOffersNothing(state: State) {
        #expect(AppleDownloadOptionChoice.choices(for: state, supportsPauseResume: true, season: false).isEmpty)
    }

    @Test("A season always offers Cancel Season Download, after Pause or Resume")
    func seasonChoices() {
        #expect(AppleDownloadOptionChoice.choices(for: Self.downloading, supportsPauseResume: true, season: true)
            == [.pause, .cancelSeasonDownload])
        #expect(AppleDownloadOptionChoice.choices(for: Self.paused, supportsPauseResume: true, season: true)
            == [.resume, .cancelSeasonDownload])
        #expect(AppleDownloadOptionChoice.choices(for: .idle, supportsPauseResume: true, season: true)
            == [.cancelSeasonDownload])
    }

    @Test("Cancels are named for what they cancel and are the only destructive choices")
    func titlesAndRoles() {
        #expect(AppleDownloadOptionChoice.allCases.map(\.title)
            == ["Pause", "Resume", "Cancel Download", "Cancel Season Download"])
        #expect(AppleDownloadOptionChoice.allCases.filter(\.isDestructive) == [.cancelDownload, .cancelSeasonDownload])
        #expect(Set(AppleDownloadOptionChoice.allCases.map(\.id)).count == AppleDownloadOptionChoice.allCases.count)
    }
}
