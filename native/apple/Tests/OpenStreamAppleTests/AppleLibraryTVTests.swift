import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleLibraryTVTests {
    private func program(_ id: String) -> AppleLibraryTVProgram {
        .init(id: id, title: id, url: URL(fileURLWithPath: "/tmp/library-tv-fixture/\(id).mp4"))
    }

    @Test func aLibraryChannelPlaysInOrderAndRepeatsWithoutAnIPTVSource() {
        let channel = AppleLibraryTVChannel(id: "files", name: "Movies", programs: [program("a"), program("b")])
        var queue = AppleLibraryTVQueue(channels: [channel])
        #expect(queue.currentProgram == nil)
        #expect(queue.select(channelID: "files")?.id == "a")
        #expect(queue.upNext().map(\.id) == ["b"])
        #expect(queue.playbackEnded(programID: "a")?.id == "b")
        #expect(queue.playbackEnded(programID: "b")?.id == "a")
        #expect(queue.currentProgram?.request.isLive == false)
        #expect(queue.currentProgram?.request.sourceKind == .files)
    }

    @Test func anEndedEventFromAnOldProgramCannotSkipTheNewChannel() {
        var queue = AppleLibraryTVQueue(channels: [
            .init(id: "one", name: "One", programs: [program("a"), program("b")]),
            .init(id: "two", name: "Two", programs: [program("c"), program("d")])
        ])
        _ = queue.select(channelID: "one")
        _ = queue.select(channelID: "two")
        #expect(queue.playbackEnded(programID: "a") == nil)
        #expect(queue.currentProgram?.id == "c")
        #expect(queue.playbackEnded(programID: "c")?.id == "d")
        #expect(queue.select(channelID: "one")?.id == "a")
        #expect(queue.select(channelID: "two")?.id == "d")
    }

    @Test func refreshingTheLineupPreservesAProgramByIdentityAndHandlesRemovedFiles() {
        var queue = AppleLibraryTVQueue(channels: [.init(id: "files", name: "Files", programs: [program("a"), program("b")])])
        _ = queue.select(channelID: "files")
        _ = queue.playbackEnded(programID: "a")
        queue.replaceChannels([.init(id: "files", name: "Files", programs: [program("b"), program("a")])])
        #expect(queue.currentProgram?.id == "b")
        queue.replaceChannels([.init(id: "files", name: "Files", programs: [program("a")])])
        #expect(queue.currentProgram?.id == "a")
        #expect(queue.upNext().isEmpty)
        #expect(queue.playbackEnded(programID: "a")?.id == "a")
        queue.replaceChannels([])
        #expect(queue.currentProgram == nil)
        #expect(queue.advance() == nil)
    }

    @Test func generatedChannelsRejectRemoteTransportsAndDeduplicatePrograms() {
        let remote = AppleLibraryTVProgram(id: "remote", title: "Remote", url: URL(string: "https://fixture.example/movie.mp4")!)
        let channel = AppleLibraryTVChannel(id: "files", name: "Files", programs: [remote, program("a"), program("a")])
        #expect(channel.programs.map(\.id) == ["a"])
        var queue = AppleLibraryTVQueue(channels: [.init(id: "empty", name: "Empty", programs: []), channel])
        #expect(queue.channels.map(\.id) == ["files"])
        #expect(queue.select(channelID: "missing") == nil)
        #expect(queue.currentProgram == nil)
    }

    @Test func buildingChannelsUsesOnlyEnabledLocalFoldersAndReportsUnreadableSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "library-tv-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Episode 2.mp4", "Episode 1.mp4", "notes.txt"] { try Data("fixture".utf8).write(to: root.appending(path: name)) }
        let sources: [AppleSource] = [
            .init(kind: .library, name: "Episodes", url: root),
            .init(kind: .library, name: "Disabled", url: root, isEnabled: false),
            .init(kind: .nas, name: "Private share", url: URL(string: "smb://fixture.example/private")!),
            .init(kind: .library, name: "Missing folder", url: root.appending(path: "missing"))
        ]
        let builder = AppleLibraryTVBuilder(offlineStore: .init(rootDirectory: root.appending(path: "offline")))
        let result = try await builder.load(sources: sources)
        #expect(result.channels.map(\.name) == ["Episodes"])
        #expect(result.channels.first?.programs.map(\.title) == ["Episode 1", "Episode 2"])
        #expect(result.channels.first?.programs.allSatisfy { $0.securityScopedURL == root } == true)
        #expect(result.notices.count == 1)
        #expect(result.notices.first?.contains("Missing folder") == true)
    }

    @MainActor @Test func cancelledFolderScansDoNotKeepEnumeratingVideos() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "library-tv-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appending(path: "video.mp4"))
        let scanner = AppleLibraryScanner()
        let source = AppleSource(kind: .library, name: "Fixture", url: root)
        let task = Task { @MainActor in try await scanner.scan(source: source) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled scan must stop before returning videos.")
        } catch is CancellationError {
        }
    }
}
