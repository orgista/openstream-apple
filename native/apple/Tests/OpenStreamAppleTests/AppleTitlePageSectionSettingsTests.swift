import Foundation
import Testing
@testable import OpenStreamApple

private struct NoCredentials: AppleCredentialStoring {
    func string(for account: String) throws -> String? { nil }
    func set(_ value: String, for account: String) throws {}
    func remove(_ account: String) throws {}
}

private func isolatedDefaults() -> UserDefaults {
    let name = "openstream.tests.titlePageSections.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Settings › Title Page (owner 2026-10-28): Trailers, Cast & Crew,
/// Information and About, all on until the viewer turns one off.
@MainActor
@Suite("Title page section switches")
struct AppleTitlePageSectionSettingsTests {
    @Test func allFourStartOn() {
        let store = AppleSettingsStore(defaults: isolatedDefaults(), keychain: NoCredentials())
        #expect(store.titlePageSections == AppleTitlePageSectionVisibility())
        #expect(store.titlePageTrailersEnabled && store.titlePageCastEnabled
                && store.titlePageInformationEnabled && store.titlePageAboutEnabled)
    }

    private static let switches: [ReferenceWritableKeyPath<AppleSettingsStore, Bool>] = [
        \.titlePageTrailersEnabled, \.titlePageCastEnabled, \.titlePageInformationEnabled, \.titlePageAboutEnabled]

    @Test(arguments: 0 ..< 4)
    func eachSwitchPersistsOnItsOwn(_ index: Int) {
        let defaults = isolatedDefaults()
        AppleSettingsStore(defaults: defaults, keychain: NoCredentials())[keyPath: Self.switches[index]] = false

        let reread = AppleSettingsStore(defaults: defaults, keychain: NoCredentials())
        for (other, keyPath) in Self.switches.enumerated() {
            #expect(reread[keyPath: keyPath] == (other != index))
        }
    }

    /// Backup, setup transfer and iCloud sync all carry `configurationKeys`.
    @Test(arguments: 0 ... 4)
    func theSwitchesTravelWithTheConfiguration(offCount: Int) throws {
        let source = AppleSettingsStore(defaults: isolatedDefaults(), keychain: NoCredentials())
        for keyPath in Self.switches.prefix(offCount) { source[keyPath: keyPath] = false }

        let target = AppleSettingsStore(defaults: isolatedDefaults(), keychain: NoCredentials())
        try target.restoreConfiguration(source.configurationValues())

        for (index, keyPath) in Self.switches.enumerated() {
            #expect(target[keyPath: keyPath] == (index >= offCount))
        }
    }
}

@Suite("Title page section visibility")
struct AppleTitlePageSectionVisibilityTests {
    private let keys = ["abc123DEF45", "xyz987UVW65"]
    private let people = [AppleCreditPerson(name: "Bryan Cranston", role: "Walter White")]
    private let facts = [AppleTitlePagePolicy.Fact(label: "Released", value: "2008")]
    private let summary = "A chemistry teacher turns to crime."

    @Test func everythingShowsByDefault() {
        let visibility = AppleTitlePageSectionVisibility()
        #expect(visibility.trailerKeys(keys) == keys)
        #expect(visibility.credits(people) == people)
        #expect(visibility.facts(facts) == facts)
        #expect(visibility.aboutSummary(summary) == summary)
        #expect(visibility.synopsisLineLimit == nil)
    }

    @Test func trailersOffRemovesOnlyTheTrailers() {
        let visibility = AppleTitlePageSectionVisibility(trailers: false)
        #expect(visibility.trailerKeys(keys).isEmpty)
        #expect(visibility.credits(people) == people)
        #expect(visibility.facts(facts) == facts)
        #expect(visibility.aboutSummary(summary) == summary)
    }

    @Test func castOffRemovesOnlyCastAndCrew() {
        let visibility = AppleTitlePageSectionVisibility(castAndCrew: false)
        #expect(visibility.trailerKeys(keys) == keys)
        #expect(visibility.credits(people).isEmpty)
        #expect(visibility.facts(facts) == facts)
        #expect(visibility.aboutSummary(summary) == summary)
    }

    @Test func informationOffRemovesOnlyTheFacts() {
        let visibility = AppleTitlePageSectionVisibility(information: false)
        #expect(visibility.trailerKeys(keys) == keys)
        #expect(visibility.credits(people) == people)
        #expect(visibility.facts(facts).isEmpty)
        #expect(visibility.aboutSummary(summary) == summary)
    }

    @Test func aboutOffRemovesOnlyAbout() {
        let visibility = AppleTitlePageSectionVisibility(about: false)
        #expect(visibility.trailerKeys(keys) == keys)
        #expect(visibility.credits(people) == people)
        #expect(visibility.facts(facts) == facts)
        #expect(visibility.aboutSummary(summary) == nil)
        #expect(visibility.synopsisLineLimit == 3)
    }
}
