import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Library loading", .timeLimit(.minutes(1)))
struct AppleLibraryLoadingTests {
    private func files(_ count: Int) -> [AppleLibraryItem] {
        let source = UUID()
        return (0..<count).map { index in
            let name = "Fixture Film \(index).2024.mp4"
            return AppleLibraryItem(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + name),
                relativePath: name, sizeBytes: 12)
        }
    }

    @Test func resolverBoundsLookupsAndReleasesEverySlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MetadataConcurrencyProbe()
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in
            await probe.lookup(title)
        }
        let items = files(40)
        let work = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask { _ = try await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "") }
                }
                try await group.waitForAll()
            }
        }
        await probe.waitForTen()
        #expect(await probe.maximum == 10)
        await probe.release()
        try await work.value
        #expect(await probe.count == 40)
        #expect(await probe.maximum <= 10)
        #expect(await resolver.activeLookupWaiterCount == 0)
    }

    @Test @MainActor func metadataPublishesInBatchesAndReusesFreshMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MetadataConcurrencyProbe(blocks: false)
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in await probe.lookup(title) }
        let groups = AppleLibrarySeries.groups(files(45))
        let store = AppleLocalLibraryStore(resolver: resolver, groups: groups,
            versionCacheURL: root.appendingPathComponent("versions.json"))
        await store.resolveMetadata(groups, tmdbKey: "fixture", omdbKey: "")
        #expect(store.metadata.count == 45)
        #expect(store.contentRevision <= 8)
        let revision = store.contentRevision
        await store.resolveMetadata(groups, tmdbKey: "fixture", omdbKey: "")
        #expect(store.contentRevision == revision)
        #expect(await probe.count == 45)
    }

    @Test func cancelledLookupsDoNotStrandTheConcurrencyBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MetadataConcurrencyProbe()
        let resolver = AppleLibraryMetadataResolver(directory: root) { title, _, _ in await probe.lookup(title) }
        let items = files(40)
        let work = Task {
            await withTaskGroup(of: Void.self) { tasks in
                for item in items {
                    tasks.addTask { _ = try? await resolver.resolve(item, tmdbKey: "fixture", omdbKey: "") }
                }
            }
        }
        await probe.waitForTen()
        work.cancel()
        await probe.release()
        await work.value
        #expect(await resolver.activeLookupWaiterCount == 0)
        #expect(await probe.maximum <= 10)
        let replacement = try await resolver.resolve(files(1)[0], tmdbKey: "fixture", omdbKey: "")
        #expect(replacement != nil)
    }

    @Test func diskIndexRestoresPresenceAndColourWithoutWritingOnRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let cache = AppleArtworkDiskCache(directory: root)
        let colour = AppleArtworkColour(red: 100, green: 80, blue: 60)
        await cache.store(Data([1, 2, 3]), for: url, variant: "raw")
        await cache.storeColour(colour, for: url)
        let file = root.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let restored = AppleArtworkDiskCache(directory: root)
        #expect(await restored.contains(url: url, variant: "raw"))
        #expect(await restored.colour(for: url) == colour)
        #expect(await restored.data(for: url, variant: "raw") == Data([1, 2, 3]))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(after == date)
        #expect(await restored.contains(url: url, variant: "display-512") == false)
    }

    @Test func diskLRUReadOrderSurvivesReopeningTheCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<3).map { try #require(URL(string: "https://fixture.example/\($0).png")) }
        let writer = AppleArtworkDiskCache(directory: root, maximumBytes: 1000)
        for (index, url) in urls.enumerated() {
            await writer.store(Data(repeating: 1, count: 6), for: url, variant: "raw")
            let file = root.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: file.path)
        }
        let reader = AppleArtworkDiskCache(directory: root, maximumBytes: 1000)
        #expect(await reader.data(for: urls[0], variant: "raw") != nil)
        await reader.flushPendingAccesses()
        let reopened = AppleArtworkDiskCache(directory: root, maximumBytes: 16)
        await reopened.trimIfNeeded()
        #expect(await reopened.contains(url: urls[0], variant: "raw"))
        #expect(await reopened.contains(url: urls[1], variant: "raw") == false)
        #expect(await reopened.contains(url: urls[2], variant: "raw"))
    }

    @Test func diskIndexDropsMissingFilesAndReplacesColourInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://fixture.example/poster.png"))
        let cache = AppleArtworkDiskCache(directory: root)
        await cache.store(Data([1, 2, 3]), for: url, variant: "raw")
        let file = root.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw"))
        try FileManager.default.removeItem(at: file)
        #expect(await cache.data(for: url, variant: "raw") == nil)
        #expect(await cache.contains(url: url, variant: "raw") == false)
        let colour = AppleArtworkColour(red: 20, green: 40, blue: 60)
        await cache.storeColour(colour, for: url)
        #expect(await cache.colour(for: url) == colour)
        await cache.store(Data([1]), for: url, variant: "colour")
        #expect(await cache.colour(for: url) == nil)
    }

    @Test func evictionUsesTheInMemoryReadOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<3).map { try #require(URL(string: "https://fixture.example/\($0).png")) }
        let writer = AppleArtworkDiskCache(directory: root, maximumBytes: 1000)
        for (index, url) in urls.enumerated() {
            await writer.store(Data([1, 2, 3, 4, 5, 6]), for: url, variant: "raw")
            let file = root.appendingPathComponent(AppleArtworkDiskCachePolicy.fileName(for: url, variant: "raw"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                ofItemAtPath: file.path)
        }
        let reader = AppleArtworkDiskCache(directory: root, maximumBytes: 16)
        #expect(await reader.data(for: urls[0], variant: "raw") != nil)
        await reader.trimIfNeeded()
        #expect(await reader.contains(url: urls[0], variant: "raw"))
        #expect(await reader.contains(url: urls[1], variant: "raw") == false)
        #expect(await reader.contains(url: urls[2], variant: "raw"))
    }

    @Test(arguments: ["Georgie and Mandys", "Georgie & Mandy’s", "Georgie and Mandy's (2024)", "Georgie and Mandy's 2024"])
    func tolerantShowNames(_ name: String) {
        let parsed = AppleLibraryTitle(title: name, year: 2024, season: 1, episode: 1, kind: .show)
        let show = AppleCatalogItem(mediaID: "tmdb:tv:1", type: "series", name: "Georgie & Mandy's", releaseInfo: "2024")
        #expect(AppleLibraryMetadataResolver.bestMatch([show], parsed: parsed) == show)
    }

    @Test func tolerantMatchingStillRejectsAmbiguousRemakesAndUnrelatedTitles() {
        let parsed = AppleLibraryTitle(title: "Film and Friends", year: nil, season: nil, episode: nil, kind: .movie)
        let first = AppleCatalogItem(mediaID: "tmdb:movie:1", type: "movie", name: "Film & Friends", releaseInfo: "1994")
        let second = AppleCatalogItem(mediaID: "tmdb:movie:2", type: "movie", name: "Film and Friends", releaseInfo: "2024")
        #expect(AppleLibraryMetadataResolver.bestMatch([first, second], parsed: parsed) == nil)
        #expect(AppleLibraryMetadataResolver.bestMatch([.init(mediaID: "3", type: "movie", name: "Another Film")], parsed: parsed) == nil)
    }

    @Test(arguments: [("Blade Runner 2049", "Blade Runner", "2017"),
                      ("Wonder Woman 1984", "Wonder Woman", "2020"), ("1917", "191", "2019")])
    func titleYearsArePreserved(_ title: String, _ otherTitle: String, _ release: String) {
        let parsed = AppleLibraryTitle(title: title, year: nil, season: nil, episode: nil, kind: .movie)
        let exact = AppleCatalogItem(mediaID: "exact", type: "movie", name: title, releaseInfo: release)
        let other = AppleCatalogItem(mediaID: "other", type: "movie", name: otherTitle, releaseInfo: "1982")
        #expect(AppleLibraryMetadataResolver.bestMatch([other, exact], parsed: parsed) == exact)
    }

    @Test func separateReleaseYearDoesNotRemoveTheTitleYear() {
        let parsed = AppleLibraryTitle(title: "Blade Runner 2049 (2017)", year: 2017,
            season: nil, episode: nil, kind: .movie)
        let item = AppleCatalogItem(mediaID: "exact", type: "movie", name: "Blade Runner 2049", releaseInfo: "2017")
        #expect(AppleLibraryMetadataResolver.bestMatch([item], parsed: parsed) == item)
    }

    @Test func showPrefixRequiresMatchingReleaseYear() {
        let spinoff = AppleCatalogItem(mediaID: "spinoff", type: "series", name: "The Original Show: New Adventures", releaseInfo: "2024")
        for year in [nil, 2023] as [Int?] {
            let parsed = AppleLibraryTitle(title: "The Original Show", year: year, season: 1, episode: 1, kind: .show)
            #expect(AppleLibraryMetadataResolver.bestMatch([spinoff], parsed: parsed) == nil)
        }
        let dated = AppleLibraryTitle(title: "The Original Show", year: 2024, season: 1, episode: 1, kind: .show)
        #expect(AppleLibraryMetadataResolver.bestMatch([spinoff], parsed: dated) == spinoff)
        let second = AppleCatalogItem(mediaID: "second", type: "series", name: "The Original Show: More Adventures", releaseInfo: "2024")
        #expect(AppleLibraryMetadataResolver.bestMatch([spinoff, second], parsed: dated) == nil)
    }

    @Test func cappedWalkKeepsTheSamePathsDespiteReversedCompletionAndInputOrder() async throws {
        for reverse in [false, true] {
            let probe = CappedFolderProbe()
            let paths = reverse ? ["d", "c", "b", "a"] : ["a", "b", "c", "d"]
            let root = paths.map { AppleSMBDirectoryEntry(name: $0, path: $0, isDirectory: true) }
            let result = try await AppleSMBDirectoryWalker.scan(root: root, maximumEntries: 5, maximumFolders: 10) { path in
                await probe.load(path)
            }
            #expect(result.status == .partial)
            #expect(result.entries.map(\.path) == ["a", "a/file.mp4", "b", "c", "d"])
        }
    }

    @Test func generatedFixtureKeepsFiveHundredDistinctSearchableTitles() {
        let source = UUID()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let items = (0..<500).map { index in
            let suffix = [index / 676 % 26, index / 26 % 26, index % 26]
                .map { String(letters[$0]) }.joined()
            let title = "Fixture Film title" + suffix
            let name = title + " (2024).mp4"
            let path = "Section \(index / 50)/" + name
            let item = AppleLibraryItem(sourceID: source, name: name, url: URL(fileURLWithPath: "/" + path),
                relativePath: path, sizeBytes: 34)
            #expect(AppleLibraryTitleParser.parse(item).title == title)
            return item
        }
        #expect(AppleLibrarySeries.groups(items).count == 500)
    }

    @Test func folderWalkIsFourWideAndPublishesPartialResults() async throws {
        let probe = FolderConcurrencyProbe()
        let root = (0..<8).map { AppleSMBDirectoryEntry(name: "Folder \($0)", path: "Folder \($0)", isDirectory: true) }
        let work = Task {
            try await AppleSMBDirectoryWalker.scan(root: root, maximumEntries: 100, maximumFolders: 20,
                onProgress: { await probe.progress($0) }, load: { await probe.load($0) })
        }
        await probe.waitForFour()
        #expect(await probe.maximum == 4)
        await probe.release()
        let result = try await work.value
        #expect(result.status == .complete)
        #expect(result.entries.filter { !$0.isDirectory }.count == 8)
        #expect(await probe.maximum <= 4)
        #expect(await probe.fileCounts == Array(0...8))
    }

    @Test func nestedWalkPublishesAtTopLevelFolderCompletion() async throws {
        let probe = FolderConcurrencyProbe()
        let root = [AppleSMBDirectoryEntry(name: "A", path: "A", isDirectory: true)]
        let result = try await AppleSMBDirectoryWalker.scan(root: root, maximumEntries: 100, maximumFolders: 20,
            onProgress: { await probe.progress($0) }) { path in
                if path == "A" { return [.init(name: "Nested", path: "A/Nested", isDirectory: true)] }
                return [.init(name: "Film.mp4", path: "A/Nested/Film.mp4", isDirectory: false)]
            }
        #expect(result.status == .complete)
        #expect(await probe.fileCounts == [0, 1])
    }
}

private actor FolderConcurrencyProbe {
    private var blocks = true
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var fourStarted: CheckedContinuation<Void, Never>?
    private(set) var maximum = 0
    private(set) var fileCounts: [Int] = []

    func load(_ path: String) async -> [AppleSMBDirectoryEntry] {
        active += 1
        maximum = max(maximum, active)
        if active == 4 { fourStarted?.resume(); fourStarted = nil }
        if blocks { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        return [.init(name: "Film.mp4", path: path + "/Film.mp4", isDirectory: false, sizeBytes: 12)]
    }

    func progress(_ entries: [AppleSMBDirectoryEntry]) { fileCounts.append(entries.filter { !$0.isDirectory }.count) }

    func waitForFour() async {
        if maximum < 4 { await withCheckedContinuation { fourStarted = $0 } }
    }

    func release() {
        blocks = false
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume() }
    }
}

private actor MetadataConcurrencyProbe {
    private var blocks: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var tenStarted: CheckedContinuation<Void, Never>?
    private var active = 0
    private(set) var maximum = 0
    private(set) var count = 0

    init(blocks: Bool = true) { self.blocks = blocks }

    func lookup(_ title: AppleLibraryTitle) async -> AppleCatalogItem {
        active += 1
        maximum = max(maximum, active)
        count += 1
        if count >= 10 { tenStarted?.resume(); tenStarted = nil }
        if blocks { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        return AppleCatalogItem(mediaID: "fixture:" + title.title, type: "movie", name: title.title, releaseInfo: "2024")
    }

    func waitForTen() async {
        if count < 10 { await withCheckedContinuation { tenStarted = $0 } }
    }

    func release() {
        blocks = false
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume() }
    }
}

private actor CappedFolderProbe {
    private var otherLoads = 0
    private var first: CheckedContinuation<Void, Never>?

    func load(_ path: String) async -> [AppleSMBDirectoryEntry] {
        if path == "a", otherLoads < 3 {
            await withCheckedContinuation { first = $0 }
        } else if path != "a" {
            otherLoads += 1
            if otherLoads == 3 { first?.resume(); first = nil }
        }
        return [.init(name: "file.mp4", path: path + "/file.mp4", isDirectory: false)]
    }
}
