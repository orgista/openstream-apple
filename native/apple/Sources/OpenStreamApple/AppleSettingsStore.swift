import Foundation
import Observation
import Security

public enum AppleKeychainStoreError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error \(status)."
        case .invalidData:
            return "The saved credential could not be read."
        }
    }
}

public protocol AppleCredentialStoring {
    func string(for account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String) throws
}

/// Stores credentials in the local data-protection Keychain. ThisDeviceOnly
/// accessibility keeps them out of device backups and iCloud Keychain sync.
public struct AppleKeychainStore: AppleCredentialStoring, Sendable {
    private let service: String

    public init(service: String = "com.orgista.openstream.settings") {
        self.service = service
    }

    public func string(for account: String) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AppleKeychainStoreError.unexpectedStatus(status)
        }
        guard let data = value as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw AppleKeychainStoreError.invalidData
        }
        return string
    }

    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AppleKeychainStoreError.unexpectedStatus(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw AppleKeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

public enum AppleLiveChannelScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case providerLineup
    case regional
    case favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .providerLineup: "Provider Lineup"
        case .regional: "Your Regional"
        case .favorites: "My Channels"
        }
    }
}

public enum AppleLiveChannelPackage: String, Codable, CaseIterable, Identifiable, Sendable {
    case premierGuide
    case everything
    case custom

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .premierGuide: "Premier Guide"
        case .everything: "Everything"
        case .custom: "Custom"
        }
    }
}

public enum AppleZIPCodePolicy {
    public static func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 5, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }

    public static func isValid(_ value: String) -> Bool { normalize(value) != nil }
}

/// Preferred caption behaviour, stored in `AppleSettingsStore.captionsPreference`
/// and surfaced under Settings → Playback → Captions. `.off` shows nothing; the
/// other values auto-select a subtitle track on load when one is available —
/// `.english` and `.deviceLanguage` only when a track's language matches,
/// `.always` for any track. The former "Captions Auto-On" boolean migrates to
/// `.always` (on) / `.off` (off).
public enum AppleCaptionsPreference: String, CaseIterable, Sendable {
    case off
    case english
    case deviceLanguage = "device"
    case always

    /// Languages to hand the engine for post-load auto-selection; empty for
    /// `.off` (no auto-select) and `.always` (any track, selected by id).
    var preferredSubtitleLanguages: [String] {
        switch self {
        case .off: return []
        case .english: return ["eng", "en"]
        case .deviceLanguage:
            return Locale.preferredLanguages.prefix(4).flatMap { language -> [String] in
                // "en-US" → ["eng", "en"]; the engine matches ISO 639-2/1 forms.
                let base = language.split(separator: "-").first.map(String.init) ?? language
                return [base, Self.iso639_2(for: base)].compactMap { $0 }
            }
        case .always: return []
        }
    }

    /// True when a track should be auto-selected on load regardless of language.
    var autoSelectsAnyTrack: Bool { self == .always }

    private static func iso639_2(for code: String) -> String? {
        switch code.lowercased() {
        case "en": return "eng"
        case "es": return "spa"
        case "fr": return "fra"
        case "de": return "deu"
        case "it": return "ita"
        case "pt": return "por"
        case "nl": return "nld"
        case "ru": return "rus"
        case "ja": return "jpn"
        case "ko": return "kor"
        case "zh": return "chi"
        default: return nil
        }
    }
}

@MainActor
@Observable
public final class AppleSettingsStore {
    /// The defaults key behind `autoPlayNextEpisode`, so the transport overlay
    /// can read the setting without being handed a store.
    public static let autoPlayNextEpisodeKey = DefaultsKey.autoPlayNextEpisode

    public var metadataEnabled: Bool {
        didSet { defaults.set(metadataEnabled, forKey: DefaultsKey.metadataEnabled) }
    }

    public var tmdbAPIKey: String {
        didSet { persistSecret(tmdbAPIKey, account: SecretKey.tmdbAPIKey) }
    }

    public var omdbAPIKey: String {
        didSet { persistSecret(omdbAPIKey, account: SecretKey.omdbAPIKey) }
    }

    public var radarrURL: String {
        didSet { defaults.set(radarrURL, forKey: DefaultsKey.radarrURL) }
    }

    public var radarrAPIKey: String {
        didSet { persistSecret(radarrAPIKey, account: SecretKey.radarrAPIKey) }
    }

    public var radarrRootFolderPath: String {
        didSet { defaults.set(radarrRootFolderPath, forKey: DefaultsKey.radarrRootFolderPath) }
    }

    public var radarrQualityProfileID: String {
        didSet { defaults.set(radarrQualityProfileID, forKey: DefaultsKey.radarrQualityProfileID) }
    }

    public var sonarrURL: String {
        didSet { defaults.set(sonarrURL, forKey: DefaultsKey.sonarrURL) }
    }

    public var sonarrAPIKey: String {
        didSet { persistSecret(sonarrAPIKey, account: SecretKey.sonarrAPIKey) }
    }

    public var sonarrRootFolderPath: String {
        didSet { defaults.set(sonarrRootFolderPath, forKey: DefaultsKey.sonarrRootFolderPath) }
    }

    public var sonarrQualityProfileID: String {
        didSet { defaults.set(sonarrQualityProfileID, forKey: DefaultsKey.sonarrQualityProfileID) }
    }

    public var gatewayEnabled: Bool {
        didSet { defaults.set(gatewayEnabled, forKey: DefaultsKey.gatewayEnabled) }
    }

    public var gatewayURL: String {
        didSet { defaults.set(gatewayURL, forKey: DefaultsKey.gatewayURL) }
    }

    public var gatewayToken: String {
        didSet { persistSecret(gatewayToken, account: SecretKey.gatewayToken) }
    }

    public var traktClientID: String {
        didSet { persistSecret(traktClientID, account: SecretKey.traktClientID) }
    }

    public var traktClientSecret: String {
        didSet { persistSecret(traktClientSecret, account: SecretKey.traktClientSecret) }
    }

    /// Preferred caption behaviour (Settings → Playback → Captions). Persisted
    /// as the raw value; an invalid or missing stored string falls back to `.off`.
    public var captionsPreference: AppleCaptionsPreference {
        didSet { defaults.set(captionsPreference.rawValue, forKey: DefaultsKey.captionsPreference) }
    }

    /// Compatibility shim for the former "Captions Auto-On" toggle, now folded
    /// into `captionsPreference`: `true` ↔ `.always`, `false` ↔ `.off`. Kept so
    /// existing callers and the migration read compile unchanged.
    public var captionsAutoOn: Bool {
        get { captionsPreference != .off }
        set { captionsPreference = newValue ? .always : .off }
    }

    /// Languages the captions menu lists add-on subtitles for, as three-letter
    /// codes in preference order (Settings → Playback → Subtitle Languages).
    /// Defaults to the device's preferred languages until the viewer picks.
    /// Written through `AppleSubtitleLanguages.sanitized`, so unknown codes,
    /// duplicates and anything past the third entry never reach storage.
    public var subtitleLanguages: [String] {
        get {
            access(keyPath: \.subtitleLanguages)
            return storedSubtitleLanguages
        }
        set {
            let clean = AppleSubtitleLanguages.sanitized(newValue)
            withMutation(keyPath: \.subtitleLanguages) {
                storedSubtitleLanguages = clean
            }
            defaults.set(clean, forKey: AppleSubtitleLanguages.defaultsKey)
            hasChosenSubtitleLanguages = true
        }
    }

    @ObservationIgnored private var storedSubtitleLanguages: [String]

    /// True once the viewer has picked languages; until then the list is the
    /// English-first device default. The picker is only ever opened by hand,
    /// from Settings › Playback or a subtitles add-on's detail page.
    public private(set) var hasChosenSubtitleLanguages: Bool

    /// Whether a show carries on to the next episode by itself. On by default,
    /// the way every other TV app behaves; with it off the end-of-episode card
    /// still appears and still works, it just never fires unattended.
    public var autoPlayNextEpisode: Bool {
        didSet { defaults.set(autoPlayNextEpisode, forKey: DefaultsKey.autoPlayNextEpisode) }
    }

    /// TMDB provider ids for the services the viewer has said they subscribe
    /// to. **Empty by default and empty means off** — nothing about where else
    /// a title can be watched appears until they opt in, which is the owner's
    /// first rule for the feature (2026-09-16).
    public var watchProviderIDs: Set<Int> {
        get {
            access(keyPath: \.watchProviderIDs)
            return storedWatchProviderIDs
        }
        set {
            withMutation(keyPath: \.watchProviderIDs) { storedWatchProviderIDs = newValue }
            defaults.set(Array(newValue).sorted(), forKey: DefaultsKey.watchProviderIDs)
        }
    }

    @ObservationIgnored private var storedWatchProviderIDs: Set<Int>

    public var autoPlayTrailer: Bool {
        didSet { defaults.set(autoPlayTrailer, forKey: DefaultsKey.autoPlayTrailer) }
    }

    public var autoMuteTrailer: Bool {
        didSet { defaults.set(autoMuteTrailer, forKey: DefaultsKey.autoMuteTrailer) }
    }

    public var deleteAfterWatching: Bool {
        didSet { defaults.set(deleteAfterWatching, forKey: DefaultsKey.deleteAfterWatching) }
    }

    public var systemSearchEnabled: Bool {
        didSet { defaults.set(systemSearchEnabled, forKey: DefaultsKey.systemSearchEnabled) }
    }

    public var topShelfEnabled: Bool {
        didSet { defaults.set(topShelfEnabled, forKey: DefaultsKey.topShelfEnabled) }
    }

    /// Writes the timeline this build records to a file, and lets the Web
    /// Management portal serve it.
    ///
    /// Off in a shipped build, on in a debug one. It is stored under the key
    /// `AppleInteractionTrace` reads directly, because the tracer runs long
    /// before this store exists and cannot depend on it.
    public var diagnosticLoggingEnabled: Bool {
        didSet { defaults.set(diagnosticLoggingEnabled, forKey: AppleInteractionTrace.preferenceKey) }
    }

    public var showInAppleServices: Bool {
        get { systemSearchEnabled || topShelfEnabled }
        set {
            systemSearchEnabled = newValue
            topShelfEnabled = newValue
        }
    }

    public var liveTVEnabled: Bool {
        didSet { defaults.set(liveTVEnabled, forKey: DefaultsKey.liveTVEnabled) }
    }

    public var discoverEnabled: Bool {
        didSet { defaults.set(discoverEnabled, forKey: DefaultsKey.discoverEnabled) }
    }

    public var libraryEnabled: Bool {
        didSet { defaults.set(libraryEnabled, forKey: DefaultsKey.libraryEnabled) }
    }

    public var top10ListsEnabled: Bool {
        didSet { defaults.set(top10ListsEnabled, forKey: DefaultsKey.top10ListsEnabled) }
    }

    public var liveChannelScope: AppleLiveChannelScope {
        didSet { defaults.set(liveChannelScope.rawValue, forKey: DefaultsKey.liveChannelScope) }
    }

    public var liveChannelPackage: AppleLiveChannelPackage {
        didSet { defaults.set(liveChannelPackage.rawValue, forKey: DefaultsKey.liveChannelPackage) }
    }

    public var customChannelPackage: AppleCustomChannelPackage {
        didSet {
            if let data = try? JSONEncoder().encode(customChannelPackage) {
                defaults.set(data, forKey: "openstream.settings.live.custom.v1")
            }
        }
    }

    public var showPayPerViewChannels: Bool {
        didSet { defaults.set(showPayPerViewChannels, forKey: DefaultsKey.showPayPerViewChannels) }
    }

    public var show24x7Channels: Bool {
        didSet { defaults.set(show24x7Channels, forKey: DefaultsKey.show24x7Channels) }
    }

    public var favoriteChannelIDs: Set<String> {
        didSet { defaults.set(favoriteChannelIDs.sorted(), forKey: DefaultsKey.favoriteChannelIDs) }
    }

    public var regionalZIPCode: String {
        didSet { defaults.set(regionalZIPCode, forKey: DefaultsKey.regionalZIPCode) }
    }

    /// Preferred playback engine for the next presentation. Persisted as the
    /// raw value; an invalid or missing stored string falls back to `.openStream`.
    public var playbackEngine: ApplePlaybackEngineKind {
        didSet { defaults.set(playbackEngine.rawValue, forKey: DefaultsKey.playbackEngine) }
    }

    /// Runtime-only flag set when the preferred OpenStream engine could not
    /// start and playback fell back to the AVPlayer-only native engine. Not
    /// persisted; reset to `false` on every launch.
    public var engineFellBackToNative: Bool

    public private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let keychain: any AppleCredentialStoring
    private var unreadableSecretAccounts: Set<String>

    public init(
        defaults: UserDefaults = .standard,
        keychain: any AppleCredentialStoring = AppleKeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain

        metadataEnabled = defaults.object(forKey: DefaultsKey.metadataEnabled) as? Bool ?? false
        radarrURL = defaults.string(forKey: DefaultsKey.radarrURL) ?? ""
        radarrRootFolderPath = defaults.string(forKey: DefaultsKey.radarrRootFolderPath) ?? ""
        radarrQualityProfileID = defaults.string(forKey: DefaultsKey.radarrQualityProfileID) ?? ""
        sonarrURL = defaults.string(forKey: DefaultsKey.sonarrURL) ?? ""
        sonarrRootFolderPath = defaults.string(forKey: DefaultsKey.sonarrRootFolderPath) ?? ""
        sonarrQualityProfileID = defaults.string(forKey: DefaultsKey.sonarrQualityProfileID) ?? ""
        gatewayEnabled = defaults.bool(forKey: DefaultsKey.gatewayEnabled)
        gatewayURL = defaults.string(forKey: DefaultsKey.gatewayURL) ?? ""
        // Captions are on unless the viewer has turned them off, so they work
        // out of the box rather than sitting behind two settings screens
        // (owner 2026-09-15: "auto on captions should be enabled by default
        // but can be toggled off"). Only a stored preference overrides this —
        // including `.off`, so turning them off sticks. The former
        // "Captions Auto-On" boolean is read here too, for installs that
        // predate the preference, and both of its values map to the same
        // answer they used to mean.
        if let stored = defaults.string(forKey: DefaultsKey.captionsPreference),
           let pref = AppleCaptionsPreference(rawValue: stored) {
            captionsPreference = pref
        } else {
            captionsPreference = .always
        }
        if let storedLanguages = defaults.stringArray(forKey: AppleSubtitleLanguages.defaultsKey) {
            storedSubtitleLanguages = AppleSubtitleLanguages.sanitized(storedLanguages)
            hasChosenSubtitleLanguages = true
        } else {
            storedSubtitleLanguages = AppleSubtitleLanguages.deviceDefaults()
            hasChosenSubtitleLanguages = false
        }
        autoPlayTrailer = defaults.object(forKey: DefaultsKey.autoPlayTrailer) as? Bool ?? true
        autoPlayNextEpisode = defaults.object(forKey: DefaultsKey.autoPlayNextEpisode) as? Bool ?? true
        storedWatchProviderIDs = Set((defaults.array(forKey: DefaultsKey.watchProviderIDs) as? [Int]) ?? [])
        autoMuteTrailer = defaults.object(forKey: DefaultsKey.autoMuteTrailer) as? Bool ?? false
        deleteAfterWatching = defaults.bool(forKey: DefaultsKey.deleteAfterWatching)
        systemSearchEnabled = defaults.bool(forKey: DefaultsKey.systemSearchEnabled)
        diagnosticLoggingEnabled = AppleInteractionTrace.isEnabled
        topShelfEnabled = defaults.bool(forKey: DefaultsKey.topShelfEnabled)
        liveTVEnabled = defaults.object(forKey: DefaultsKey.liveTVEnabled) as? Bool ?? true
        discoverEnabled = defaults.object(forKey: DefaultsKey.discoverEnabled) as? Bool ?? true
        libraryEnabled = defaults.object(forKey: DefaultsKey.libraryEnabled) as? Bool ?? true
        top10ListsEnabled = defaults.object(forKey: DefaultsKey.top10ListsEnabled) as? Bool ?? true
        liveChannelScope = defaults.string(forKey: DefaultsKey.liveChannelScope)
            .flatMap(AppleLiveChannelScope.init(rawValue:)) ?? .providerLineup
        liveChannelPackage = defaults.string(forKey: DefaultsKey.liveChannelPackage)
            .flatMap(AppleLiveChannelPackage.init(rawValue:)) ?? .premierGuide
        customChannelPackage = defaults.data(forKey: "openstream.settings.live.custom.v1")
            .flatMap { try? JSONDecoder().decode(AppleCustomChannelPackage.self, from: $0) } ?? .init()
        showPayPerViewChannels = defaults.object(forKey: DefaultsKey.showPayPerViewChannels) as? Bool ?? true
        show24x7Channels = defaults.object(forKey: DefaultsKey.show24x7Channels) as? Bool ?? false
        favoriteChannelIDs = Set(defaults.stringArray(forKey: DefaultsKey.favoriteChannelIDs) ?? [])
        regionalZIPCode = defaults.string(forKey: DefaultsKey.regionalZIPCode) ?? ""
        playbackEngine = ApplePlaybackEngineKind(
            rawValue: defaults.string(forKey: DefaultsKey.playbackEngine) ?? ""
        ) ?? .openStream
        engineFellBackToNative = false

        var unreadable = Set<String>()
        var firstReadError: String?
        func load(_ account: String) -> String {
            do {
                return try keychain.string(for: account) ?? ""
            } catch {
                unreadable.insert(account)
                if firstReadError == nil { firstReadError = error.localizedDescription }
                return ""
            }
        }
        tmdbAPIKey = load(SecretKey.tmdbAPIKey)
        omdbAPIKey = load(SecretKey.omdbAPIKey)
        radarrAPIKey = load(SecretKey.radarrAPIKey)
        sonarrAPIKey = load(SecretKey.sonarrAPIKey)
        gatewayToken = load(SecretKey.gatewayToken)
        traktClientID = load(SecretKey.traktClientID)
        traktClientSecret = load(SecretKey.traktClientSecret)
        unreadableSecretAccounts = unreadable
        persistenceError = firstReadError
    }

    public func clearPersistenceError() {
        persistenceError = nil
    }

    private func persistSecret(_ value: String, account: String) {
        do {
            if value.isEmpty {
                guard !unreadableSecretAccounts.contains(account) else { return }
                try keychain.remove(account)
            } else {
                try keychain.set(value, for: account)
                unreadableSecretAccounts.remove(account)
            }
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private enum DefaultsKey {
        static let metadataEnabled = "openstream.settings.metadata.enabled.v1"
        static let radarrURL = "openstream.settings.radarr.url.v1"
        static let radarrRootFolderPath = "openstream.settings.radarr.rootFolderPath.v1"
        static let radarrQualityProfileID = "openstream.settings.radarr.qualityProfileID.v1"
        static let sonarrURL = "openstream.settings.sonarr.url.v1"
        static let sonarrRootFolderPath = "openstream.settings.sonarr.rootFolderPath.v1"
        static let sonarrQualityProfileID = "openstream.settings.sonarr.qualityProfileID.v1"
        static let gatewayEnabled = "openstream.settings.gateway.enabled.v1"
        static let gatewayURL = "openstream.settings.gateway.url.v1"
        static let captionsAutoOn = "openstream.settings.captions.autoOn.v1"
        static let captionsPreference = "openstream.settings.captions.preference.v1"
        static let autoPlayTrailer = "openstream.settings.trailer.autoplay.v1"
        static let autoPlayNextEpisode = "openstream.settings.nextepisode.autoplay.v1"
        static let watchProviderIDs = "openstream.settings.watchproviders.v1"
        static let autoMuteTrailer = "openstream.settings.trailer.autoMute.v1"
        static let deleteAfterWatching = "openstream.settings.downloads.deleteAfterWatching.v1"
        static let systemSearchEnabled = "openstream.settings.privacy.systemSearch.v1"
        static let topShelfEnabled = "openstream.settings.privacy.topShelf.v1"
        static let liveTVEnabled = "openstream.settings.live.enabled.v1"
        static let discoverEnabled = "openstream.settings.discover.enabled.v1"
        static let libraryEnabled = "openstream.settings.library.enabled.v1"
        static let top10ListsEnabled = "openstream.settings.discover.top10Lists.v1"
        static let liveChannelScope = "openstream.settings.live.scope.v1"
        static let liveChannelPackage = "openstream.settings.live.package.v1"
        static let showPayPerViewChannels = "openstream.settings.live.showPPV.v1"
        static let show24x7Channels = "openstream.settings.live.show24x7.v1"
        static let favoriteChannelIDs = "openstream.settings.live.favoriteChannelIDs.v1"
        static let regionalZIPCode = "openstream.settings.live.regionalZIPCode.v1"
        static let playbackEngine = "openstream.playback.engine"
    }

    private enum SecretKey {
        static let tmdbAPIKey = "metadata.tmdb.apiKey"
        static let omdbAPIKey = "metadata.omdb.apiKey"
        static let radarrAPIKey = "downloads.radarr.apiKey"
        static let sonarrAPIKey = "downloads.sonarr.apiKey"
        static let gatewayToken = "transcode.gateway.token"
        static let traktClientID = "trakt.client.id"
        static let traktClientSecret = "trakt.client.secret"
    }
}
