import Foundation
import Testing
@testable import OpenStreamApple

@Suite @MainActor
struct AppleMediaServerTitleProgressTests {
    @Test func serverPlaybackPositionProducesResumeOnItsCatalogTitlePage() {
        let source = UUID()
        let reference = AppleMediaServerItemReference(sourceID: source, itemID: "fixture-movie")
        let item = AppleCatalogItem(mediaID: reference.mediaID, type: "movie",
                                    name: "Big Buck Bunny", releaseInfo: "2008")
        let saved = ApplePlaybackProgress(position: 65, duration: 634)
        let lookup: (String) -> ApplePlaybackProgress? = { $0 == reference.mediaID ? saved : nil }
        let key = AppleTitleProgressIdentity.key(
            among: AppleTitleProgressIdentity.candidates(item: item, sourceID: source), progress: lookup)
        #expect(key == reference.mediaID)
        #expect(AppleTitlePagePolicy.primaryAction(type: "movie", progress: key.flatMap(lookup),
            selectedEpisode: nil, isPlayable: true, hasTrailer: false) == .resume(episode: nil))
    }
}
