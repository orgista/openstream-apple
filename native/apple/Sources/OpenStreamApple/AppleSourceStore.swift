import CryptoKit
import Foundation
import Observation

public enum AppleSourceKind: String, Codable, CaseIterable, Sendable {
    case library
    case liveTV
    case nas
    case mediaServer

    public var title: String {
        switch self {
        case .library: "Library"
        case .liveTV: "Live TV"
        case .nas: "Network share"
        case .mediaServer: "Media Server"
        }
    }
}

public enum AppleIPTVSourceType: String, Codable, CaseIterable, Sendable {
    case m3u
    case xtream

    public var title: String {
        switch self {
        case .m3u: "M3U Playlist"
        case .xtream: "Provider Login"
        }
    }
}

public struct AppleIPTVCredentials: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

enum AppleDiagnosticRedactor {
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:https?|smb)://[^\s\"'<>]+"#
    )
    private static let bodyPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(body|requestBody|responseBody)\s*[:=]\s*.*$"#
    )
    private static let credentialPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passwd|pwd|username|user|token|cookie|authorization)\b\s*[\"']?\s*[:=]\s*[\"']?[^,\s;&}\]]+"#
    )
    /// Xtream stream paths without a scheme: `host/live/<user>/<pass>/1.ts`.
    private static let xtreamPathPattern = try! NSRegularExpression(
        pattern: #"(?i)/(live|movie|series)/[^/\s\"'<>]+/[^/\s\"'<>]+/"#
    )
    private static let bearerPattern = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[^\s,;\"'}\]]+"#
    )

    static func redact(_ value: String) -> String {
        var redacted = replace(urlPattern, in: value, with: "[REDACTED URL]")
        redacted = replace(xtreamPathPattern, in: redacted, with: "/$1/[REDACTED]/[REDACTED]/")
        redacted = replace(bearerPattern, in: redacted, with: "Bearer [REDACTED]")
        redacted = replace(bodyPattern, in: redacted, with: "$1=[REDACTED]")
        return replace(credentialPattern, in: redacted, with: "$1=[REDACTED]")
    }

    /// An error for a trace line: its localized text, redacted. `\(error)`
    /// would carry `NSErrorFailingURLStringKey`, i.e. the stream URL.
    static func describe(_ error: any Error) -> String {
        redact(error.localizedDescription)
    }

    private static func replace(
        _ expression: NSRegularExpression,
        in value: String,
        with template: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}

public struct AppleSource: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: AppleSourceKind
    public var name: String
    public var url: URL
    public var isEnabled: Bool
    public var needsSignIn: Bool = false
    var needsSourceAddress: Bool = false
    var usesGuestAccess: Bool = false
    public var isEnabledAfterSignIn: Bool? = nil
    public let addedAt: Date
    public var iptvType: AppleIPTVSourceType?
    public var epgURL: URL?
    public var credentialReference: String?
    public var transportReference: String?
    public var bookmarkData: Data?
    public var isManagedImports: Bool
    public var configurationRevision: Int
    public var lastValidatedAt: Date?
    public var validationSummary: String?
    public var lastValidationFailureAt: Date?
    public var validationFailureSummary: String?
    var savedPlaylistHealth: AppleSavedPlaylistHealth?

    /// Failure history remains available, but a later success resolves its warning.
    public var hasCurrentValidationFailure: Bool {
        if let savedPlaylistHealth { return savedPlaylistHealth.requiresAttention }
        guard let failedAt = lastValidationFailureAt else { return false }
        return failedAt > (lastValidatedAt ?? .distantPast)
    }

    var validationStatus: String? {
        if hasCurrentValidationFailure, let validationFailureSummary { return validationFailureSummary }
        if let savedPlaylistHealth { return savedPlaylistHealth.summary }
        guard lastValidatedAt != nil else { return "Not yet validated" }
        return validationSummary
    }

    public var discoveredItemCount: Int?
    public var capabilities: [String]
    /// The readable Bonjour hostname for NAS sources. `url.host` remains the
    /// resolved numeric endpoint used by the SMB client.
    public var networkDisplayHost: String?

    public var serverKind: AppleMediaServerKind?
    /// Matches accounts across devices without putting a user ID or credential in iCloud.
    public var mediaServerIdentity: String?
    public var connection: AppleSourceConnectionConfiguration?

    // Decode-only bridge for v1 installs. AppleSourceStore immediately moves
    // these values to Keychain and they are never encoded again.
    var legacyUsername: String?
    var legacyPassword: String?

    public init(
        id: UUID = UUID(),
        kind: AppleSourceKind,
        name: String,
        url: URL,
        isEnabled: Bool = true,
        addedAt: Date = .now,
        iptvType: AppleIPTVSourceType? = nil,
        epgURL: URL? = nil,
        credentialReference: String? = nil,
        transportReference: String? = nil,
        bookmarkData: Data? = nil,
        isManagedImports: Bool = false,
        configurationRevision: Int = 1,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        lastValidationFailureAt: Date? = nil,
        validationFailureSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = [],
        networkDisplayHost: String? = nil,
        serverKind: AppleMediaServerKind? = nil,
        mediaServerIdentity: String? = nil,
        connection: AppleSourceConnectionConfiguration? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.addedAt = addedAt
        self.iptvType = iptvType
        self.epgURL = epgURL
        self.credentialReference = credentialReference
        self.transportReference = transportReference
        self.bookmarkData = bookmarkData
        self.isManagedImports = isManagedImports
        self.configurationRevision = max(configurationRevision, 1)
        self.lastValidatedAt = lastValidatedAt
        self.validationSummary = Self.cleanStatus(validationSummary)
        self.lastValidationFailureAt = lastValidationFailureAt
        self.validationFailureSummary = Self.cleanStatus(validationFailureSummary)
        self.discoveredItemCount = Self.cleanItemCount(discoveredItemCount)
        self.capabilities = Self.cleanCapabilities(capabilities)
        self.networkDisplayHost = Self.cleanNetworkDisplayHost(networkDisplayHost)
        self.serverKind = serverKind
        self.mediaServerIdentity = mediaServerIdentity
        self.connection = connection
        legacyUsername = nil
        legacyPassword = nil
    }

    private enum CodingKeys: String, CodingKey {
        case needsSignIn, needsSourceAddress, usesGuestAccess, isEnabledAfterSignIn
        case id, kind, name, url, isEnabled, addedAt, isManagedImports
        case iptvType, epgURL, credentialReference, transportReference, username, password, bookmarkData
        case configurationRevision, lastValidatedAt, validationSummary
        case lastValidationFailureAt, validationFailureSummary, discoveredItemCount, capabilities, networkDisplayHost
        case savedPlaylistHealth
        case serverKind, mediaServerIdentity, connection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(AppleSourceKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(URL.self, forKey: .url)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        needsSignIn = try container.decodeIfPresent(Bool.self, forKey: .needsSignIn) ?? false
        needsSourceAddress = try container.decodeIfPresent(Bool.self, forKey: .needsSourceAddress) ?? false
        usesGuestAccess = try container.decodeIfPresent(Bool.self, forKey: .usesGuestAccess) ?? false
        isEnabledAfterSignIn = try container.decodeIfPresent(Bool.self, forKey: .isEnabledAfterSignIn)
        if needsSignIn || needsSourceAddress { isEnabled = false }
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
        iptvType = try container.decodeIfPresent(AppleIPTVSourceType.self, forKey: .iptvType)
        epgURL = try container.decodeIfPresent(URL.self, forKey: .epgURL)
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
        transportReference = try container.decodeIfPresent(String.self, forKey: .transportReference)
        legacyUsername = try container.decodeIfPresent(String.self, forKey: .username)
        legacyPassword = try container.decodeIfPresent(String.self, forKey: .password)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        isManagedImports = try container.decodeIfPresent(Bool.self, forKey: .isManagedImports) ?? false
        configurationRevision = max(
            try container.decodeIfPresent(Int.self, forKey: .configurationRevision) ?? 1,
            1
        )
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        validationSummary = Self.cleanStatus(try container.decodeIfPresent(String.self, forKey: .validationSummary))
        lastValidationFailureAt = try container.decodeIfPresent(Date.self, forKey: .lastValidationFailureAt)
        validationFailureSummary = Self.cleanStatus(
            try container.decodeIfPresent(String.self, forKey: .validationFailureSummary)
        )
        savedPlaylistHealth = try container.decodeIfPresent(AppleSavedPlaylistHealth.self, forKey: .savedPlaylistHealth)
        discoveredItemCount = Self.cleanItemCount(
            try container.decodeIfPresent(Int.self, forKey: .discoveredItemCount)
        )
        capabilities = Self.cleanCapabilities(
            try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        )
        networkDisplayHost = Self.cleanNetworkDisplayHost(
            try container.decodeIfPresent(String.self, forKey: .networkDisplayHost)
        )
        serverKind = try container.decodeIfPresent(AppleMediaServerKind.self, forKey: .serverKind)
        mediaServerIdentity = try container.decodeIfPresent(String.self, forKey: .mediaServerIdentity)
        connection = try container.decodeIfPresent(AppleSourceConnectionConfiguration.self, forKey: .connection)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(isEnabled, forKey: .isEnabled)
        if needsSignIn { try container.encode(true, forKey: .needsSignIn) }
        if needsSourceAddress { try container.encode(true, forKey: .needsSourceAddress) }
        if usesGuestAccess { try container.encode(true, forKey: .usesGuestAccess) }
        try container.encodeIfPresent(isEnabledAfterSignIn, forKey: .isEnabledAfterSignIn)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(iptvType, forKey: .iptvType)
        try container.encodeIfPresent(epgURL, forKey: .epgURL)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
        try container.encodeIfPresent(transportReference, forKey: .transportReference)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        if isManagedImports { try container.encode(true, forKey: .isManagedImports) }
        try container.encode(configurationRevision, forKey: .configurationRevision)
        try container.encodeIfPresent(lastValidatedAt, forKey: .lastValidatedAt)
        try container.encodeIfPresent(validationSummary, forKey: .validationSummary)
        try container.encodeIfPresent(lastValidationFailureAt, forKey: .lastValidationFailureAt)
        try container.encodeIfPresent(validationFailureSummary, forKey: .validationFailureSummary)
        try container.encodeIfPresent(savedPlaylistHealth, forKey: .savedPlaylistHealth)
        try container.encodeIfPresent(discoveredItemCount, forKey: .discoveredItemCount)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(networkDisplayHost, forKey: .networkDisplayHost)
        try container.encodeIfPresent(serverKind, forKey: .serverKind)
        try container.encodeIfPresent(mediaServerIdentity, forKey: .mediaServerIdentity)
        try container.encodeIfPresent(connection, forKey: .connection)
    }

    private static func cleanStatus(_ value: String?) -> String? {
        value?
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map(AppleDiagnosticRedactor.redact)
            .map { String($0.prefix(200)) }
    }

    private static func cleanItemCount(_ value: Int?) -> Int? {
        value.map { min(max($0, 0), 1_000_000) }
    }

    private static func cleanNetworkDisplayHost(_ value: String?) -> String? {
        value?
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(256)) }
    }

    private static func cleanCapabilities(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let bounded = String(clean.prefix(40))
            guard seen.insert(bounded.lowercased()).inserted else { return nil }
            return bounded
        }.prefix(16).map { $0 }
    }
}

/// A saved source of a kind this app no longer has: builds before 2026-10-22
/// could add a trailer channel (`youtube`) or a catalog source, which always
/// carried a `manifestID`. It is deleted with its Keychain entries wherever
/// it turns up (this device's list, an iCloud copy, a backup, a transfer),
/// its id is tombstoned so an older build stops sending it back, and it is
/// never kept or passed on. A kind a later build adds is not retired.
struct AppleRetiredSource: Equatable, Sendable {
    let id: UUID
    let keychainReferences: [String]

    /// `fields` is one source as stored.
    init?(fields: [String: Any]) {
        guard let kind = fields["kind"] as? String, AppleSourceKind(rawValue: kind) == nil,
              kind == "youtube" || fields["manifestID"] is String,
              let id = (fields["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        self.id = id
        let reference = id.uuidString.lowercased()
        keychainReferences = [fields["credentialReference"] as? String, fields["transportReference"] as? String,
                              reference, "transport.\(reference)", "guide.\(reference)"].compactMap { $0 }
    }

    /// Caches the retired sources and the old chart rows filled in
    /// `Caches/OpenStream`: the shelf cache, the chart and its artwork.
    /// Cheap, so it runs on every launch.
    static func removeLeftoverFiles(fileManager: FileManager = .default) {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let folder = caches.appending(path: "OpenStream", directoryHint: .isDirectory)
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name == "catalogs-v2.json" || name == "top10-artwork-v1.json" || name.hasSuffix("-top10-v1.json") {
            try? fileManager.removeItem(at: folder.appending(path: name))
        }
    }
}

private struct AppleSourceLossyList {
    let values: [AppleSource]
    let retired: [AppleRetiredSource]

    init(data: Data) throws {
        guard let members = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected a source array"))
        }
        var result: [AppleSource] = []
        var retired: [AppleRetiredSource] = []
        for member in members.prefix(1_024) {
            guard JSONSerialization.isValidJSONObject(member),
                  let payload = try? JSONSerialization.data(withJSONObject: member) else {
                continue
            }
            if let value = try? JSONDecoder().decode(AppleSource.self, from: payload) {
                result.append(value)
            } else if let fields = member as? [String: Any], let source = AppleRetiredSource(fields: fields) {
                retired.append(source)
            }
        }
        values = result
        self.retired = retired
    }
}

@MainActor
@Observable
public final class AppleSourceStore {
    public nonisolated static let defaultStorageKey = "openstream.sources.v1"

    public private(set) var sources: [AppleSource]
    public private(set) var sourceTombstones: [UUID: Date]
    public private(set) var credentialError: String?

    private let defaults: UserDefaults
    private let storageKey: String
    private let keychain: any AppleCredentialStoring
    private let localMediaServerKeychain: any AppleCredentialStoring
    private(set) var mediaServerSessionMutations: [UUID: AppleMediaServerSessionMutation]
    private(set) var credentialsRestoreRevision = 0
    var mediaServerSessionDidChange: (() -> Void)?
    var refreshCloudSessionAfterUnauthorized: ((UUID) async -> Bool)?
    private let managedImportsDirectory: URL
    private var protectsStoredBlobWhenEmpty: Bool
    private var pendingCredentialCleanupReferences: [String]
    private var mediaServerSessionsNeedingValidation: Set<UUID> = []

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = AppleSourceStore.defaultStorageKey,
        keychain: any AppleCredentialStoring = AppleKeychainStore(service: "com.orgista.openstream.instances"),
        documentsDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        sourceTombstones = defaults.data(forKey: storageKey + ".tombstones")
            .flatMap { try? JSONDecoder().decode([UUID: Date].self, from: $0) } ?? [:]
        self.keychain = keychain
        localMediaServerKeychain = keychain is AppleKeychainStore ? AppleKeychainStore.localMediaServerSessions : keychain
        mediaServerSessionMutations = defaults.data(forKey: storageKey + ".session-mutations")
            .flatMap { try? JSONDecoder().decode([UUID: AppleMediaServerSessionMutation].self, from: $0) } ?? [:]
        managedImportsDirectory = (documentsDirectory ?? AppleStorageLocation.documents)
            .appendingPathComponent("Imports", isDirectory: true).standardizedFileURL
        credentialError = nil
        pendingCredentialCleanupReferences = defaults.stringArray(
            forKey: storageKey + ".pending-keychain-removals"
        ) ?? []
        var retired: [AppleRetiredSource] = []
        if let data = defaults.data(forKey: storageKey) {
            if let decoded = try? AppleSourceLossyList(data: data) {
                sources = decoded.values.sorted { $0.addedAt < $1.addedAt }
                retired = decoded.retired
                protectsStoredBlobWhenEmpty = decoded.values.isEmpty && decoded.retired.isEmpty
                    && !Self.isEmptyStoredList(data)
            } else {
                sources = []
                protectsStoredBlobWhenEmpty = !Self.isEmptyStoredList(data)
            }
        } else {
            sources = []
            protectsStoredBlobWhenEmpty = false
        }
        if !sourceTombstones.isEmpty { mergeSourceTombstones([:]) }
        retryPendingCredentialCleanup()
        hydrateProtectedTransportURLs()
        hydrateMediaServerIdentities()
        hydrateGuideAddresses()
        normalizeRestoredSourceAvailability()
        migrateLegacyIPTVCredentials()
        hydrateConnectionConfigurations()
        relocateManagedImports()
        // After the migrations above, so the save that drops them is not
        // refused for a source still holding inline credentials.
        if !retired.isEmpty { deleteRetiredSources(retired) }
        AppleRetiredSource.removeLeftoverFiles()
    }

    public func setEnabled(_ enabled: Bool, id: AppleSource.ID,
                           client: AppleMediaServerClient = AppleMediaServerClient(),
                           plexClient: ApplePlexClient = ApplePlexClient()) async throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        if enabled, sources[index].kind == .mediaServer {
            try await enableMediaServer(id: id, client: client, plexClient: plexClient)
            return
        }
        guard sources[index].isEnabled != enabled, !enabled || (!sources[index].needsSignIn && !sources[index].needsSourceAddress) else { return }
        sources[index].isEnabled = enabled
        sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
        persist()
    }

    @discardableResult
    public func addIPTV(
        name: String,
        type: AppleIPTVSourceType,
        endpoint: String,
        username: String = "",
        password: String = "",
        epgURL: String? = nil,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = []
    ) throws -> AppleSource {
        let url = try AppleIPTVEndpointPolicy.normalize(endpoint)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? "My TV" : cleanName
        let cleanUsername = String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        let cleanPassword = String(password.prefix(512))
        let cleanEPGURL: URL?
        if let epgURL, !epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cleanEPGURL = try AppleIPTVEndpointPolicy.normalize(epgURL)
        } else {
            cleanEPGURL = nil
        }
        let cleanValidationSummary = validationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(200)) }
        if type == .xtream, cleanUsername.isEmpty || cleanPassword.isEmpty {
            throw AppleIPTVError.missingCredentials
        }

        if let index = sources.firstIndex(where: { candidate in
            guard candidate.kind == .liveTV, candidate.iptvType == type, candidate.url == url else { return false }
            return type == .m3u || (try? iptvCredentials(for: candidate))?.username == cleanUsername
        }) {
            let existing = sources[index]
            let reference = existing.id.uuidString.lowercased()
            try updateIPTVCredentials(
                type: type,
                reference: reference,
                username: cleanUsername,
                password: cleanPassword
            )
            if cleanEPGURL == nil { try? keychain.remove(Self.guideReference(existing.id)) }
            sources[index] = try securedTransportSource(AppleSource(
                id: existing.id,
                kind: .liveTV,
                name: displayName,
                url: url,
                isEnabled: true,
                addedAt: existing.addedAt,
                iptvType: type,
                epgURL: cleanEPGURL,
                credentialReference: type == .xtream ? reference : nil,
                transportReference: existing.transportReference,
                configurationRevision: nextConfigurationRevision(existing.configurationRevision),
                lastValidatedAt: lastValidatedAt,
                validationSummary: cleanValidationSummary,
                lastValidationFailureAt: existing.lastValidationFailureAt,
                validationFailureSummary: existing.validationFailureSummary,
                discoveredItemCount: discoveredItemCount,
                capabilities: capabilities,
                connection: .init(username: type == .xtream ? cleanUsername : nil)
            ))
            persist()
            queueMediaServerSessionMutation(source: sources[index], deleted: false)
            return sources[index]
        }

        let id = UUID()
        let reference = id.uuidString.lowercased()
        try updateIPTVCredentials(
            type: type,
            reference: reference,
            username: cleanUsername,
            password: cleanPassword
        )
        let source = try securedTransportSource(AppleSource(
            id: id,
            kind: .liveTV,
            name: displayName,
            url: url,
            iptvType: type,
            epgURL: cleanEPGURL,
            credentialReference: type == .xtream ? reference : nil,
            lastValidatedAt: lastValidatedAt,
            validationSummary: cleanValidationSummary,
            discoveredItemCount: discoveredItemCount,
            capabilities: capabilities,
            connection: .init(username: type == .xtream ? cleanUsername : nil)
        ))
        sources.append(source)
        persist()
        queueMediaServerSessionMutation(source: source, deleted: false)
        return source
    }

    @discardableResult
    public func addLibraryFolder(name: String, url: URL, bookmarkData: Data?) throws -> AppleSource {
        guard url.isFileURL else { throw AppleLibrarySourceError.invalidFolder }
        let url = url.standardizedFileURL
        let isManagedImports = url == managedImportsDirectory
        let bookmarkData = isManagedImports ? nil : bookmarkData
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? url.lastPathComponent : cleanName
        if let index = sources.firstIndex(where: { $0.kind == .library && $0.url == url }) {
            sources[index].name = displayName
            sources[index].isEnabled = true
            sources[index].bookmarkData = bookmarkData
            sources[index].isManagedImports = isManagedImports
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
            sources[index].lastValidatedAt = .now
            sources[index].validationSummary = "Folder access granted"
            sources[index].capabilities = ["Files", "Playback"]
            persist()
            return sources[index]
        }
        let source = AppleSource(
            kind: .library,
            name: displayName,
            url: url,
            bookmarkData: bookmarkData,
            isManagedImports: isManagedImports,
            lastValidatedAt: .now,
            validationSummary: "Folder access granted",
            capabilities: ["Files", "Playback"]
        )
        sources.append(source)
        persist()
        return source
    }

    @discardableResult
    public func addNetworkShare(
        name: String,
        host: String,
        port: Int = 445,
        share: String,
        path: String = "",
        username: String = "",
        password: String = "",
        domain: String = "",
        displayHost: String? = nil,
        lastValidatedAt: Date? = nil,
        validationSummary: String? = nil,
        discoveredItemCount: Int? = nil,
        capabilities: [String] = []
    ) throws -> AppleSource {
        let url = try AppleSMBEndpointPolicy.makeURL(host: host, port: port, share: share, path: path)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? share : cleanName
        let cleanDisplayHost = (displayHost ?? host)
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedDisplayHost = cleanDisplayHost.isEmpty ? nil : String(cleanDisplayHost.prefix(256))
        let credentials = AppleSMBCredentials(
            username: String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)),
            password: String(password.prefix(512)),
            domain: String(domain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        )
        let cleanValidationSummary = validationSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map { String($0.prefix(200)) }

        if let index = sources.firstIndex(where: { $0.kind == .nas && $0.url == url }) {
            let oldReference = sources[index].credentialReference
            let reference = try networkCredentialReference(
                server: .init(name: host, host: host, port: port, displayHost: displayHost), credentials: credentials,
                excluding: sources[index].id, preferred: sources[index].credentialReference ?? sources[index].id.uuidString.lowercased())
            try updateNetworkCredentials(credentials, reference: reference)
            sources[index].name = displayName
            sources[index].isEnabled = true
            sources[index].credentialReference = reference
            sources[index].usesGuestAccess = credentials.username.isEmpty && credentials.password.isEmpty && credentials.domain.isEmpty
            sources[index].needsSignIn = false
            sources[index].needsSourceAddress = false
            sources[index].networkDisplayHost = boundedDisplayHost
            sources[index].connection = .init(credentials: credentials)
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
            sources[index].lastValidatedAt = lastValidatedAt
            sources[index].validationSummary = cleanValidationSummary
            sources[index].discoveredItemCount = discoveredItemCount.map { min(max($0, 0), 1_000_000) }
            sources[index].capabilities = boundedCapabilities(capabilities)
            persist()
            retireNetworkCredential(oldReference, keeping: reference)
            queueMediaServerSessionMutation(source: sources[index], deleted: false)
            return sources[index]
        }

        let id = UUID()
        let reference = try networkCredentialReference(
            server: .init(name: host, host: host, port: port, displayHost: displayHost), credentials: credentials,
            preferred: id.uuidString.lowercased())
        try updateNetworkCredentials(credentials, reference: reference)
        var source = AppleSource(
            id: id,
            kind: .nas,
            name: displayName,
            url: url,
            credentialReference: reference,
            lastValidatedAt: lastValidatedAt,
            validationSummary: cleanValidationSummary,
            discoveredItemCount: discoveredItemCount,
            capabilities: capabilities,
            networkDisplayHost: boundedDisplayHost,
            connection: .init(credentials: credentials)
        )
        source.usesGuestAccess = credentials.username.isEmpty && credentials.password.isEmpty && credentials.domain.isEmpty
        sources.append(source)
        persist()
        queueMediaServerSessionMutation(source: source, deleted: false)
        return source
    }

    /// Points an existing network share at a new server, folder or account,
    /// keeping its identity (and so its library and watch history).
    @discardableResult
    func updateNetworkShare(
        id: AppleSource.ID,
        name: String,
        host: String,
        port: Int,
        share: String,
        path: String,
        credentials: AppleSMBCredentials,
        displayHost: String?,
        validationSummary: String?
    ) throws -> AppleSource {
        guard let index = sources.firstIndex(where: { $0.id == id && $0.kind == .nas }) else {
            throw AppleSMBError.invalidShare
        }
        let url = try AppleSMBEndpointPolicy.makeURL(host: host, port: port, share: share, path: path)
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let cleanDisplayHost = (displayHost ?? host)
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oldReference = sources[index].credentialReference
        let cleanCredentials = AppleSMBCredentials(
            username: String(credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512)),
            password: String(credentials.password.prefix(512)),
            domain: String(credentials.domain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)))
        let reference = try networkCredentialReference(
            server: .init(name: host, host: host, port: port, displayHost: displayHost), credentials: cleanCredentials,
            excluding: id, preferred: sources[index].credentialReference ?? id.uuidString.lowercased())
        try updateNetworkCredentials(cleanCredentials, reference: reference)
        sources[index].name = cleanName.isEmpty ? share : cleanName
        sources[index].url = url
        sources[index].isEnabled = true
        sources[index].credentialReference = reference
        sources[index].usesGuestAccess = cleanCredentials.username.isEmpty && cleanCredentials.password.isEmpty && cleanCredentials.domain.isEmpty
        sources[index].needsSignIn = false
        sources[index].needsSourceAddress = false
        sources[index].networkDisplayHost = cleanDisplayHost.isEmpty ? nil : String(cleanDisplayHost.prefix(256))
        sources[index].connection = .init(credentials: cleanCredentials)
        sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
        sources[index].lastValidatedAt = .now
        sources[index].validationSummary = validationSummary.flatMap(boundedStatus)
        persist()
        retireNetworkCredential(oldReference, keeping: reference)
        queueMediaServerSessionMutation(source: sources[index], deleted: false)
        // Open playback sessions still carry the old address or account.
        Task { await AppleSMBRangeServer.shared.removeAllSessions() }
        return sources[index]
    }

    public func recordValidationSuccess(
        id: AppleSource.ID,
        summary: String,
        discoveredItemCount: Int? = nil,
        capabilities: [String]? = nil,
        at date: Date = .now
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].lastValidatedAt = date
        sources[index].needsSignIn = false
        sources[index].savedPlaylistHealth = nil
        sources[index].validationSummary = boundedStatus(summary)
        sources[index].discoveredItemCount = discoveredItemCount.map { min(max($0, 0), 1_000_000) }
        if let capabilities {
            sources[index].capabilities = boundedCapabilities(capabilities)
        }
        persist()
    }

    public func recordValidationFailure(
        id: AppleSource.ID,
        summary: String,
        needsSignIn: Bool = false,
        at date: Date = .now
    ) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].lastValidationFailureAt = date
        sources[index].validationFailureSummary = boundedStatus(summary) ?? "Connection failed"
        if needsSignIn { sources[index].needsSignIn = true }
        sources[index].savedPlaylistHealth?.requiresAttention = true
        persist()
    }

    func recordPlaylistRefreshFailure(id: AppleSource.ID, error: any Error, savedAt: Date?, at date: Date = .now) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !Task.isCancelled,
              let index = sources.firstIndex(where: { $0.id == id && $0.kind == .liveTV }) else { return }
        let summary = AppleIPTVFailureCause.message(for: error, providerName: sources[index].name)
        let authenticationFailed = ApplePlaybackFailure.classify(error).kind == .authentication
        if let savedAt {
            var health = sources[index].savedPlaylistHealth ?? .init(firstFailedAt: date, storedAt: savedAt)
            health.storedAt = savedAt
            health.recordFailure(at: date, authenticationFailed: authenticationFailed)
            sources[index].savedPlaylistHealth = health
            if !health.requiresAttention {
                persist()
                return
            }
        } else {
            sources[index].savedPlaylistHealth = nil
        }
        recordValidationFailure(id: id, summary: summary, at: date)
    }

    @discardableResult
    public func remove(id: AppleSource.ID) -> Bool {
        guard let source = sources.first(where: { $0.id == id }) else {
            appleTrace("remove source \(id): not in the list")
            return false
        }
        appleTrace("remove source \"\(source.name)\" (\(source.kind))")
        let referenceID = source.id.uuidString.lowercased()
        let references = [source.credentialReference, source.transportReference, referenceID, "transport.\(referenceID)",
                          "guide.\(referenceID)", "cloud-session.\(referenceID)", "cloud-transport.\(referenceID)", "cloud-guide.\(referenceID)"].compactMap { $0 }
        pendingCredentialCleanupReferences.append(contentsOf: references)
        pendingCredentialCleanupReferences = Array(Set(pendingCredentialCleanupReferences)).sorted()
        persistPendingCredentialCleanup()
        sourceTombstones[id] = .now
        sources.removeAll { $0.id == id }
        persist()
        retryPendingCredentialCleanup()
        if source.kind != .library { queueMediaServerSessionMutation(source: source, deleted: true) }
        if source.kind == .nas {
            Task { await AppleSMBRangeServer.shared.removeAllSessions() }
        }
        return true
    }

    public func iptvCredentials(for source: AppleSource) throws -> AppleIPTVCredentials? {
        guard source.kind == .liveTV, source.iptvType == .xtream else { return nil }

        var references: [String] = []
        if let reference = source.credentialReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty,
           !references.contains(reference) {
            references.append(reference)
        }
        if let transportReference = source.transportReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transportReference.isEmpty,
           !references.contains(transportReference) {
            references.append(transportReference)
        }
        let sourceReference = source.id.uuidString.lowercased()
        if !references.contains(sourceReference) {
            references.append(sourceReference)
        }

        var lastLookupError: (any Swift.Error)?
        for reference in references {
            do {
                guard let value = try keychain.string(for: reference) ?? localMediaServerKeychain.string(for: reference),
                      let data = value.data(using: .utf8) else { continue }
                let credentials = try JSONDecoder().decode(AppleIPTVCredentials.self, from: data)
                if source.credentialReference != reference, let index = sources.firstIndex(where: { $0.id == source.id }) {
                    sources[index].credentialReference = reference
                    sources[index].legacyUsername = nil
                    sources[index].legacyPassword = nil
                    persist()
                }
                return credentials
            } catch is DecodingError {
                lastLookupError = AppleKeychainStoreError.invalidData
            } catch {
                lastLookupError = error
            }
        }

        let legacyUsername = source.legacyUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let legacyPassword = source.legacyPassword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacyUsername.isEmpty && !legacyPassword.isEmpty {
            let reference = source.credentialReference ?? sourceReference
            try updateIPTVCredentials(type: .xtream, reference: reference, username: legacyUsername, password: legacyPassword)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].credentialReference = reference
                sources[index].legacyUsername = nil
                sources[index].legacyPassword = nil
                persist()
            }
            return AppleIPTVCredentials(username: legacyUsername, password: legacyPassword)
        }

        if let lastLookupError { credentialError = lastLookupError.localizedDescription }
        return nil
    }

    public func networkCredentials(for source: AppleSource) throws -> AppleSMBCredentials? {
        guard source.kind == .nas,
              let reference = source.credentialReference,
              let value = try keychain.string(for: reference) ?? localMediaServerKeychain.string(for: reference),
              let data = value.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(AppleSMBCredentials.self, from: data)
    }

    private func updateIPTVCredentials(
        type: AppleIPTVSourceType,
        reference: String,
        username: String,
        password: String
    ) throws {
        if type == .xtream {
            let credentials = AppleIPTVCredentials(username: username, password: password)
            let data = try JSONEncoder().encode(credentials)
            guard let value = String(data: data, encoding: .utf8) else {
                throw AppleKeychainStoreError.invalidData
            }
            try keychain.set(value, for: reference)
        } else {
            try keychain.remove(reference)
        }
        credentialError = nil
    }

    /// Folders on one server/account share a key. An account/server edit
    /// detaches when its old key is still used by another folder.
    private func networkCredentialReference(
        server: AppleNetworkShareServer,
        credentials: AppleSMBCredentials,
        excluding id: UUID? = nil,
        preferred: String? = nil
    ) throws -> String {
        for source in sources where source.id != id && AppleNetworkSharePolicy.sameServer(source, as: server) {
            // One unreadable sibling entry must not block this folder: it
            // just isn't a key to share.
            guard let reference = source.credentialReference,
                  let saved = try? networkCredentials(for: source),
                  saved.username == credentials.username, saved.domain == credentials.domain else { continue }
            return reference
        }
        if let preferred, !sources.contains(where: { $0.id != id && $0.credentialReference == preferred }) {
            return preferred
        }
        return UUID().uuidString.lowercased()
    }

    private func retireNetworkCredential(_ oldReference: String?, keeping reference: String) {
        guard let oldReference, oldReference != reference else { return }
        pendingCredentialCleanupReferences = Array(Set(pendingCredentialCleanupReferences + [oldReference])).sorted()
        persistPendingCredentialCleanup()
        retryPendingCredentialCleanup()
    }

    private func updateNetworkCredentials(_ credentials: AppleSMBCredentials, reference: String) throws {
        let stored = try keychain.string(for: reference)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(AppleSMBCredentials.self, from: $0) }
        if stored == credentials {
            credentialError = nil
            return
        }
        let data = try JSONEncoder().encode(credentials)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AppleKeychainStoreError.invalidData
        }
        try keychain.set(value, for: reference)
        for index in sources.indices where sources[index].kind == .nas && sources[index].credentialReference == reference {
            sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
        }
        credentialError = nil
    }

    public func addMediaServer(
        kind: AppleMediaServerKind,
        name: String,
        session: AppleMediaServerSession,
        reconnecting sourceID: AppleSource.ID? = nil
    ) throws -> AppleSource {
        let cleanName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let displayName = cleanName.isEmpty ? kind.title : cleanName

        let existingIndex: Int?
        if let sourceID {
            guard let index = sources.firstIndex(where: { $0.id == sourceID && $0.kind == .mediaServer }) else {
                throw AppleMediaServerError.configurationChanged
            }
            existingIndex = index
        } else {
            existingIndex = sources.firstIndex(where: { candidate in
                guard candidate.kind == .mediaServer, candidate.serverKind == kind else { return false }
                if candidate.mediaServerIdentity == Self.mediaServerIdentity(for: session) { return true }
                guard candidate.url.host?.lowercased() == session.baseURL.host?.lowercased(),
                      candidate.url.port == session.baseURL.port else { return false }
                if candidate.needsSignIn, candidate.mediaServerIdentity == nil { return true }
                return (try? mediaServerSession(for: candidate))?.userID == session.userID
            })
        }
        if let index = existingIndex {
            let existing = sources[index]
            let reference = Self.mediaServerCredentialReference(for: existing.id)
            try updateMediaServerCredentials(reference: reference, session: session)
            let updated = try securedTransportSource(AppleSource(
                id: existing.id,
                kind: .mediaServer,
                name: displayName,
                url: session.baseURL,
                isEnabled: sourceID != nil || existing.needsSignIn ? true : existing.isEnabled,
                addedAt: existing.addedAt,
                credentialReference: reference,
                transportReference: existing.transportReference,
                isManagedImports: existing.isManagedImports,
                configurationRevision: nextConfigurationRevision(existing.configurationRevision),
                lastValidatedAt: .now,
                serverKind: kind,
                mediaServerIdentity: Self.mediaServerIdentity(for: session),
                connection: .init(session: session)
            ))
            sources[index] = updated
            persist()
            queueMediaServerSessionMutation(source: updated, deleted: false)
            return updated
        }

        let newID = UUID()
        let reference = Self.mediaServerCredentialReference(for: newID)
        try updateMediaServerCredentials(reference: reference, session: session)

        let newSource = try securedTransportSource(AppleSource(
            id: newID,
            kind: .mediaServer,
            name: displayName,
            url: session.baseURL,
            credentialReference: reference,
            lastValidatedAt: .now,
            serverKind: kind,
            mediaServerIdentity: Self.mediaServerIdentity(for: session),
            connection: .init(session: session)
        ))
        sources.insert(newSource, at: 0)
        persist()
        queueMediaServerSessionMutation(source: newSource, deleted: false)
        return newSource
    }

    nonisolated static func mediaServerCredentialReference(for id: UUID) -> String {
        id.uuidString.lowercased()
    }

    nonisolated static func normalizedMediaServerURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.scheme == "https" && parts.port == 443 || parts.scheme == "http" && parts.port == 80 { parts.port = nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    nonisolated static func mediaServerIdentity(for session: AppleMediaServerSession) -> String {
        let account = [session.kind.rawValue, normalizedMediaServerURL(session.baseURL), session.userID]
        return SHA256.hash(data: Data(account.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sameMediaServerAccount(_ lhs: AppleSource, _ rhs: AppleSource) -> Bool {
        lhs.kind == .mediaServer && rhs.kind == .mediaServer && lhs.serverKind == rhs.serverKind
            && lhs.mediaServerIdentity != nil && lhs.mediaServerIdentity == rhs.mediaServerIdentity
    }

    public func mediaServerSession(for source: AppleSource) throws -> AppleMediaServerSession? {
        let session = try Self.mediaServerSession(for: source, keychain: keychain, localKeychain: localMediaServerKeychain)
        if let session, !Self.mediaServerSession(session, matches: source) {
            mediaServerSessionsNeedingValidation.insert(source.id)
            appleTrace("source session: metadata mismatch; keeping saved token for revalidation")
        }
        return session
    }

    func hasSavedMediaServerSession(for source: AppleSource) async throws -> Bool {
        try await savedMediaServerSession(for: source) != nil
    }

    private func savedMediaServerSession(for source: AppleSource) async throws -> AppleMediaServerSession? {
        if let keychain = keychain as? AppleKeychainStore {
            return try await Self.readMediaServerSession(for: source, keychain: keychain)
        }
        // Injected stores stay on their owning actor; Security queries leave it.
        return try mediaServerSession(for: source)
    }

    @concurrent
    private nonisolated static func readMediaServerSession(for source: AppleSource,
                                                           keychain: AppleKeychainStore) async throws -> AppleMediaServerSession? {
        try mediaServerSession(for: source, keychain: keychain, localKeychain: AppleKeychainStore.localMediaServerSessions)
    }

    private nonisolated static func mediaServerSession(for source: AppleSource,
                                                       keychain: any AppleCredentialStoring,
                                                       localKeychain: any AppleCredentialStoring) throws -> AppleMediaServerSession? {
        guard source.kind == .mediaServer else { return nil }
        let reference = source.credentialReference ?? mediaServerCredentialReference(for: source.id)
        guard let value = try keychain.string(for: reference) ?? localKeychain.string(for: reference),
              let data = value.data(using: .utf8) else {
            return nil
        }
        let session = try JSONDecoder().decode(AppleMediaServerSession.self, from: data)
        return session.accessToken.isEmpty ? nil : session
    }

    private nonisolated static func mediaServerSession(_ session: AppleMediaServerSession, matches source: AppleSource) -> Bool {
        guard !session.accessToken.isEmpty, !session.userID.isEmpty,
              source.serverKind == nil || source.serverKind == session.kind else { return false }
        if let identity = source.mediaServerIdentity {
            return identity == mediaServerIdentity(for: session)
        }
        return normalizedMediaServerURL(source.url) == normalizedMediaServerURL(session.baseURL)
            || source.needsSignIn && AppleConfigurationSnapshot.publicAddress(source.url)
                == AppleConfigurationSnapshot.publicAddress(session.baseURL)
    }

    func revalidateSavedMediaServerSessions(client: AppleMediaServerClient = AppleMediaServerClient(),
                                             plexClient: ApplePlexClient = ApplePlexClient()) async {
        for id in mediaServerSessionsNeedingValidation {
            guard let source = sources.first(where: { $0.id == id }) else {
                mediaServerSessionsNeedingValidation.remove(id)
                continue
            }
            do {
                guard let session = try await savedMediaServerSession(for: source) else { continue }
                try await client.validateSession(session, plexClient: plexClient)
                guard let index = sources.firstIndex(where: { $0.id == id }),
                      sources[index].configurationRevision == source.configurationRevision else { continue }
                var validated = sources[index]
                validated.url = session.baseURL
                validated.serverKind = session.kind
                validated.mediaServerIdentity = Self.mediaServerIdentity(for: session)
                validated.connection = .init(session: session)
                validated.configurationRevision = nextConfigurationRevision(source.configurationRevision)
                sources[index] = try securedTransportSource(validated)
                mediaServerSessionsNeedingValidation.remove(id)
                persist()
                appleTrace("source session: saved token revalidated")
            } catch {
                appleTraceFailure("source session: revalidation failed; keeping saved token (\(appleErrorLabel(error)))")
            }
        }
    }

    func enableMediaServer(id: AppleSource.ID, client: AppleMediaServerClient = AppleMediaServerClient(),
                           plexClient: ApplePlexClient = ApplePlexClient()) async throws {
        guard let source = sources.first(where: { $0.id == id }), source.kind == .mediaServer else {
            throw AppleMediaServerError.configurationChanged
        }
        do {
            guard let session = try await savedMediaServerSession(for: source) else {
                throw AppleMediaServerError.invalidCredentials
            }
            try Task.checkCancellation()
            try await client.validateSession(session, plexClient: plexClient)
            try Task.checkCancellation()
            guard let index = sources.firstIndex(where: { $0.id == id }),
                  sources[index].configurationRevision == source.configurationRevision else {
                throw AppleMediaServerError.configurationChanged
            }
            var enabledSource = sources[index]
            enabledSource.url = session.baseURL
            enabledSource.serverKind = session.kind
            enabledSource.mediaServerIdentity = Self.mediaServerIdentity(for: session)
            enabledSource.connection = .init(session: session)
            enabledSource.credentialReference = source.credentialReference ?? Self.mediaServerCredentialReference(for: id)
            enabledSource.needsSignIn = false
            enabledSource.needsSourceAddress = false
            enabledSource.isEnabled = true
            enabledSource.configurationRevision = nextConfigurationRevision(source.configurationRevision)
            sources[index] = try securedTransportSource(enabledSource)
            persist()
        } catch AppleMediaServerError.invalidCredentials {
            try Task.checkCancellation()
            guard let index = sources.firstIndex(where: { $0.id == id }),
                  sources[index].configurationRevision == source.configurationRevision else {
                throw AppleMediaServerError.configurationChanged
            }
            let refreshedFromCloud = await refreshCloudSessionAfterUnauthorized?(id) == true
            try Task.checkCancellation()
            if refreshedFromCloud {
                guard let refreshed = sources.firstIndex(where: { $0.id == id }) else {
                    throw AppleMediaServerError.configurationChanged
                }
                sources[refreshed].isEnabled = true
                sources[refreshed].configurationRevision = nextConfigurationRevision(sources[refreshed].configurationRevision)
                persist()
                return
            }
            guard let current = sources.firstIndex(where: { $0.id == id }),
                  sources[current].configurationRevision == source.configurationRevision else {
                throw AppleMediaServerError.configurationChanged
            }
            sources[current].needsSignIn = true
            sources[current].isEnabled = false
            sources[current].credentialReference = source.credentialReference ?? Self.mediaServerCredentialReference(for: id)
            sources[current].configurationRevision = nextConfigurationRevision(source.configurationRevision)
            persist()
            queueMediaServerSessionMutation(source: sources[current], deleted: true)
            throw AppleMediaServerError.invalidCredentials
        }
    }

    private func updateMediaServerCredentials(reference: String, session: AppleMediaServerSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AppleKeychainStoreError.invalidData
        }
        try keychain.set(value, for: reference)
        credentialError = nil
    }

    public func signOutMediaServer(id: UUID) throws {
        guard let source = sources.first(where: { $0.id == id && $0.kind == .mediaServer }) else { return }
        queueMediaServerSessionMutation(source: source, deleted: true)
        try clearCloudMediaServerSession(id: id)
    }

    func clearCloudMediaServerSession(id: UUID) throws {
        guard let index = sources.firstIndex(where: { $0.id == id && $0.kind == .mediaServer }) else { return }
        let stableReference = Self.mediaServerCredentialReference(for: id)
        let reference = sources[index].credentialReference ?? stableReference
        let references: Set<String> = reference.hasPrefix("cloud-session.")
            ? [reference] : [reference, stableReference, "cloud-session.\(stableReference)"]
        sources[index].credentialReference = reference
        sources[index].url = AppleConfigurationSnapshot.publicAddress(sources[index].url)
        sources[index].epgURL = nil
        sources[index].needsSignIn = true
        sources[index].needsSourceAddress = true
        sources[index].isEnabled = false
        sources[index].configurationRevision = nextConfigurationRevision(sources[index].configurationRevision)
        persist()
        try removeCloudCredentialReferences(references)
    }

    private func removeCloudCredentialReferences(_ references: Set<String>) throws {
        do {
            for reference in references {
                try keychain.remove(reference)
                try localMediaServerKeychain.remove(reference)
            }
        } catch {
            pendingCredentialCleanupReferences = Array(Set(pendingCredentialCleanupReferences).union(references)).sorted()
            persistPendingCredentialCleanup()
            throw error
        }
    }

    func installCloudMediaServerSession(_ session: AppleMediaServerSession, for source: AppleSource,
                                        enabled: Bool = true, validatedAt: Date = .now) throws {
        guard let index = sources.firstIndex(where: { $0.id == source.id }),
              sources[index].configurationRevision == source.configurationRevision,
              Self.mediaServerSession(session, matches: sources[index]) else { throw AppleMediaServerError.configurationChanged }
        let reference = "cloud-session.\(Self.mediaServerCredentialReference(for: source.id))"
        let previous = try localMediaServerKeychain.string(for: reference)
        do {
            try localMediaServerKeychain.set(String(decoding: JSONEncoder().encode(session), as: UTF8.self), for: reference)
            var restored = sources[index]
            restored.url = session.baseURL
            restored.credentialReference = reference
            restored.serverKind = session.kind
            restored.mediaServerIdentity = Self.mediaServerIdentity(for: session)
            restored.isEnabled = enabled
            restored.isEnabledAfterSignIn = nil
            restored.needsSignIn = false
            restored.needsSourceAddress = false
            restored.lastValidatedAt = validatedAt
            restored.configurationRevision = nextConfigurationRevision(restored.configurationRevision)
            sources[index] = try securedTransportSource(restored)
            persist()
        } catch {
            do {
                if let previous { try localMediaServerKeychain.set(previous, for: reference) }
                else { try localMediaServerKeychain.remove(reference) }
            } catch { appleTrace("media server sign-in sync: local credential rollback failed") }
            throw error
        }
    }

    func cloudSourceCredentials(for source: AppleSource) throws -> AppleCloudMediaServerSession? {
        guard source.kind != .library, !source.needsSignIn, !source.needsSourceAddress,
              !AppleLocalPlaylistStore.isLocal(source.url) else { return nil }
        let validatedAt = mediaServerSessionMutations[source.id]?.deleted == false ? Date.now : source.lastValidatedAt ?? source.addedAt
        if source.kind == .mediaServer {
            guard let session = try mediaServerSession(for: source) else { return nil }
            return AppleCloudMediaServerSession(sourceID: source.id, session: session,
                validatedAt: validatedAt, isEnabled: source.isEnabled)
        }
        let credential = try source.usesGuestAccess ? nil : source.credentialReference.flatMap {
            try keychain.string(for: $0) ?? localMediaServerKeychain.string(for: $0)
        }
        let record = AppleCloudMediaServerSession(source: source, credential: credential, validatedAt: validatedAt)
        try record.validate()
        return record
    }

    func installCloudSourceCredentials(_ entry: AppleCloudMediaServerSession, for source: AppleSource) throws {
        try entry.validate()
        guard entry.matches(source), let index = sources.firstIndex(where: { $0.id == source.id }),
              sources[index].configurationRevision == source.configurationRevision else {
            throw AppleMediaServerError.configurationChanged
        }
        if let session = entry.session {
            try installCloudMediaServerSession(session, for: source, enabled: entry.isEnabled, validatedAt: entry.validatedAt)
            return
        }
        let reference = "cloud-session.\(source.id.uuidString.lowercased())"
        // Keep pulled secrets in the non-synchronizing local service on every platform.
        let values: [(String, String?)] = [(reference, entry.credential),
            ("cloud-transport.\(source.id.uuidString.lowercased())", entry.sourceURL.absoluteString),
            ("cloud-guide.\(source.id.uuidString.lowercased())", entry.guideURL?.absoluteString)]
        let previous = try values.map { ($0.0, try localMediaServerKeychain.string(for: $0.0)) }
        do {
            for (key, value) in values {
                if let value { try localMediaServerKeychain.set(value, for: key) }
                else { try localMediaServerKeychain.remove(key) }
            }
        } catch {
            for (key, value) in previous {
                do {
                    if let value { try localMediaServerKeychain.set(value, for: key) }
                    else { try localMediaServerKeychain.remove(key) }
                } catch { appleTrace("source sign-in sync: local credential rollback failed") }
            }
            throw error
        }
        var restored = sources[index]
        restored.isEnabled = entry.isEnabled
        restored.isEnabledAfterSignIn = nil
        if entry.kind == .nas {
            if let credential = entry.credential {
                restored.connection = .init(credentials: try JSONDecoder().decode(AppleSMBCredentials.self, from: Data(credential.utf8)))
            } else { restored.connection = .init(username: "", domain: "", requiresCredentials: false) }
        } else if entry.iptvType == .xtream, let credential = entry.credential {
            restored.connection = .init(username: try JSONDecoder().decode(AppleIPTVCredentials.self, from: Data(credential.utf8)).username)
        }
        restored.url = entry.sourceURL
        restored.epgURL = entry.guideURL
        restored.credentialReference = entry.credential == nil ? nil : reference
        restored.usesGuestAccess = entry.kind == .nas && entry.credential == nil
        restored.transportReference = "cloud-transport.\(source.id.uuidString.lowercased())"
        restored.needsSignIn = false
        restored.needsSourceAddress = false
        restored.lastValidatedAt = entry.validatedAt
        restored.configurationRevision = nextConfigurationRevision(source.configurationRevision)
        sources[index] = restored
        persist()
    }

    func clearCloudSourceCredentials(id: UUID) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        if sources[index].kind == .mediaServer { try clearCloudMediaServerSession(id: id); return }
        let source = sources[index]
        let suffix = id.uuidString.lowercased()
        let references: Set<String> = ["cloud-session.\(suffix)", "cloud-transport.\(suffix)", "cloud-guide.\(suffix)"]
        sources[index].url = AppleConfigurationSnapshot.publicAddress(source.url)
        sources[index].epgURL = nil
        sources[index].credentialReference = nil
        sources[index].transportReference = nil
        sources[index].needsSignIn = source.credentialReference != nil
        sources[index].needsSourceAddress = true
        sources[index].isEnabled = false
        sources[index].configurationRevision = nextConfigurationRevision(source.configurationRevision)
        persist()
        try removeCloudCredentialReferences(references)
    }

    func didRestoreCloudCredentials() {
        credentialsRestoreRevision += 1
    }

    private func normalizeRestoredSourceAvailability() {
        var changed = false
        for index in sources.indices {
            if sources[index].kind == .nas {
                if let credential = try? networkCredentials(for: sources[index]),
                   credential.username.isEmpty, credential.password.isEmpty, credential.domain.isEmpty {
                    if !sources[index].usesGuestAccess { sources[index].usesGuestAccess = true; changed = true }
                    if sources[index].needsSignIn { sources[index].needsSignIn = false; changed = true }
                }
                if (try? AppleSMBEndpointPolicy.parts(from: sources[index].url)) == nil {
                    sources[index].needsSourceAddress = true
                }
            }
            if sources[index].needsSignIn || sources[index].needsSourceAddress, sources[index].isEnabled {
                sources[index].isEnabled = false
                changed = true
            }
        }
        if changed { persist() }
    }

    private func queueMediaServerSessionMutation(source: AppleSource, deleted: Bool) {
        mediaServerSessionMutations[source.id] = AppleMediaServerSessionMutation(
            revision: UUID(), deleted: deleted, identity: source.mediaServerIdentity ?? "\(source.kind.rawValue):\(source.id.uuidString.lowercased())")
        persistMediaServerSessionMutations()
        mediaServerSessionDidChange?()
    }

    func completeMediaServerSessionMutation(id: UUID, revision: UUID) {
        guard mediaServerSessionMutations[id]?.revision == revision else { return }
        mediaServerSessionMutations[id] = nil
        persistMediaServerSessionMutations()
    }

    private func persistMediaServerSessionMutations() {
        do { defaults.set(try JSONEncoder().encode(mediaServerSessionMutations), forKey: storageKey + ".session-mutations") }
        catch { appleTrace("media server sign-in sync: could not save pending session change") }
    }

    private func boundedStatus(_ value: String) -> String? {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyAppleSourceString
            .map(AppleDiagnosticRedactor.redact)
            .map { String($0.prefix(200)) }
    }

    private func boundedCapabilities(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value
                .components(separatedBy: .controlCharacters)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let bounded = String(clean.prefix(40))
            guard seen.insert(bounded.lowercased()).inserted else { return nil }
            return bounded
        }.prefix(16).map { $0 }
    }

    private func nextConfigurationRevision(_ current: Int) -> Int {
        current == .max ? 1 : max(current + 1, 1)
    }

    private func migrateLegacyIPTVCredentials() {
        var didMigrate = false
        for index in sources.indices {
            guard sources[index].kind == .liveTV,
                  sources[index].iptvType == .xtream,
                  let username = sources[index].legacyUsername,
                  !username.isEmpty,
                  let password = sources[index].legacyPassword,
                  !password.isEmpty else { continue }
            let reference = sources[index].credentialReference
                ?? sources[index].id.uuidString.lowercased()
            do {
                try updateIPTVCredentials(
                    type: .xtream,
                    reference: reference,
                    username: username,
                    password: password
                )
                sources[index].credentialReference = reference
                sources[index].legacyUsername = nil
                sources[index].legacyPassword = nil
                didMigrate = true
            } catch {
                credentialError = error.localizedDescription
            }
        }
        if didMigrate { persist() }
    }

    private func relocateManagedImports() {
        var changed = false
        for index in sources.indices where sources[index].kind == .library {
            let source = sources[index]
            let parts = source.url.standardizedFileURL.pathComponents
            // Older portal imports had no bookmark or ownership marker. Only
            // recognize the app-container Documents/Imports layout, never an
            // arbitrary external folder named Imports or a granted bookmark.
            let legacyImports = source.bookmarkData == nil && source.url.isFileURL
                && parts.count >= 7
                && Array(parts.suffix(6).prefix(3)) == ["Containers", "Data", "Application"]
                && UUID(uuidString: parts[parts.count - 3]) != nil
                && Array(parts.suffix(2)) == ["Documents", "Imports"]
            guard source.isManagedImports || legacyImports else { continue }
            guard source.url != managedImportsDirectory || !source.isManagedImports || source.bookmarkData != nil else { continue }
            sources[index].url = managedImportsDirectory
            sources[index].isManagedImports = true
            sources[index].bookmarkData = nil
            sources[index].configurationRevision = nextConfigurationRevision(source.configurationRevision)
            changed = true
        }
        if changed { persist() }
    }

    /// Drops retired sources from the stored list, queues their Keychain
    /// entries for removal and tombstones their ids, so a device on an older
    /// build deletes them too instead of sending them back through iCloud.
    private func deleteRetiredSources(_ retired: [AppleRetiredSource]) {
        pendingCredentialCleanupReferences = Array(Set(pendingCredentialCleanupReferences
            + retired.flatMap(\.keychainReferences))).sorted()
        retryPendingCredentialCleanup()
        for source in retired where sourceTombstones[source.id] == nil { sourceTombstones[source.id] = .now }
        persist()
        appleTrace("sources: deleted \(retired.count) retired")
    }

    func mergeSourceTombstones(_ incoming: [UUID: Date]) {
        let combined = sourceTombstones.merging(incoming) { max($0, $1) }
        for id in combined.keys where sources.contains(where: { $0.id == id }) { _ = remove(id: id) }
        sourceTombstones = combined
        persist()
    }

    func configurationSecrets() throws -> AppleConfigurationSecrets {
        var result = AppleConfigurationSecrets()
        for source in sources {
            if let reference = source.credentialReference {
                result.sourceCredentials[source.id] = try keychain.string(for: reference)
                    ?? localMediaServerKeychain.string(for: reference)
            }
            if !source.needsSignIn && !source.needsSourceAddress {
                result.sourceAddresses[source.id] = source.url
                result.guideAddresses[source.id] = source.epgURL
            }
        }
        return result
    }

    /// Restores `incoming` over (or, without `merge`, instead of) this
    /// device's sources. A source whose sign-in or address this device's
    /// keychain will not keep is not fatal: it keeps this device's copy when
    /// there is one, else arrives signed out for the viewer to sign in again.
    /// Returns how many sources that happened to.
    @discardableResult
    func restoreConfigurationSources(_ incoming: [AppleSource], secrets: AppleConfigurationSecrets?, merge: Bool = true) throws -> Int {
        var merged = merge ? sources : []
        var signedOut = 0
        for incomingSource in incoming where sourceTombstones[incomingSource.id] == nil {
            var portable = incomingSource
            if portable.kind == .mediaServer, portable.mediaServerIdentity == nil {
                do {
                    var accountSource = AppleConfigurationSnapshot.portableSource(portable)
                    accountSource.needsSignIn = true
                    if let value = try secrets?.sourceCredentials[portable.id]
                        ?? keychain.string(for: Self.mediaServerCredentialReference(for: portable.id)),
                       let session = try? JSONDecoder().decode(AppleMediaServerSession.self, from: Data(value.utf8)),
                       Self.mediaServerSession(session, matches: accountSource) {
                        portable.mediaServerIdentity = Self.mediaServerIdentity(for: session)
                    }
                } catch {
                    appleTraceFailure("source restore: legacy account unavailable (\(appleErrorLabel(error)))")
                }
            }
            let restored: AppleSource
            let sameID = merged.first { $0.id == portable.id } ?? sources.first { $0.id == portable.id }
            let mergedIDs = Set(merged.map(\.id))
            let candidates = merged + sources.filter { !mergedIDs.contains($0.id) }
            let sameAccount = Self.matchingConfigurationMediaServer(portable, in: candidates)
            let conflictingID = sameID?.mediaServerIdentity != nil && portable.mediaServerIdentity != nil
                && sameID?.mediaServerIdentity != portable.mediaServerIdentity
            let existing = conflictingID ? sameID
                : sameID?.isEnabled != true && sameAccount?.isEnabled == true ? sameAccount : sameID ?? sameAccount
            do {
                restored = try restoredConfigurationSource(portable, existing: existing, secrets: secrets)
            } catch {
                signedOut += 1
                appleTraceFailure("source restore: \(portable.kind.rawValue) kept signed out: \(appleErrorLabel(error))")
                if let existing {
                    restored = existing
                } else {
                    var fallback = AppleConfigurationSnapshot.portableSource(portable)
                    fallback.credentialReference = nil
                    fallback.transportReference = nil
                    fallback.needsSignIn = true
                    fallback.isEnabled = false
                    restored = fallback
                }
            }
            if restored.id != portable.id {
                sourceTombstones[portable.id] = .now
                merged.removeAll { $0.id == portable.id }
            }
            if let index = merged.firstIndex(where: { $0.id == restored.id }) { merged[index] = restored }
            else { merged.append(restored) }
        }
        var unique: [AppleSource] = []
        for source in merged {
            if let index = unique.firstIndex(where: { $0.id == source.id || Self.sameMediaServerAccount($0, source) }) {
                let previous = unique[index]
                let preferred = source.isEnabled && !source.needsSignIn && (!previous.isEnabled || previous.needsSignIn) ? source : previous
                let removed = preferred.id == source.id ? previous : source
                unique[index] = preferred
                if removed.id != preferred.id { sourceTombstones[removed.id] = .now }
            } else { unique.append(source) }
        }
        sources = unique.map { source in
            var restored = source
            if restored.kind == .nas, (try? AppleSMBEndpointPolicy.parts(from: restored.url)) == nil {
                restored.needsSourceAddress = true
            }
            if restored.needsSignIn || restored.needsSourceAddress { restored.isEnabled = false }
            return restored
        }
        persist()
        if secrets != nil {
            let incomingIDs = Set(incoming.map(\.id))
            for source in sources where source.kind != .library && !source.needsSignIn && incomingIDs.contains(source.id) {
                queueMediaServerSessionMutation(source: source, deleted: false)
            }
        }
        return signedOut
    }

    private func restoredConfigurationSource(_ portable: AppleSource, existing: AppleSource?,
                                             secrets: AppleConfigurationSecrets?) throws -> AppleSource {
        if portable.kind == .mediaServer {
            return try restoredConfigurationMediaServer(portable, existing: existing, secrets: secrets)
        }
        var restored = AppleConfigurationSnapshot.portableSource(portable)
        let compatible = existing.flatMap { source in
            source.kind == restored.kind
                && (source.transportReference?.hasPrefix("cloud-transport.") == true
                    || AppleConfigurationSnapshot.publicAddress(source.url) == AppleConfigurationSnapshot.publicAddress(restored.url)
                    || restored.url == AppleConfigurationSnapshot.unavailableSourceURL) ? source : nil
        }
        let keepsEncryptedAddress = compatible?.transportReference?.hasPrefix("cloud-transport.") == true
        if let existing = compatible {
            restored.bookmarkData = existing.bookmarkData
            restored.credentialReference = existing.credentialReference
            restored.transportReference = existing.transportReference
            restored.url = existing.url
            restored.epgURL = existing.epgURL
            restored.needsSignIn = existing.needsSignIn
            restored.needsSourceAddress = existing.needsSourceAddress
            restored.usesGuestAccess = existing.usesGuestAccess
            restored.isEnabled = portable.needsSignIn || portable.needsSourceAddress ? existing.isEnabled : portable.isEnabled
        }
        restored.connection = keepsEncryptedAddress
            ? compatible?.connection?.fillingMissingFields(from: portable.connection) ?? portable.connection
            : portable.connection?.fillingMissingFields(from: compatible?.connection) ?? compatible?.connection
        if let value = secrets?.sourceCredentials[restored.id] {
            let reference = restored.id.uuidString.lowercased()
            try keychain.set(value, for: reference)
            restored.credentialReference = reference
            if restored.kind == .nas {
                let credentials = try JSONDecoder().decode(AppleSMBCredentials.self, from: Data(value.utf8))
                restored.connection = .init(credentials: credentials)
                restored.usesGuestAccess = credentials.username.isEmpty && credentials.password.isEmpty
            }
        } else if !keepsEncryptedAddress,
                  AppleConfigurationSyncPolicy.receivesICloudKeychain(mode: AppleConfigurationSyncPolicy.current),
                  AppleConfigurationSyncPolicy.isEnabled(storedPreference: AppleConfigurationSyncPolicy.storedPreference()),
                  restored.kind != .library {
            // Stable accounts reconnect independently arriving iCloud Keychain items.
            let reference = restored.id.uuidString.lowercased()
            if try keychain.string(for: reference) != nil { restored.credentialReference = reference }
            let transport = "transport.\(reference)"
            if let address = try keychain.string(for: transport), let url = URL(string: address) {
                restored.url = url
                restored.transportReference = transport
                restored.epgURL = try keychain.string(for: "guide.\(reference)").flatMap(URL.init(string:))
                if compatible?.needsSignIn != true
                    || compatible?.credentialReference == nil && compatible?.transportReference == nil {
                    restored.needsSignIn = false
                    restored.needsSourceAddress = false
                    restored.isEnabled = restored.isEnabledAfterSignIn ?? restored.isEnabled
                }
            }
        }
        // Legacy snapshots carried only an origin, with no way to reconnect its path.
        let isLegacyOrigin = portable.connection == nil && portable.needsSignIn
            && portable.url == AppleConfigurationSnapshot.publicAddress(portable.url)
        let keepsPrivateAddress = compatible.map {
            !$0.needsSourceAddress && AppleSourceConnectionConfiguration.publicURL($0.url) == nil
        } ?? false
        if !keepsEncryptedAddress, !keepsPrivateAddress,
           let address = AppleSourceConnectionConfiguration.publicURL(portable.url), !isLegacyOrigin || compatible == nil {
            restored.url = address
            restored.epgURL = portable.epgURL.flatMap(AppleSourceConnectionConfiguration.publicURL) ?? compatible?.epgURL
        }
        if let address = secrets?.sourceAddresses[restored.id] {
            restored.url = address
            restored.epgURL = secrets?.guideAddresses[restored.id]
            restored.needsSignIn = false
            restored.needsSourceAddress = false
            restored.isEnabled = portable.isEnabledAfterSignIn
                ?? (portable.isEnabled || portable.needsSignIn || portable.needsSourceAddress)
        }
        if restored.kind == .library || AppleLocalPlaylistStore.isLocal(restored.url) {
            restored.needsSignIn = compatible == nil || compatible?.needsSignIn == true
        }
        let isGuestShare = restored.kind == .nas && (restored.usesGuestAccess || restored.connection?.requiresCredentials == false)
        if restored.iptvType == .xtream || restored.kind == .nas && !isGuestShare,
           restored.credentialReference == nil {
            restored.needsSignIn = true
        }
        if restored.kind == .nas, (try? AppleSMBEndpointPolicy.parts(from: restored.url)) == nil {
            restored.needsSourceAddress = true
            restored.needsSignIn = true
        }
        if restored.needsSignIn || restored.needsSourceAddress { restored.isEnabled = false }
        else {
            restored.isEnabledAfterSignIn = nil
            restored = try securedTransportSource(restored)
        }
        if let existing, existing.url != restored.url || existing.isEnabled != restored.isEnabled
            || existing.credentialReference != restored.credentialReference || existing.connection != restored.connection {
            restored.configurationRevision = nextConfigurationRevision(max(existing.configurationRevision, restored.configurationRevision))
        }
        return restored
    }

    nonisolated static func matchingConfigurationMediaServer(_ portable: AppleSource, in candidates: [AppleSource]) -> AppleSource? {
        guard portable.kind == .mediaServer else { return nil }
        // A server address alone cannot establish which user an older snapshot belongs to.
        let matches = candidates.filter { sameMediaServerAccount($0, portable) }
        return matches.first { $0.isEnabled && !$0.needsSignIn } ?? matches.first
    }

    private func restoredConfigurationMediaServer(_ portable: AppleSource, existing: AppleSource?,
                                                  secrets: AppleConfigurationSecrets?) throws -> AppleSource {
        if let existing, existing.id == portable.id, let identity = existing.mediaServerIdentity,
           let incomingIdentity = portable.mediaServerIdentity, identity != incomingIdentity {
            appleTrace("source restore: account changed under the same ID; keeping local credentials")
            return existing
        }
        let localSource = existing.flatMap { $0.id == portable.id || Self.sameMediaServerAccount($0, portable) ? $0 : nil }
        if let localSource, !localSource.needsSignIn, let session = try mediaServerSession(for: localSource) {
            var restored = localSource
            restored.name = portable.name
            restored.connection = portable.connection?.fillingMissingFields(from: localSource.connection) ?? localSource.connection
            if Self.mediaServerSession(session, matches: localSource) {
                restored.mediaServerIdentity = Self.mediaServerIdentity(for: session)
            }
            restored.configurationRevision = max(localSource.configurationRevision, portable.configurationRevision)
            if restored.name != localSource.name || restored.connection != localSource.connection {
                restored.configurationRevision = nextConfigurationRevision(restored.configurationRevision)
            }
            return restored
        }
        var restored = localSource ?? AppleConfigurationSnapshot.portableSource(portable)
        restored.name = portable.name
        restored.connection = portable.connection?.fillingMissingFields(from: localSource?.connection) ?? localSource?.connection
        restored.url = localSource?.url ?? AppleConfigurationSnapshot.portableSource(portable).url
        restored.mediaServerIdentity = portable.mediaServerIdentity
        restored.transportReference = localSource?.transportReference
        let reference = localSource?.credentialReference ?? Self.mediaServerCredentialReference(for: restored.id)
        let importedCredential = secrets?.sourceCredentials[portable.id]
        restored.credentialReference = reference
        restored.isEnabled = false
        restored.needsSignIn = true
        let credential = try importedCredential ?? keychain.string(for: reference)
        if let credential {
            let session = try JSONDecoder().decode(AppleMediaServerSession.self, from: Data(credential.utf8))
            guard Self.mediaServerSession(session, matches: restored) else { throw AppleMediaServerError.invalidCredentials }
            restored.url = session.baseURL
            restored.serverKind = session.kind
            restored.mediaServerIdentity = Self.mediaServerIdentity(for: session)
            restored.connection = restored.connection?.fillingMissingFields(from: .init(session: session)) ?? .init(session: session)
            restored.needsSignIn = importedCredential == nil && existing?.needsSignIn == true && existing?.credentialReference != nil
            if !restored.needsSignIn {
                let previousCredential = try keychain.string(for: reference)
                do {
                    if let importedCredential { try keychain.set(importedCredential, for: reference) }
                } catch {
                    do {
                        if let previousCredential { try keychain.set(previousCredential, for: reference) }
                        else { try keychain.remove(reference) }
                    } catch {
                        if previousCredential == nil {
                            pendingCredentialCleanupReferences.append(reference)
                            persistPendingCredentialCleanup()
                        }
                        appleTraceFailure("source restore: credential rollback failed (\(appleErrorLabel(error)))")
                    }
                    throw error
                }
            }
        } else {
            restored.credentialReference = nil
        }
        if let existing { restored.configurationRevision = nextConfigurationRevision(max(existing.configurationRevision, portable.configurationRevision)) }
        return restored
    }

    private func hydrateMediaServerIdentities() {
        var changed = false
        for index in sources.indices where sources[index].kind == .mediaServer {
            do {
                guard let session = try mediaServerSession(for: sources[index]) else { continue }
                if sources[index].mediaServerIdentity == nil, Self.mediaServerSession(session, matches: sources[index]) {
                    sources[index].mediaServerIdentity = Self.mediaServerIdentity(for: session)
                    changed = true
                }
            } catch {
                appleTraceFailure("source identity: saved session unavailable (\(appleErrorLabel(error)))")
            }
        }
        if changed { persist() }
    }

    private func hydrateConnectionConfigurations() {
        var changed = false
        for index in sources.indices where sources[index].connection == nil && sources[index].kind != .library
            && !sources[index].url.isFileURL && !AppleLocalPlaylistStore.isLocal(sources[index].url) {
            let source = sources[index]
            var connection = AppleSourceConnectionConfiguration()
            do {
                switch source.kind {
                case .nas:
                    if let credentials = try networkCredentials(for: source) { connection = .init(credentials: credentials) }
                case .mediaServer:
                    if let session = try mediaServerSession(for: source) { connection = .init(session: session) }
                case .liveTV:
                    connection.username = try iptvCredentials(for: source)?.username
                case .library:
                    break
                }
            } catch {
                appleTraceFailure("source connection: saved account unavailable (\(appleErrorLabel(error)))")
                continue
            }
            sources[index].connection = connection
            changed = true
        }
        if changed { persist() }
    }

    func reconnectConfigurationFolder(id: UUID, url: URL, bookmark: Data?) {
        guard let index = sources.firstIndex(where: { $0.id == id }), sources[index].kind == .library else { return }
        sources[index].url = url
        sources[index].bookmarkData = bookmark
        sources[index].isManagedImports = false
        sources[index].needsSignIn = false
        sources[index].needsSourceAddress = false
        sources[index].isEnabled = true
        persist()
    }

    func prepareConfigurationKeychain() throws {
        for source in sources where !source.needsSignIn && !source.needsSourceAddress && source.kind != .library
            && source.transportReference?.hasPrefix("cloud-transport.") != true
            && source.credentialReference?.hasPrefix("cloud-session.") != true && !AppleLocalPlaylistStore.isLocal(source.url) {
            let id = source.id.uuidString.lowercased()
            try keychain.set(source.url.absoluteString, for: "transport.\(id)")
            if let guide = source.epgURL { try keychain.set(guide.absoluteString, for: "guide.\(id)") }
            if let reference = source.credentialReference, reference != id,
               let credential = try keychain.string(for: reference) {
                try keychain.set(credential, for: id)
            }
        }
    }

    func refreshConfigurationKeychain() throws {
        let pending = sources.filter { ($0.needsSignIn || $0.needsSourceAddress) && $0.kind != .library }
        guard !pending.isEmpty else { return }
        try restoreConfigurationSources(pending, secrets: nil)
    }

    func restoreSourceSignIn(id: UUID, address: URL, username: String, password: String) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var source = sources[index]
        guard source.kind != .mediaServer else { throw AppleMediaServerError.unsupported }
        let reference = id.uuidString.lowercased()
        if source.kind == .liveTV, source.iptvType == .xtream {
            try updateIPTVCredentials(type: .xtream, reference: reference, username: username, password: password)
            source.credentialReference = reference
        } else if source.kind == .nas {
            _ = try AppleSMBEndpointPolicy.parts(from: address)
            try updateNetworkCredentials(.init(username: username, password: password, domain: source.connection?.domain ?? ""),
                                         reference: reference)
            source.credentialReference = reference
            source.usesGuestAccess = username.isEmpty && password.isEmpty
        }
        source.url = address
        source.connection = .init(username: username, domain: source.connection?.domain,
                                  requiresCredentials: source.kind == .nas ? !username.isEmpty || !password.isEmpty : nil)
        source.needsSignIn = false
        source.needsSourceAddress = false
        source.isEnabled = true
        sources[index] = try securedTransportSource(source)
        persist()
        queueMediaServerSessionMutation(source: sources[index], deleted: false)
    }

    private func securedTransportSource(_ source: AppleSource) throws -> AppleSource {
        guard Self.protectsTransportURL(source) else { return source }
        var secured = source
        let reference = source.transportReference ?? "transport.\(source.id.uuidString.lowercased())"
        if reference.hasPrefix("cloud-transport.") { try localMediaServerKeychain.set(source.url.absoluteString, for: reference) }
        else { try keychain.set(source.url.absoluteString, for: reference) }
        secured.transportReference = reference
        return secured
    }

    private func hydrateProtectedTransportURLs() {
        var migrated = false
        for index in sources.indices where Self.protectsTransportURL(sources[index]) && !sources[index].needsSignIn && !sources[index].needsSourceAddress {
            if let reference = sources[index].transportReference {
                do {
                    guard let stored = try keychain.string(for: reference) ?? localMediaServerKeychain.string(for: reference),
                          let url = URL(string: stored),
                          url.scheme != nil else {
                        credentialError = "A saved source address is unavailable. Re-add that source."
                        sources[index].needsSourceAddress = true
                        sources[index].isEnabled = false
                        continue
                    }
                    sources[index].url = url
                } catch {
                    credentialError = error.localizedDescription
                }
                continue
            }
            do {
                sources[index] = try securedTransportSource(sources[index])
                migrated = true
            } catch {
                credentialError = error.localizedDescription
            }
        }
        if migrated { persist() }
    }

    /// The guide (EPG) address can carry the provider password in its query,
    /// so it lives in the Keychain under `guide.<id>`, never in the defaults
    /// blob. Older blobs that still hold it are rewritten without it.
    private func hydrateGuideAddresses() {
        var storedInBlob = false
        for index in sources.indices where Self.protectsTransportURL(sources[index]) {
            if sources[index].epgURL != nil {
                storedInBlob = true
                continue
            }
            do {
                let imported = sources[index].transportReference?.hasPrefix("cloud-transport.") == true
                let guideStore = imported ? localMediaServerKeychain : keychain
                let reference = imported ? "cloud-guide.\(sources[index].id.uuidString.lowercased())" : Self.guideReference(sources[index].id)
                sources[index].epgURL = try guideStore.string(for: reference).flatMap(URL.init(string:))
            } catch {
                credentialError = error.localizedDescription
            }
        }
        if storedInBlob { persist() }
    }

    static func guideReference(_ id: UUID) -> String {
        "guide.\(id.uuidString.lowercased())"
    }

    private func retryPendingCredentialCleanup() {
        guard !pendingCredentialCleanupReferences.isEmpty else { return }
        let activeReferences = Set(sources.filter { !$0.needsSignIn }.flatMap { source in
            [source.credentialReference, source.transportReference].compactMap { $0 }
        })
        var failed: [String] = []
        for reference in pendingCredentialCleanupReferences {
            guard !activeReferences.contains(reference) else {
                failed.append(reference)
                continue
            }
            do {
                try keychain.remove(reference)
                try localMediaServerKeychain.remove(reference)
            } catch {
                failed.append(reference)
                credentialError = error.localizedDescription
            }
        }
        pendingCredentialCleanupReferences = failed
        persistPendingCredentialCleanup()
        if failed.isEmpty { credentialError = nil }
    }

    private func persistPendingCredentialCleanup() {
        let key = storageKey + ".pending-keychain-removals"
        if pendingCredentialCleanupReferences.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(pendingCredentialCleanupReferences, forKey: key)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sourceTombstones) { defaults.set(data, forKey: storageKey + ".tombstones") }
        // Each of these refusals is correct — they protect a stored list from
        // being replaced by an empty or credential-leaking one — but they are
        // also indistinguishable from a successful save until the next launch
        // shows the source gone. Say which one fired.
        guard !(protectsStoredBlobWhenEmpty && sources.isEmpty) else {
            appleTraceFailure("sources not saved: refusing to overwrite the stored list with an empty one")
            return
        }
        guard !sources.contains(where: { $0.legacyUsername != nil || $0.legacyPassword != nil }) else {
            appleTraceFailure("sources not saved: a source still holds legacy inline credentials")
            return
        }
        guard !sources.contains(where: {
            Self.protectsTransportURL($0) && !$0.needsSignIn && !$0.needsSourceAddress && $0.transportReference == nil
        }) else {
            appleTraceFailure("sources not saved: a protected source has no transport reference")
            return
        }
        for source in sources where Self.protectsTransportURL(source) {
            guard let guide = source.epgURL?.absoluteString else { continue }
            let imported = source.transportReference?.hasPrefix("cloud-transport.") == true
            let reference = imported ? "cloud-guide.\(source.id.uuidString.lowercased())" : Self.guideReference(source.id)
            let guideStore = imported ? localMediaServerKeychain : keychain
            do {
                if try guideStore.string(for: reference) != guide { try guideStore.set(guide, for: reference) }
            } catch {
                appleTraceFailure("sources not saved: a guide address could not be stored in the Keychain")
                return
            }
        }
        let persistedSources = sources.map { source -> AppleSource in
            guard Self.protectsTransportURL(source) else { return source }
            var sanitized = source
            sanitized.url = Self.sanitizedTransportURL(source)
            sanitized.epgURL = nil
            return sanitized
        }
        let members: [Any] = persistedSources.compactMap { source in
            guard let data = try? JSONEncoder().encode(source) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: members) else {
            appleTraceFailure("sources not saved: the list could not be encoded")
            return
        }
        defaults.set(encoded, forKey: storageKey)
        protectsStoredBlobWhenEmpty = false
        appleTrace("sources saved: \(sources.count)")
    }

    private static func protectsTransportURL(_ source: AppleSource) -> Bool {
        source.kind == .liveTV
    }

    private static func sanitizedTransportURL(_ source: AppleSource) -> URL {
        guard var components = URLComponents(url: source.url, resolvingAgainstBaseURL: false) else {
            return URL(string: "https://source.invalid/")!
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/"
        return components.url ?? URL(string: "https://source.invalid/")!
    }

    private static func isEmptyStoredList(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "[]"
    }
}

private extension String {
    var nonEmptyAppleSourceString: String? { isEmpty ? nil : self }
}
