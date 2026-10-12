import Foundation
import Testing
@testable import OpenStreamApple

// Edge cases for ApplePlayGatingPolicy not covered by
// AppleDetailReadinessTests.swift (canonicalMediaID/isPreparingOnAppear happy
// path with a plain "tt" id and a non-IMDB id, and the multi-season
// defaultEpisodeID ordering test).

@Test func playGatingCanonicalMediaIDTrimsSurroundingWhitespaceBeforeValidating() {
    #expect(ApplePlayGatingPolicy.canonicalMediaID("  tt1234567  ") == "tt1234567")
    #expect(ApplePlayGatingPolicy.canonicalMediaID("   ") == nil)
    #expect(ApplePlayGatingPolicy.requiresIdentifierResolution(mediaID: "   "))
}

@Test func playGatingCanonicalMediaIDRejectsAnIdentifierShorterThanTheImdbFormat() {
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt123") == nil)
    #expect(ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: "tt123"))
}

@Test func playGatingCanonicalMediaIDAcceptsSeasonZeroAsASpecialsEpisode() {
    // Season 0 is the "specials" season; the policy treats it as a resolved,
    // canonical episode id, so Play is ready as soon as it appears.
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567:0:1") == "tt1234567:0:1")
    #expect(ApplePlayGatingPolicy.isPreparingOnAppear(mediaID: "tt1234567:0:1") == false)
}

@Test func playGatingCanonicalMediaIDRejectsATwoPartIdentifier() {
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567:1") == nil)
    #expect(ApplePlayGatingPolicy.requiresIdentifierResolution(mediaID: "tt1234567:1"))
}

@Test func playGatingCanonicalMediaIDEnforcesTheEpisodeNumberBoundaries() {
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567:1:0") == nil)
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567:1:100000") == "tt1234567:1:100000")
    #expect(ApplePlayGatingPolicy.canonicalMediaID("tt1234567:1:100001") == nil)
}

@Test func playGatingDefaultEpisodeIDSkipsSeasonZeroSpecialsWhenALaterSeasonExists() {
    let episodes = [
        AppleStremioEpisode(id: "tt1234567:0:1", title: "Special", season: 0, episode: 1),
        AppleStremioEpisode(id: "tt1234567:2:2", title: "Second of season two", season: 2, episode: 2),
        AppleStremioEpisode(id: "tt1234567:2:1", title: "First of season two", season: 2, episode: 1),
    ]
    #expect(ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes) == "tt1234567:2:1")
}

@Test func playGatingDefaultEpisodeIDFallsBackToSeasonZeroWhenItIsTheOnlySeasonAvailable() {
    let episodes = [
        AppleStremioEpisode(id: "tt1234567:0:2", title: "Special two", season: 0, episode: 2),
        AppleStremioEpisode(id: "tt1234567:0:1", title: "Special one", season: 0, episode: 1),
    ]
    #expect(ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes) == "tt1234567:0:1")
}

@Test func playGatingDefaultEpisodeIDReturnsNilWhenNoEpisodeCarriesBothASeasonAndAnEpisodeNumber() {
    let episodes = [
        AppleStremioEpisode(id: "tt1234567:1:1", title: "Missing season", season: nil, episode: 1),
        AppleStremioEpisode(id: "tt1234567:1:2", title: "Missing episode", season: 1, episode: nil),
        AppleStremioEpisode(id: "", title: "Empty id", season: 1, episode: 1),
    ]
    #expect(ApplePlayGatingPolicy.defaultEpisodeID(episodes: episodes) == nil)
}
