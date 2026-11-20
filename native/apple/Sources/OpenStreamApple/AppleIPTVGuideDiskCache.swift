import Foundation

/// Parsed guide data, partitioned by source and configuration digest. No URLs or credentials are stored.
public actor AppleIPTVGuideDiskCache {
    public static let shared = AppleIPTVGuideDiskCache()
    public static let maximumProgrammes = 500_000
    private let directory: URL?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("oStream/LiveGuide", isDirectory: true)
    }

    public struct Snapshot: Codable, Sendable {
        public let programmes: [AppleIPTVProgramme]
        public let channelNames: [String: String]
        public var mappingEvidence: [String: AppleIPTVGuideMappingEvidence]? = nil
        public var fetchedAt: Date? = nil
        public var eTag: String? = nil
        public var lastModified: String? = nil
        public var contentDigest: String? = nil
        /// Older snapshots contain mapped channels; new XMLTV snapshots retain provider channels.
        public var isRawXMLTV: Bool? = nil
        /// A generation is published only after all its UTC-day shards exist.
        var shardGeneration: UUID? = nil
        var shardDays: [Int]? = nil
        var binaryShards: Bool? = nil
    }

    public func programmes(key: String, now: Date = .now) -> [AppleIPTVProgramme] {
        snapshot(key: key, now: now).programmes
    }

    public func snapshot(key: String, now: Date = .now) -> Snapshot {
        let empty = Snapshot(programmes: [], channelNames: [:])
        guard let url = fileURL(key),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 96 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return empty }
        if snapshot.isRawXMLTV == true || (snapshot.mappingEvidence != nil && snapshot.shardGeneration != nil) {
            if let generation = snapshot.shardGeneration, let days = snapshot.shardDays {
                guard days.count <= 16 else { return empty }
                var size = data.count
                var programmes: [AppleIPTVProgramme] = []
                for day in days {
                    let shard = shardURL(url, generation: generation, day: day, binary: snapshot.binaryShards == true)
                    guard let bytes = try? shard.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          bytes <= 96 * 1024 * 1024 - size,
                          let data = try? Data(contentsOf: shard),
                          let values = try? Self.decodeShard(data, binary: snapshot.binaryShards == true),
                          values.count <= Self.maximumProgrammes - programmes.count else { return empty }
                    size += bytes
                    programmes.append(contentsOf: values)
                }
                snapshot = Snapshot(programmes: Self.retained(programmes, now: now), channelNames: snapshot.channelNames,
                    mappingEvidence: snapshot.mappingEvidence, fetchedAt: snapshot.fetchedAt, eTag: snapshot.eTag, lastModified: snapshot.lastModified,
                    contentDigest: snapshot.contentDigest, isRawXMLTV: snapshot.isRawXMLTV)
            } else {
                snapshot = Snapshot(programmes: Self.retained(snapshot.programmes, now: now), channelNames: snapshot.channelNames,
                    mappingEvidence: snapshot.mappingEvidence, fetchedAt: snapshot.fetchedAt, eTag: snapshot.eTag, lastModified: snapshot.lastModified,
                    contentDigest: snapshot.contentDigest, isRawXMLTV: snapshot.isRawXMLTV)
                store(snapshot.programmes, key: key, channelNames: snapshot.channelNames,
                    mappingEvidence: snapshot.mappingEvidence, fetchedAt: snapshot.fetchedAt, eTag: snapshot.eTag, lastModified: snapshot.lastModified,
                    contentDigest: snapshot.contentDigest, isRawXMLTV: true, now: now)
            }
            return snapshot
        }
        let valid = snapshot.programmes.filter { $0.end > now && $0.end > $0.start }
        if valid.isEmpty && snapshot.mappingEvidence == nil { try? FileManager.default.removeItem(at: url) }
        return Snapshot(programmes: Array(valid.prefix(Self.maximumProgrammes)), channelNames: snapshot.channelNames,
            mappingEvidence: snapshot.mappingEvidence,
            fetchedAt: snapshot.fetchedAt, eTag: snapshot.eTag, lastModified: snapshot.lastModified,
            contentDigest: snapshot.contentDigest, isRawXMLTV: snapshot.isRawXMLTV)
    }

    @discardableResult
    public func store(_ programmes: [AppleIPTVProgramme], key: String, channelNames: [String: String] = [:],
                      mappingEvidence: [String: AppleIPTVGuideMappingEvidence]? = nil,
                      fetchedAt: Date? = nil, eTag: String? = nil, lastModified: String? = nil,
                      contentDigest: String? = nil, isRawXMLTV: Bool? = nil, now: Date? = nil) -> Bool {
        guard let directory, let url = fileURL(key), (!programmes.isEmpty || isRawXMLTV == true || mappingEvidence != nil) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sharded = isRawXMLTV == true || mappingEvidence != nil
        let values = sharded ? Self.retained(programmes, now: now ?? fetchedAt ?? .now)
            : Array(programmes.prefix(Self.maximumProgrammes))
        let grouped = mappingEvidence == nil ? [:] : Dictionary(grouping: values, by: \.channelID)
        var retainedEvidence = mappingEvidence
        for (id, value) in retainedEvidence ?? [:] {
            var evidence = value
            evidence.coverage = AppleIPTVGuideMappingEvidence.coverage(of: grouped[id] ?? [])
            retainedEvidence?[id] = evidence
        }
        var snapshot = Snapshot(programmes: sharded ? [] : values, channelNames: channelNames,
            mappingEvidence: retainedEvidence,
            fetchedAt: fetchedAt, eTag: eTag, lastModified: lastModified,
            contentDigest: contentDigest, isRawXMLTV: isRawXMLTV)
        var written: [URL] = []
        do {
            var total = 0
            if sharded {
                let generation = UUID()
                let firstDay = Int(floor((now ?? fetchedAt ?? .now).addingTimeInterval(-3 * 86_400).timeIntervalSince1970 / 86_400))
                let groups = Dictionary(grouping: values) { max(firstDay, Int(floor($0.start.timeIntervalSince1970 / 86_400))) }
                snapshot.shardGeneration = generation
                snapshot.shardDays = groups.keys.sorted()
                snapshot.binaryShards = true
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                for day in snapshot.shardDays ?? [] {
                    let data = try encoder.encode(groups[day] ?? [])
                    total += data.count
                    guard total <= 96 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                    let shard = shardURL(url, generation: generation, day: day, binary: true)
                    written.append(shard)
                    try data.write(to: shard, options: .atomic)
                }
            }
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 96 * 1024 * 1024 - total else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
            let prefix = url.deletingPathExtension().lastPathComponent + ".day."
            let publishedNames = Set(written.map(\.lastPathComponent))
            for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent.hasPrefix(prefix) && !publishedNames.contains(old.lastPathComponent) {
                try? FileManager.default.removeItem(at: old)
            }
            return true
        } catch {
            // A failed generation never replaces the previously published one.
            for shard in written { try? FileManager.default.removeItem(at: shard) }
            return false
        }
    }

    /// Flatten and bound projected evidence on the disk actor, never in a view's actor.
    func storeEvidence(_ channelProgrammes: [String: [AppleIPTVProgramme]], key: String,
                       evidence: [String: AppleIPTVGuideMappingEvidence], now: Date) -> Bool {
        store(channelProgrammes.filter { evidence[$0.key] != nil }.values.flatMap { $0 },
              key: key, mappingEvidence: evidence, now: now)
    }

    func remove(key: String) {
        guard let url = fileURL(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func retained(_ programmes: [AppleIPTVProgramme], now: Date) -> [AppleIPTVProgramme] {
        let lower = now.addingTimeInterval(-3 * 86_400), upper = now.addingTimeInterval(7 * 86_400)
        return Array(programmes.lazy.filter { $0.end > $0.start && $0.end > lower && $0.start < upper }
            .prefix(maximumProgrammes))
    }

    private func shardURL(_ manifest: URL, generation: UUID, day: Int, binary: Bool) -> URL {
        manifest.deletingPathExtension().appendingPathExtension("day.\(generation.uuidString).\(day).\(binary ? "plist" : "json")")
    }

    private static func decodeShard(_ data: Data, binary: Bool) throws -> [AppleIPTVProgramme] {
        if binary { return try PropertyListDecoder().decode([AppleIPTVProgramme].self, from: data) }
        return try JSONDecoder().decode([AppleIPTVProgramme].self, from: data)
    }

    private func fileURL(_ key: String) -> URL? {
        directory?.appendingPathComponent(ApplePlaybackIdentity.digest(for: key) + ".json")
    }
}
