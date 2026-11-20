import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleMediaVersionTests {
    @Test func versionMenuIncludesProbedFormatWithoutDuplicatingResolution() throws {
        var version = AppleMediaVersion(id: "v", itemID: "film", sourceID: UUID(), label: "2160P · MKV", parts: [])
        version.formatBadges = [.uhd, .dolbyVision, .surround71]
        #expect(version.menuLabel == "2160P · MKV · HDR · 7.1")
        let restored = try JSONDecoder().decode(AppleMediaVersion.self, from: JSONEncoder().encode(version))
        #expect(restored.formatBadges == version.formatBadges)
        #expect(restored.menuLabel == version.menuLabel)
        #expect(version.quality.dynamicRange == 3)
    }

    @Test func cumulativeTimeline() throws {
        let version = AppleMediaVersion(id: "v", itemID: "film", sourceID: UUID(), label: "4K", parts: [
            .init(id: "p1", ordinal: 1, duration: 1800, reference: "one"),
            .init(id: "p2", ordinal: 2, duration: 2400, reference: "two")])
        #expect(version.duration == 4200)
        #expect(version.location(at: 2100) == .init(ordinal: 2, offset: 300))
        #expect(version.location(at: 1800) == .init(ordinal: 2, offset: 0))
        #expect(version.cumulativePosition(ordinal: 2, offset: 300) == 2100)
        #expect(version.isAvailable(references: ["one"]) == false)
        #expect(version.isAvailable(references: ["one", "two"]))
    }

    @Test func unknownDurationDoesNotGuessPartOffsets() {
        let version = AppleMediaVersion(id: "v", itemID: "film", sourceID: UUID(), label: "", parts: [
            .init(id: "p1", ordinal: 1, duration: nil, reference: "one"),
            .init(id: "p2", ordinal: 2, duration: 1000, reference: "two")])
        #expect(version.duration == nil)
        #expect(version.location(at: 1200) == nil)
        #expect(version.cumulativePosition(ordinal: 2, offset: 20) == nil)
    }

    @Test func runtimeGuardUsesTimeNotPercentage() {
        let progress = ApplePlaybackProgress(position: 2400, duration: 6000)
        #expect(AppleVersionResumePolicy.resolve(own: nil, item: progress, duration: 6000).position == 2400)
        #expect(AppleVersionResumePolicy.resolve(own: nil, item: progress, duration: 6000).needsConfirmation == false)
        #expect(AppleVersionResumePolicy.resolve(own: nil, item: progress, duration: 6720).needsConfirmation)
        #expect(AppleVersionResumePolicy.resolve(own: nil, item: progress, duration: 6720).position == 2400)
        #expect(AppleVersionResumePolicy.resolve(own: progress, item: progress, duration: 6720).needsConfirmation == false)
    }
}

@MainActor @Suite struct AppleVersionProgressTests {
    @Test func stageAUpgradePreservesBothCopiesAndDowngradeKeys() throws {
        try ApplePlaybackAliasFixture.run { f in
            let first = ApplePlaybackProgress(position: 2400, duration: 6000, updatedAt: Date(timeIntervalSince1970: 100))
            let second = ApplePlaybackProgress(position: 900, duration: 6000, updatedAt: Date(timeIntervalSince1970: 200))
            let stageA = AppleConfigurationSnapshot(playbackProgress: [f.oldKey: first, f.newKey: second])
            let bytes = try AppleConfigurationSnapshot.encoder.encode(stageA)
            let restored = try JSONDecoder().decode(AppleConfigurationSnapshot.self, from: bytes)
            f.store.restoreConfigurationProgress(restored.playbackProgress)
            let before = f.store.configurationProgress()
            f.store.migrateVersionProgress(itemID: "film", versions: ["4K": [f.oldID], "1080p": [f.newID]])
            f.store.migrateVersionProgress(itemID: "film", versions: ["4K": [f.oldID], "1080p": [f.newID]])
            #expect(f.store.versionProgress(itemID: "film", versionID: "4K") == first)
            #expect(f.store.versionProgress(itemID: "film", versionID: "1080p") == second)
            #expect(f.store.progress(for: "film") == second)
            for (key, value) in before { #expect(f.store.configurationProgress()[key] == value) }
            f.store.saveVersion(itemID: "film", versionID: "4K", position: 2500, duration: 6000)
            for (key, value) in before { #expect(f.store.configurationProgress()[key] == value) }
            let relaunched = ApplePlaybackStore(defaults: f.defaults)
            #expect(relaunched.versionProgress(itemID: "film", versionID: "4K")?.position == 2500)
            #expect(relaunched.versionProgress(itemID: "film", versionID: "1080p") == second)
            // A Stage-A reader ignores the new blobs and reads its original entries from a v1 snapshot.
            let downgrade = AppleConfigurationSnapshot(playbackProgress: f.store.configurationProgress())
            let downgraded = try JSONDecoder().decode(AppleConfigurationSnapshot.self,
                from: AppleConfigurationSnapshot.encoder.encode(downgrade))
            #expect(try AppleConfigurationSnapshot.encoder.encode(downgraded.playbackProgress[f.oldKey]) == AppleConfigurationSnapshot.encoder.encode(first as ApplePlaybackProgress?))
            #expect(try AppleConfigurationSnapshot.encoder.encode(downgraded.playbackProgress[f.newKey]) == AppleConfigurationSnapshot.encoder.encode(second as ApplePlaybackProgress?))
        }
    }

    @Test func equalClockMigrationKeepsTheFresherVersionValue() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.saveVersion(itemID: "film", versionID: "4K", position: 2500, duration: 6000)
            let own = try #require(f.store.versionProgress(itemID: "film", versionID: "4K"))
            let legacy = ApplePlaybackProgress(position: 2000, duration: 6000, updatedAt: own.updatedAt)
            f.store.restoreConfigurationProgress([f.oldKey: legacy])
            for _ in 0..<2 { f.store.migrateVersionProgress(itemID: "film", versions: ["4K": [f.oldID]]) }
            #expect(f.store.versionProgress(itemID: "film", versionID: "4K") == own)
            #expect(f.store.configurationProgress()[f.oldKey] == legacy)
        }
    }

    @Test func lastPlayedVersionNeverChangesWatchedAndSurvivesAbsence() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.markWatched(mediaID: "film")
            let history = f.store.configurationWatchedHistory()
            f.store.preferVersion("1080p", itemID: "film")
            let relaunched = ApplePlaybackStore(defaults: f.defaults)
            #expect(relaunched.preferredVersion(itemID: "film") == "1080p")
            // An unmounted share falls back for one play; the record stays.
            let fourK = AppleMediaVersion(id: "4K", itemID: "film", sourceID: UUID(), label: "2160p", parts: [
                .init(id: "p", ordinal: 1, duration: 7200, reference: "four")])
            #expect(AppleVersionSelectionPolicy.select([fourK], lastPlayed: relaunched.preferredVersion(itemID: "film"),
                requestedReference: nil)?.id == "4K")
            #expect(relaunched.preferredVersion(itemID: "film") == "1080p")
            #expect(f.store.configurationWatchedHistory() == history)
        }
    }

    @Test func playbackStartRecordsTheVersionThatPlays() throws {
        try ApplePlaybackAliasFixture.run { f in
            var request = ApplePlaybackRequest(url: URL(string: "https://fixture.example/film")!, mediaID: "film", sourceKind: .files)
            f.store.notePlaybackStarted(request)
            #expect(f.store.preferredVersion(itemID: "film") == nil)
            request.hints.versionID = "4K"
            f.store.notePlaybackStarted(request)
            #expect(f.store.preferredVersion(itemID: "film") == "4K")
            request.hints.versionID = "1080p"
            f.store.notePlaybackStarted(request)
            #expect(f.store.preferredVersion(itemID: "film") == "1080p")
        }
    }
}

@MainActor struct AppleLocalMediaVersionTests {
    private func files(_ names: [String]) -> [AppleLibraryItem] {
        let source = UUID()
        return names.map { AppleLibraryItem(sourceID: source, name: $0,
            url: URL(fileURLWithPath: "/" + $0), relativePath: $0, sizeBytes: 100) }
    }
    @Test func copiesAreQualityOrderedAndExtrasExcluded() throws {
        let files = files(["Film.2020.1080p.mkv", "Film.2020.2160p.mkv", "Film.2020.trailer.mkv"])
        let groups = AppleLibrarySeries.groups(files)
        let movie = try #require(groups.first { $0.items.count == 2 })
        let versions = movie.mediaVersions(itemID: "film", playbackID: { $0.id })
        #expect(versions.count == 2)
        #expect(versions[0].label.contains("2160P"))
        #expect(versions.allSatisfy { $0.parts.count == 1 })
        #expect(groups.count == 1)
    }
    @Test func consecutiveStackIsOneVersionAndMissingSuccessorIsOnePart() throws {
        let files = files(["Film.2020.cd1.mkv", "Film.2020.cd2.mkv"])
        let group = try #require(AppleLibrarySeries.groups(files).first)
        let versions = group.mediaVersions(itemID: "film", playbackID: { $0.id },
            durations: [files[0].id: 1800, files[1].id: 2400])
        #expect(versions.count == 1)
        #expect(versions.first?.parts.count == 2)
        #expect(versions.first?.duration == 4200)
        let alone = try #require(AppleLibrarySeries.groups([files[0]]).first)
        #expect(alone.mediaVersions(itemID: "film", playbackID: { $0.id }).first?.parts.count == 1)
    }
}

@Suite struct AppleVersionSelectionPolicyTests {
    private func version(_ id: String, _ reference: String) -> AppleMediaVersion {
        AppleMediaVersion(id: id, itemID: "film", sourceID: UUID(), label: id, parts: [
            .init(id: "p" + id, ordinal: 1, duration: 3600, reference: reference)])
    }

    @Test func lastPlayedWinsOverQualityAndTheRequestedFile() {
        let available = [version("4K", "four"), version("1080p", "ten")]
        #expect(AppleVersionSelectionPolicy.select(available, lastPlayed: "1080p", requestedReference: "four")?.id == "1080p")
    }

    @Test func aRemovedLastPlayedFileFallsBackToTheBestAvailable() {
        let available = [version("4K", "four"), version("1080p", "ten")]
        #expect(AppleVersionSelectionPolicy.select(available, lastPlayed: "replaced", requestedReference: "ten")?.id == "4K")
        #expect(AppleVersionSelectionPolicy.select([], lastPlayed: "replaced", requestedReference: nil) == nil)
    }

    @Test func noRecordKeepsPlayUnchanged() {
        let available = [version("4K", "four"), version("1080p", "ten")]
        #expect(AppleVersionSelectionPolicy.select(available, lastPlayed: nil, requestedReference: "ten")?.id == "1080p")
        #expect(AppleVersionSelectionPolicy.select(available, lastPlayed: nil, requestedReference: "gone")?.id == "4K")
    }

    @Test func theAnsweredPromptPlaysTheVersionItAskedAbout() {
        let available = [version("4K", "four"), version("1080p", "ten")]
        #expect(AppleVersionSelectionPolicy.select(available, confirmed: "4K", lastPlayed: "1080p", requestedReference: "ten")?.id == "4K")
        #expect(AppleVersionSelectionPolicy.select(available, confirmed: "1080p", lastPlayed: "4K", requestedReference: "four")?.id == "1080p")
    }
}

@MainActor struct AppleStackMigrationTests {
    @Test func partTwoUpgradeUsesCumulativeOffsetWithoutChangingOldKeys() throws {
        try ApplePlaybackAliasFixture.run { f in
            f.store.restoreConfigurationProgress([
                f.oldKey: .init(position: 1700, duration: 1800, updatedAt: Date(timeIntervalSince1970: 100)),
                f.newKey: .init(position: 300, duration: 2400, updatedAt: Date(timeIntervalSince1970: 200))])
            let old = f.store.configurationProgress()
            let version = AppleMediaVersion(id: "stack", itemID: "film", sourceID: UUID(), label: "", parts: [
                .init(id: "1", ordinal: 1, duration: 1800, reference: f.oldID),
                .init(id: "2", ordinal: 2, duration: 2400, reference: f.newID)])
            for _ in 0..<2 {
                f.store.migrateVersionProgress(itemID: "film", versions: ["stack": [f.oldID, f.newID]], timelines: ["stack": version])
            }
            #expect(f.store.versionProgress(itemID: "film", versionID: "stack")?.position == 2100)
            #expect(f.store.versionProgress(itemID: "film", versionID: "stack")?.duration == 4200)
            #expect(f.store.configurationProgress()[f.oldKey] == old[f.oldKey])
            #expect(f.store.configurationProgress()[f.newKey] == old[f.newKey])
            var request = ApplePlaybackRequest(url: URL(string: "https://fixture.example/part2")!, mediaID: "film", sourceKind: .files)
            request.hints.versionID = "stack"
            request.hints.versionOffset = 1800
            request.hints.versionDuration = 4200
            f.store.save(request: request, position: 600, duration: 2400)
            #expect(f.store.versionProgress(itemID: "film", versionID: "stack")?.position == 2400)
            #expect(f.store.progress(for: "film")?.duration == 4200)
        }
    }
}

@MainActor struct AppleMediaVersionCacheTests {
    @Test func cacheReopensAndMissingStackStillLeavesAnotherVersionPlayable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("versions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("MediaVersions-v1.json")
        let source = UUID()
        let stack = AppleMediaVersion(id: "stack", itemID: "film", sourceID: source, label: "4K", parts: [
            .init(id: "p1", ordinal: 1, duration: 1800, reference: "one"),
            .init(id: "p2", ordinal: 2, duration: 1800, reference: "two")])
        let alternate = AppleMediaVersion(id: "alternate", itemID: "film", sourceID: source, label: "1080p", parts: [
            .init(id: "p3", ordinal: 1, duration: 3600, reference: "three")])
        AppleMediaVersionCache(url: url).record([stack, alternate])
        let reopened = AppleMediaVersionCache(url: url)
        #expect(reopened.versions[stack.id] == stack)
        #expect(reopened.versions.values.filter { $0.isAvailable(references: ["one", "three"]) }.map(\.id) == ["alternate"])
    }
}

@MainActor struct AppleMediaVersionCacheWriteTests {
    @Test func aNewerVerificationAloneIsKeptInMemoryWithoutAWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verified-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("MediaVersions-v1.json")
        var version = AppleMediaVersion(id: "film", itemID: "film", sourceID: UUID(), label: "", parts: [
            .init(id: "p1", ordinal: 1, duration: 3600, reference: "one")])
        let cache = AppleMediaVersionCache(url: url)
        cache.record([version])
        version.lastVerified = version.lastVerified.addingTimeInterval(2 * 60 * 60)
        cache.record([version])
        #expect(cache.diskWrites == 1)
        #expect(cache.versions["film"]?.lastVerified == version.lastVerified)
        let relabeled = AppleMediaVersion(id: "film", itemID: "film", sourceID: version.sourceID, label: "4K", parts: version.parts)
        cache.record([relabeled])
        #expect(cache.diskWrites == 2)
        #expect(AppleMediaVersionCache(url: url).versions["film"]?.label == "4K")
    }
}

@MainActor struct AppleLearnedPartDurationTests {
    @Test func aPartLengthLearnedFromPlaybackCompletesTheStackTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("learned-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("MediaVersions-v1.json")
        let stack = AppleMediaVersion(id: "stack", itemID: "film", sourceID: UUID(), label: "", parts: [
            .init(id: "p1", ordinal: 1, duration: nil, reference: "one"),
            .init(id: "p2", ordinal: 2, duration: nil, reference: "two")])
        let cache = AppleMediaVersionCache(url: url)
        cache.record([stack])
        cache.learnDuration(1800, reference: "one")
        #expect(AppleMediaVersionCache(url: url).versions["stack"]?.duration == nil)
        cache.learnDuration(.nan, reference: "two")
        cache.learnDuration(2400, reference: "two")
        // A measured part is never overwritten by a later report.
        cache.learnDuration(10, reference: "one")
        #expect(AppleMediaVersionCache(url: url).versions["stack"]?.duration == 4200)
    }
}

@MainActor struct AppleKnownStackAvailabilityTests {
    @Test func aMissingKnownPartCannotTurnTheRemainingPartIntoACompleteFilm() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("known-stack-" + UUID().uuidString)
        let suite = "known-stack-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = AppleSource(kind: .library, name: "Fixture", url: root)
        let files = ["Film.2020.2160p.cd1.mkv", "Film.2020.2160p.cd2.mkv", "Film.2020.1080p.mkv"].map {
            AppleLibraryItem(sourceID: source.id, name: $0, url: root.appendingPathComponent($0), relativePath: $0, sizeBytes: 100)
        }
        let group = try #require(AppleLibrarySeries.groups(files).first)
        let cacheURL = root.appendingPathComponent("MediaVersions-v1.json")
        let cached = group.mediaVersions(itemID: "film", playbackID: { AppleMediaIngestion.libraryRecord(source: source, item: $0).id },
            durations: [files[0].id: 1800, files[1].id: 1800, files[2].id: 3600])
        AppleMediaVersionCache(url: cacheURL).record(cached)
        // A later scan sees cd2 and the other version, but cd1 is gone.
        let remaining = Array(files.dropFirst())
        let progressStore = ApplePlaybackStore(defaults: defaults)
        let partTwoID = AppleMediaIngestion.libraryRecord(source: source, item: files[1]).id
        progressStore.restoreConfigurationProgress([ApplePlaybackIdentity.storageKey(for: partTwoID)!:
            .init(position: 300, duration: 1800, updatedAt: Date(timeIntervalSince1970: 200))])
        let store = AppleLocalLibraryStore(playbackStore: progressStore,
            groups: AppleLibrarySeries.groups(remaining), sources: [source], versionCacheURL: cacheURL)
        let versions = store.mediaVersions(for: files[1])
        let stack = try #require(versions.first { $0.label.contains("2160P") })
        #expect(stack.id == cached.first?.id)
        #expect(stack.parts.count == 2)
        #expect(progressStore.versionProgress(itemID: stack.itemID, versionID: stack.id)?.position == 2100)
        let references = Set(remaining.map(\.id))
        #expect(stack.isAvailable(references: references) == false)
        // Unmatched, the 1080p file is its own item (design §2) and still plays.
        #expect(versions.filter { $0.isAvailable(references: references) }.isEmpty)
        #expect(store.mediaVersions(for: files[2]).filter { $0.isAvailable(references: references) }.count == 1)
    }
}
