import Foundation

/// Volatile local playback descriptors. They are never sent to a group session
/// or written to the media index. Folder access remains scoped by the viewer.
struct AppleLibraryTVProgram: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let url: URL
    var securityScopedURL: URL?
    var artworkURL: URL?

    var request: ApplePlaybackRequest {
        .init(url: url, mediaID: id, title: title, sourceKind: .files)
    }

    var isLocal: Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
}

struct AppleLibraryTVChannel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let programs: [AppleLibraryTVProgram]

    init(id: String, name: String, programs: [AppleLibraryTVProgram]) {
        self.id = id
        self.name = name
        var seen = Set<String>()
        self.programs = programs.filter { $0.isLocal && !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}

/// Continuous channels have a real Now Playing / Up Next list. They do not
/// invent broadcast times for files whose running time has not been inspected.
struct AppleLibraryTVQueue: Equatable, Sendable {
    private(set) var channels: [AppleLibraryTVChannel] = []
    private(set) var selectedChannelID: String?
    private var programIDs: [String: String] = [:]

    init(channels: [AppleLibraryTVChannel] = []) { replaceChannels(channels) }

    var selectedChannel: AppleLibraryTVChannel? { channels.first { $0.id == selectedChannelID } }
    var currentProgram: AppleLibraryTVProgram? {
        guard let channel = selectedChannel else { return nil }
        return channel.programs.first { $0.id == programIDs[channel.id] } ?? channel.programs.first
    }

    mutating func replaceChannels(_ values: [AppleLibraryTVChannel]) {
        var seen = Set<String>()
        channels = values.filter { !$0.programs.isEmpty && seen.insert($0.id).inserted }
        programIDs = programIDs.filter { key, _ in channels.contains { $0.id == key } }
        for channel in channels where !channel.programs.contains(where: { $0.id == programIDs[channel.id] }) {
            programIDs[channel.id] = channel.programs.first?.id
        }
        if !channels.contains(where: { $0.id == selectedChannelID }) { selectedChannelID = nil }
    }

    @discardableResult mutating func select(channelID: String) -> AppleLibraryTVProgram? {
        guard channels.contains(where: { $0.id == channelID }) else { return nil }
        selectedChannelID = channelID
        return currentProgram
    }

    @discardableResult mutating func playbackEnded(programID: String) -> AppleLibraryTVProgram? {
        guard currentProgram?.id == programID else { return nil }
        return advance()
    }

    @discardableResult mutating func advance() -> AppleLibraryTVProgram? {
        guard let channel = selectedChannel, let current = currentProgram,
              let index = channel.programs.firstIndex(where: { $0.id == current.id }) else { return nil }
        let next = channel.programs[(index + 1) % channel.programs.count]
        programIDs[channel.id] = next.id
        return next
    }

    func upNext(limit: Int = 3) -> [AppleLibraryTVProgram] {
        guard let channel = selectedChannel, let current = currentProgram,
              let index = channel.programs.firstIndex(where: { $0.id == current.id }),
              limit > 0, channel.programs.count > 1 else { return [] }
        return (1...min(limit, channel.programs.count - 1)).map {
            channel.programs[(index + $0) % channel.programs.count]
        }
    }
}

struct AppleLibraryTVLoadResult: Sendable {
    let channels: [AppleLibraryTVChannel]
    let notices: [String]
}

actor AppleLibraryTVBuilder {
    private let offlineStore: AppleOfflineMediaStore
    private let scanner = AppleLibraryScanner(maximumItems: 501)

    init(offlineStore: AppleOfflineMediaStore = .init()) { self.offlineStore = offlineStore }

    func load(sources: [AppleSource]) async throws -> AppleLibraryTVLoadResult {
        var channels: [AppleLibraryTVChannel] = []
        var notices: [String] = []
        let folders = sources.filter { $0.kind == .library && $0.isEnabled && $0.url.isFileURL }
        for source in folders.prefix(16) {
            try Task.checkCancellation()
            do {
                let root = try AppleLibraryBookmark.resolve(source)
                let items = try await scanner.scan(source: source)
                let path = root.standardizedFileURL.resolvingSymlinksInPath().path
                let rootPath = path.hasSuffix("/") ? path : path + "/"
                let programs = items.prefix(500).compactMap { item -> AppleLibraryTVProgram? in
                    guard item.url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { return nil }
                    return .init(id: AppleMediaIngestion.libraryRecord(source: source, item: item).id,
                                 title: (item.name as NSString).deletingPathExtension,
                                 url: item.url, securityScopedURL: root)
                }
                let channel = AppleLibraryTVChannel(id: "library-tv:\(source.id.uuidString)", name: source.name, programs: programs)
                if !channel.programs.isEmpty { channels.append(channel) }
            } catch is CancellationError { throw CancellationError() }
            catch { notices.append("\(source.name): \(error.localizedDescription)") }
        }
        try Task.checkCancellation()
        let downloads = await offlineStore.allRecords()
        var programs: [AppleLibraryTVProgram] = []
        for record in downloads.prefix(500) {
            try Task.checkCancellation()
            guard await offlineStore.isPathContained(record.localURL) else { continue }
            let title = [record.title ?? "Downloaded Video", record.subtitle].compactMap { $0 }.joined(separator: " · ")
            programs.append(.init(id: record.mediaID, title: title, url: record.localURL, artworkURL: record.artworkURL))
        }
        let channel = AppleLibraryTVChannel(id: "library-tv:downloads", name: "Downloads", programs: programs)
        if !channel.programs.isEmpty { channels.append(channel) }
        return .init(channels: channels, notices: notices)
    }
}
