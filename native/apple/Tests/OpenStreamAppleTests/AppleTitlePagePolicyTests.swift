import Foundation
import Testing
@testable import OpenStreamApple

@Suite("iPhone title page policy")
struct AppleTitlePagePolicyTests {
    private let calendar = AppleTitlePagePolicy.utcCalendar(locale: Locale(identifier: "en_US"))

    private func day(_ value: String) -> Date {
        AppleHeroBadge.releaseDate(value)!
    }

    private func episode(_ season: Int, _ number: Int, title: String = "", released: String? = nil) -> AppleStremioEpisode {
        AppleStremioEpisode(id: "tt0903747:\(season):\(number)", title: title, season: season, episode: number, releaseInfo: released)
    }

    // MARK: Primary action

    @Test func resumeNamesTheSavedEpisodeOnlyWhenItIsTheOneSelected() {
        let saved = episode(4, 8)
        let progress = ApplePlaybackProgress(position: 600, duration: 3_000, partID: saved.id)
        let resume = AppleTitlePagePolicy.primaryAction(
            type: "series", progress: progress, selectedEpisode: saved, isPlayable: true, hasTrailer: true)
        #expect(resume == .resume(episode: "S4, E8"))
        #expect(resume.title == "Resume S4, E8")

        let other = AppleTitlePagePolicy.primaryAction(
            type: "series", progress: progress, selectedEpisode: episode(2, 1), isPlayable: true, hasTrailer: true)
        #expect(other == .play)
    }

    @Test func filmResumesFromAnUnfinishedPositionAndPlaysOtherwise() {
        let partWay = ApplePlaybackProgress(position: 1_200, duration: 6_000)
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: partWay, selectedEpisode: nil, isPlayable: true, hasTrailer: false).title == "Resume")
        let finished = ApplePlaybackProgress(position: 5_990, duration: 6_000)
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: finished, selectedEpisode: nil, isPlayable: true, hasTrailer: false) == .play)
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: true, hasTrailer: true) == .play)
    }

    @Test func nothingPlayableOffersTheTrailerWhenThereIsOne() {
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "series", progress: nil, selectedEpisode: nil, isPlayable: false, hasTrailer: true) == .playTrailer)
        #expect(AppleTitlePagePolicy.PrimaryAction.playTrailer.title == "Play Trailer")
        #expect(AppleTitlePagePolicy.primaryAction(
            type: "series", progress: nil, selectedEpisode: nil, isPlayable: false, hasTrailer: false) == .play)
    }

    // MARK: Hero button

    @Test func heroWithNothingToPlayAndNoTrailerOpensDetails() {
        let action = AppleTitlePagePolicy.heroPrimaryAction(
            type: "series", progress: nil, selectedEpisode: nil, isPlayable: false, trailer: .none)
        #expect(action == .details)
        let button = AppleTitlePagePolicy.HeroButton(action: action)
        #expect(button.title == "Details")
        #expect(button.systemImage == "info.circle")
        #expect(button.isHidden == false)
    }

    @Test func heroWithNothingToPlayOffersTheTrailerOnceFound() {
        let action = AppleTitlePagePolicy.heroPrimaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: false, trailer: .available)
        #expect(action == .playTrailer)
        // Art-first: the button reads Play Trailer and nothing else, at
        // rest and after the press alike — there is no loading state.
        let button = AppleTitlePagePolicy.HeroButton(action: action)
        #expect(button.title == "Play Trailer")
        #expect(button.systemImage == "play.fill")
    }

    @Test func heroHoldsItsButtonBackWhileTheTrailerLookupIsOut() {
        let action = AppleTitlePagePolicy.heroPrimaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: false, trailer: .pending)
        #expect(action == nil)
        #expect(AppleTitlePagePolicy.HeroButton(action: action).isHidden)
    }

    @Test(arguments: [AppleTitlePagePolicy.TrailerAvailability.none, .pending, .available])
    func heroThatCanPlayAlwaysPlays(trailer: AppleTitlePagePolicy.TrailerAvailability) {
        let partWay = ApplePlaybackProgress(position: 1_200, duration: 6_000)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(
            type: "movie", progress: nil, selectedEpisode: nil, isPlayable: true, trailer: trailer) == .play)
        #expect(AppleTitlePagePolicy.heroPrimaryAction(
            type: "movie", progress: partWay, selectedEpisode: nil, isPlayable: true, trailer: trailer) == .resume(episode: nil))
    }

    @Test func heroPlayKeepsTheOfflineWording() {
        #expect(AppleTitlePagePolicy.HeroButton(action: .play, isDownloaded: true).title == "Play Offline")
        #expect(AppleTitlePagePolicy.HeroButton(action: .details, isDownloaded: true).title == "Details")
    }

    @Test func nextEpisodeHeadingUsesTheAppleSpelling() {
        #expect(AppleTitlePagePolicy.nextEpisodeHeading(episode(4, 8, title: "Follow the Anger")) == "S4, E8 · Follow the Anger")
        #expect(AppleTitlePagePolicy.nextEpisodeHeading(episode(1, 2)) == "S1, E2")
        #expect(AppleTitlePagePolicy.nextEpisodeHeading(AppleStremioEpisode(id: "x", title: "")) == nil)
    }

    // MARK: Schedule badge and eyebrow

    @Test func weeklyShowSaysWhichDayNewEpisodesArrive() {
        // Wednesdays, 2026-09-02 / 09 / 16, next on the 23rd.
        let episodes = [2, 9, 16, 23].enumerated().map { index, date in
            AppleHeroBadge.Episode(season: 4, episode: index + 5, released: day(String(format: "2026-09-%02d", date)))
        }
        let badge = AppleTitlePagePolicy.scheduleBadge(
            type: "series", episodes: episodes, now: day("2026-09-20"), calendar: calendar)
        #expect(badge == "New Episode Every Wednesday")
    }

    @Test func finishedOrIrregularShowsGetNoScheduleBadge() {
        let ended = [2, 9, 16].enumerated().map { index, date in
            AppleHeroBadge.Episode(season: 1, episode: index + 1, released: day(String(format: "2025-01-%02d", date)))
        }
        #expect(AppleTitlePagePolicy.scheduleBadge(
            type: "series", episodes: ended, now: day("2026-09-20"), calendar: calendar) == nil)

        let binge = (1 ... 8).map {
            AppleHeroBadge.Episode(season: 2, episode: $0, released: day("2026-09-18"))
        }
        // All at once is not a schedule; the home hero's rule answers instead.
        #expect(AppleTitlePagePolicy.scheduleBadge(
            type: "series", episodes: binge, now: day("2026-09-20"), calendar: calendar) == "New Episode")
        #expect(AppleTitlePagePolicy.scheduleBadge(
            type: "movie", episodes: binge, now: day("2026-09-20"), calendar: calendar) == nil)
    }

    @Test func eyebrowNamesTheEpisodeAndWhenAnUnairedOneArrives() {
        let now = day("2026-09-20")
        #expect(AppleTitlePagePolicy.episodeEyebrow(episode(4, 8, released: "2026-09-16"), now: now, calendar: calendar) == "EPISODE 8")
        #expect(AppleTitlePagePolicy.episodeEyebrow(episode(4, 9, released: "2026-09-23"), now: now, calendar: calendar)
            == "EPISODE 9 · COMING WEDNESDAY")
        #expect(AppleTitlePagePolicy.episodeEyebrow(episode(4, 10, released: "2026-10-07"), now: now, calendar: calendar)
            == "EPISODE 10 · COMING OCT 7")
        #expect(AppleTitlePagePolicy.episodeEyebrow(episode(0, 2), now: now, calendar: calendar) == "SPECIAL 2")
    }

    // MARK: Chips and glossary

    @Test func chipsAreTheRealCapabilitiesBestFirstWithoutTheRating() {
        let chips = AppleTitlePagePolicy.capabilityChips(formatBadges: ["AD", "TV-MA", "HD", "4K", "SDH", "Nonsense", "CC", "HDR"])
        #expect(chips == ["4K", "HDR", "CC", "SDH", "AD"])
        #expect(AppleTitlePagePolicy.capabilityChips(formatBadges: []).isEmpty)
    }

    @Test func glossaryExplainsOnlyTheAccessibilityChipsShown() {
        let entries = AppleTitlePagePolicy.accessibilityGlossary(chips: ["4K", "SDH", "AD"])
        #expect(entries.map(\.badge) == ["SDH", "AD"])
        #expect(entries.allSatisfy { !$0.meaning.isEmpty })
        #expect(AppleTitlePagePolicy.accessibilityGlossary(chips: ["4K", "HDR"]).isEmpty)
    }

    // MARK: Reference blocks

    @Test func informationListsOnlyWhatIsKnown() {
        let facts = AppleTitlePagePolicy.information(
            year: 2008, releaseInfo: "2008–2013", contentRating: "TV-MA", countries: ["United States", "united states"])
        #expect(facts == [
            .init(label: "Released", value: "2008"),
            .init(label: "Rated", value: "TV-MA"),
            .init(label: "Region of Origin", value: "United States"),
        ])
        #expect(AppleTitlePagePolicy.information(year: nil, releaseInfo: nil, contentRating: nil, countries: []).isEmpty)
        #expect(AppleTitlePagePolicy.information(
            year: nil, releaseInfo: "2020-03-04", contentRating: nil, countries: ["Japan", "Korea"]).map(\.value)
            == ["Mar 4, 2020", "Japan, Korea"])
    }

    @Test func languagesShowOriginalAudioThenTheSpokenList() {
        #expect(AppleTitlePagePolicy.languages(originalLanguage: "English", spokenLanguages: ["English", "Spanish"]) == [
            .init(label: "Original Audio", value: "English"),
            .init(label: "Audio", value: "English, Spanish"),
        ])
        #expect(AppleTitlePagePolicy.languages(originalLanguage: "English", spokenLanguages: ["English"]).count == 1)
        #expect(AppleTitlePagePolicy.languages(originalLanguage: nil, spokenLanguages: []).isEmpty)
        #expect(AppleTitlePagePolicy.languageName("es", locale: Locale(identifier: "en_US")) == "Spanish")
        #expect(AppleTitlePagePolicy.regionName("GB", locale: Locale(identifier: "en_US")) == "United Kingdom")
        #expect(AppleTitlePagePolicy.regionName("United States", locale: Locale(identifier: "en_US")) == "United States")
        #expect(AppleTitlePagePolicy.regionName("usa", locale: Locale(identifier: "en_US")) == "United States")
        #expect(AppleTitlePagePolicy.regionName("uk", locale: Locale(identifier: "en_US")) == "United Kingdom")
    }

    @Test func creditsPreferDetailedPeopleAndOtherwiseLabelTheNames() {
        let detailed = [AppleCreditPerson(name: "Bryan Cranston", role: "Walter White",
                                          portraitURL: URL(string: "https://fixture.example/p.jpg"))]
        #expect(AppleTitlePagePolicy.credits(detailed: detailed, cast: ["Someone"], director: "D", writers: []) == detailed)

        let names = AppleTitlePagePolicy.credits(
            detailed: [], cast: ["Aaron Paul", "Anna Gunn", "aaron paul"], director: "Vince Gilligan", writers: ["Vince Gilligan", "Peter Gould"])
        #expect(names.map(\.name) == ["Aaron Paul", "Anna Gunn", "Vince Gilligan", "Peter Gould"])
        #expect(names.map(\.role) == ["Actor", "Actor", "Director", "Writer"])
        #expect(AppleTitlePagePolicy.credits(detailed: [], cast: [], director: nil, writers: []).isEmpty)
    }

    @Test func portraitWithoutAPictureShowsInitials() {
        #expect(AppleCreditPerson(name: "Bryan Lee Cranston").initials == "BC")
        #expect(AppleCreditPerson(name: "Cher").initials == "C")
        #expect(AppleCreditPerson(name: "X", portraitURL: URL(string: "http://fixture.example/p.jpg")).portraitURL == nil)
    }

    @Test func trailerThumbnailIsTheYouTubeStill() {
        #expect(AppleTitlePagePolicy.trailerThumbnailURL(for: "trailer_456")?.absoluteString
            == "https://i.ytimg.com/vi/trailer_456/mqdefault.jpg")
        #expect(AppleTitlePagePolicy.trailerThumbnailURL(for: "bad key") == nil)
    }

    // MARK: Word clamp

    @Test func clampEndsOnAWholeWord() {
        // "Fits" means at most 20 characters, a stand-in for the font.
        let result = AppleParagraphClamp.clamp("The quick brown fox jumps over the lazy dog", suffix: "…") { $0.count <= 20 }
        #expect(result == .init(visible: "The quick brown fox", isTruncated: true))
        let short = AppleParagraphClamp.clamp("Short text", suffix: "…") { $0.count <= 20 }
        #expect(short == .init(visible: "Short text", isTruncated: false))
        let withMore = AppleParagraphClamp.clamp("The quick brown fox jumps over the lazy dog", suffix: "…  MORE") { $0.count <= 20 }
        #expect(withMore.visible == "The quick")
    }
}
