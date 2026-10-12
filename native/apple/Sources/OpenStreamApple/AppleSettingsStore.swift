import Foundation
import MediaAccessibility
import Observation
import Security
import Synchronization
#if os(iOS) || os(tvOS)
import UIKit
#endif

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

/// Local credentials use ThisDeviceOnly; syncing is an explicit viewer choice.
public struct AppleKeychainStore: AppleCredentialStoring, Sendable {
    static let syncPreferenceKey = "openstream.backup.icloud.enabled.v1"
    private let service: String
    /// The backup key is iCloud Keychain whatever the sync switch says.
    private let alwaysSynchronizable: Bool
    /// The Apple TV has no switch, so the policy answers for it: its
    /// credentials are read from the synchronizing keychain the phone wrote.
    private var synchronizable: Bool {
        if alwaysSynchronizable { return true }
        Self.adoptDefaultSyncPreference()
        return AppleConfigurationSyncPolicy.isEnabled(
            storedPreference: AppleConfigurationSyncPolicy.storedPreference()
        )
    }

    /// Sync is on by default (2026-09-28), but an install that never touched
    /// the switch still holds its credentials ThisDeviceOnly, where a
    /// synchronizable query cannot see them. Before the first keychain access
    /// in the process, move them over and record the choice, so the stored
    /// value is what `setSynchronizationEnabled` migrates from. If the move
    /// fails, record off: the credentials stay readable where they are.
    static func adoptDefaultSyncPreference() { _ = defaultSyncAdoption }

    private static let defaultSyncAdoption: Void = {
        let defaults = UserDefaults.standard
        guard AppleConfigurationSyncPolicy.offersToggle(), testMemory == nil, !isBypassedForReview,
              defaults.object(forKey: syncPreferenceKey) == nil else { return }
        do {
            try migrateSynchronization(to: true)
            appleTrace("configuration sync: default on, keychain moved to synchronizing")
        } catch {
            defaults.set(false, forKey: syncPreferenceKey)
            appleTrace("configuration sync: default on failed to move the keychain, left off")
        }
    }()
    private var accessibility: CFString {
        if alwaysSynchronizable { return kSecAttrAccessibleAfterFirstUnlock }
        return synchronizable ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    public init(service: String = "com.orgista.openstream.settings", alwaysSynchronizable: Bool = false) {
        self.service = service
        self.alwaysSynchronizable = alwaysSynchronizable
    }

    #if DEBUG
    /// `-OpenStreamDebugNoKeychain YES`: a review build launched headlessly
    /// reads no saved credential and writes none. On the Mac a build signed
    /// differently from the one that saved an item raises a keychain dialog
    /// on the owner's screen (N13, 2026-09-23); with this it never asks.
    static var isBypassedForReview: Bool { UserDefaults.standard.bool(forKey: "OpenStreamDebugNoKeychain") }
    #else
    static let isBypassedForReview = false
    #endif

    #if DEBUG
    /// Under a test runner every read and write stays in this process. The
    /// suites built sources on the default store, so each `swift test` on the
    /// Mac added items to the owner's login keychain — 5,486 by 2026-09-24,
    /// each tied to the one test binary that wrote it — and the app then
    /// asked for the keychain password again and again.
    static let testMemory: AppleKeychainTestMemory? =
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? AppleKeychainTestMemory() : nil
    #else
    static let testMemory: AppleKeychainTestMemory? = nil
    #endif

    public func string(for account: String) throws -> String? {
        if Self.isBypassedForReview { return nil }
        if let memory = Self.testMemory { return memory.value(service: service, account: account) }
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
        if Self.isBypassedForReview { return }
        if let memory = Self.testMemory { memory.set(value, service: service, account: account); return }
        let data = Data(value.utf8)
        let query = baseQuery(for: account)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = accessibility
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
        if Self.isBypassedForReview { return }
        if let memory = Self.testMemory { memory.set(nil, service: service, account: account); return }
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.unexpectedStatus(status)
        }
    }

    /// Change accessibility and sync together; ThisDeviceOnly is incompatible with sync.
    /// Roll back migrated services if a later update fails, leaving the toggle unchanged.
    static func setSynchronizationEnabled(_ enabled: Bool) throws {
        adoptDefaultSyncPreference()
        try migrateSynchronization(to: enabled)
    }

    private static func migrateSynchronization(to enabled: Bool) throws {
        let previous = UserDefaults.standard.bool(forKey: syncPreferenceKey)
        guard !isBypassedForReview else { return }
        // Unset reads as on, so an unset "off" still has to be written down.
        guard previous != enabled else { UserDefaults.standard.set(enabled, forKey: syncPreferenceKey); return }
        // Tests keep items in memory, which has no sync attribute to migrate.
        if testMemory != nil { UserDefaults.standard.set(enabled, forKey: syncPreferenceKey); return }
        var changed: [String] = []
        do {
            for service in ["com.orgista.openstream.settings", "com.orgista.openstream.instances"] {
                try migrate(service: service, from: previous, to: enabled)
                changed.append(service)
            }
        } catch {
            for service in changed { try? migrate(service: service, from: enabled, to: previous) }
            throw error
        }
        UserDefaults.standard.set(enabled, forKey: syncPreferenceKey)
    }

    private static func migrate(service: String, from old: Bool, to new: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: old,
        ]
        let attributes: [String: Any] = [
            kSecAttrSynchronizable as String: new,
            kSecAttrAccessible as String: new ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }
}

/// A test run's keychain: one dictionary per process, keyed by service and
/// account (see `AppleKeychainStore.testMemory`).
final class AppleKeychainTestMemory: Sendable {
    private let items = Mutex<[String: String]>([:])

    func value(service: String, account: String) -> String? {
        items.withLock { $0[service + "\u{0}" + account] }
    }

    func set(_ value: String?, service: String, account: String) {
        items.withLock { $0[service + "\u{0}" + account] = value }
    }

    func removeAll(service: String) {
        items.withLock { $0 = $0.filter { !$0.key.hasPrefix(service + "\u{0}") } }
    }
}

public enum AppleLiveChannelScope: String, Codable, CaseIterable, Identifiable, Sendable {
    // "Your Regional" was removed by owner decision (2026-09-17: "I don't
    // think it works"); a stored "regional" decodes as nil and falls back to
    // the provider lineup.
    case providerLineup
    case favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .providerLineup: "Provider Lineup"
        case .favorites: "My Channels"
        }
    }
}

public enum AppleLiveChannelPackage: String, Codable, CaseIterable, Identifiable, Sendable {
    case completeGuide
    case everything
    case custom

    public var id: String { rawValue }

    /// All builds carry the organisation preset; none supply channels.
    public static var available: [AppleLiveChannelPackage] { allCases }

    /// Count distinct guide numbers so duplicate quality feeds cannot qualify a playlist.
    public static func defaultPackage(for channels: [AppleIPTVChannel]) -> AppleLiveChannelPackage {
        let index = AppleChannelLineupIndex((try? AppleChannelLineupPresets.completeUS()) ?? [])
        let matched = Set(AppleChannelVisibilityPolicy.deduplicatedEastChannels(channels)
            .compactMap { index.match($0.name)?.number })
        return matched.count >= AppleLiveChannelSnapshot.minimumLineupMatches ? .completeGuide : .everything
    }

    public init?(storedValue: String) {
        self.init(rawValue: storedValue == "premierGuide" ? "completeGuide" : storedValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let package = Self(storedValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown Live TV package")
        }
        self = package
    }

    public var title: String {
        switch self {
        case .completeGuide: "Complete Guide"
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

/// Preferred caption behaviour, stored in `AppleSettingsStore.storedCaptionsPreference`
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

    /// The system CC + SDH switch is an extra ON signal; switching it off
    /// never disables an app preference or rewrites the saved choice.
    static func effective(_ stored: Self, systemCaptionsEnabled: Bool) -> Self {
        stored == .off && systemCaptionsEnabled ? .always : stored
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

    /// Saved app choice. The system CC + SDH switch can additionally enable
    /// captions, without changing this value or its persisted representation.
    public var storedCaptionsPreference: AppleCaptionsPreference {
        didSet { defaults.set(storedCaptionsPreference.rawValue, forKey: DefaultsKey.captionsPreference) }
    }
    /// Playback preference, including the system CC + SDH switch. Settings
    /// binds to `storedCaptionsPreference` so the saved choice remains editable.
    public var captionsPreference: AppleCaptionsPreference {
        get {
            _ = systemCaptionsRevision
            return .effective(storedCaptionsPreference, systemCaptionsEnabled: systemCaptionsEnabled())
        }
        set { storedCaptionsPreference = newValue }
    }
    private var systemCaptionsRevision = 0
    @ObservationIgnored private let systemCaptionsEnabled: () -> Bool
    @ObservationIgnored private let captionNotificationCenter: NotificationCenter
    @ObservationIgnored private var captionObservers: [NSObjectProtocol] = []

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

    /// Settings › Playback › Audio Language as a canonical three-letter
    /// code, or "" for Device Language (`AppleAudioLanguagePreference`).
    /// Engines read the stored value at each load.
    public var liveBuffer: AppleLiveBufferPreference {
        didSet { defaults.set(liveBuffer.rawValue, forKey: AppleLiveBufferPreference.defaultsKey) }
    }

    public var audioLanguage: String {
        didSet {
            let clean = AppleSubtitleLanguages.normalized(audioLanguage) ?? ""
            if clean.isEmpty { defaults.removeObject(forKey: AppleAudioLanguagePreference.defaultsKey) }
            else { defaults.set(clean, forKey: AppleAudioLanguagePreference.defaultsKey) }
        }
    }

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

    /// Top Shelf, widgets and channel suggestions; the data stays on the device.
    public nonisolated static func topShelfEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.topShelfEnabled) as? Bool ?? true
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

    /// The viewer's Discover row order (`AppleDiscoverRowOrder` ids), or nil
    /// for the order Discover builds on its own.
    public var discoverRowOrder: [String]? {
        didSet {
            if let discoverRowOrder { defaults.set(discoverRowOrder, forKey: DefaultsKey.discoverRowOrder) }
            else { defaults.removeObject(forKey: DefaultsKey.discoverRowOrder) }
        }
    }

    public var liveChannelScope: AppleLiveChannelScope {
        didSet { defaults.set(liveChannelScope.rawValue, forKey: DefaultsKey.liveChannelScope) }
    }

    private var selectedLiveChannelPackage: AppleLiveChannelPackage?
    private var automaticLiveChannelPackage: AppleLiveChannelPackage = .everything

    public var liveChannelPackage: AppleLiveChannelPackage {
        get { selectedLiveChannelPackage ?? automaticLiveChannelPackage }
        set {
            selectedLiveChannelPackage = newValue
            defaults.set(newValue.rawValue, forKey: DefaultsKey.liveChannelPackage)
        }
    }

    /// Automatic choices stay unsaved, so new or changed playlists are evaluated again.
    public func updateAutomaticLiveChannelPackage(channels: [AppleIPTVChannel]) {
        guard selectedLiveChannelPackage == nil else { return }
        automaticLiveChannelPackage = AppleLiveChannelPackage.defaultPackage(for: channels)
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

    public var hiddenLiveChannelIDs: Set<String> {
        didSet { defaults.set(hiddenLiveChannelIDs.sorted(), forKey: DefaultsKey.hiddenLiveChannelIDs) }
    }
    public var hiddenLiveGroups: Set<String> {
        didSet { defaults.set(hiddenLiveGroups.sorted(), forKey: DefaultsKey.hiddenLiveGroups) }
    }
    public var favoriteLiveChannelOrder: [String] {
        didSet { defaults.set(favoriteLiveChannelOrder, forKey: DefaultsKey.favoriteLiveChannelOrder) }
    }

    public var guideChannelAssignments: [String: String] {
        didSet { defaults.set(guideChannelAssignments, forKey: DefaultsKey.guideChannelAssignments) }
    }

    public var guideTimeOffsets: [String: Int] {
        didSet { defaults.set(guideTimeOffsets, forKey: DefaultsKey.guideTimeOffsets) }
    }

    public var favoriteChannelIDs: Set<String> {
        didSet { defaults.set(favoriteChannelIDs.sorted(), forKey: DefaultsKey.favoriteChannelIDs) }
    }

    public var regionalZIPCode: String {
        didSet { defaults.set(regionalZIPCode, forKey: DefaultsKey.regionalZIPCode) }
    }

    /// The playback engine: always the OpenStream engine, which plays every
    /// container inside Apple's own player (owner decision 2026-10-01, "native
    /// player with our engine"). Not a setting any more, and not persisted: a
    /// "native" saved by the old Player picker is ignored and cleared. A DEBUG
    /// build honours `-openstream.playback.engine native` on the launch line
    /// for testing (`ApplePlaybackEngineKind.resolved`).
    public var playbackEngine: ApplePlaybackEngineKind

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
        keychain: any AppleCredentialStoring = AppleKeychainStore(),
        systemCaptionsEnabled: @escaping () -> Bool = {
            MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
        },
        captionNotificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.systemCaptionsEnabled = systemCaptionsEnabled
        self.captionNotificationCenter = captionNotificationCenter

        metadataEnabled = defaults.object(forKey: DefaultsKey.metadataEnabled) as? Bool ?? false
        radarrURL = defaults.string(forKey: DefaultsKey.radarrURL) ?? ""
        radarrRootFolderPath = defaults.string(forKey: DefaultsKey.radarrRootFolderPath) ?? ""
        radarrQualityProfileID = defaults.string(forKey: DefaultsKey.radarrQualityProfileID) ?? ""
        sonarrURL = defaults.string(forKey: DefaultsKey.sonarrURL) ?? ""
        sonarrRootFolderPath = defaults.string(forKey: DefaultsKey.sonarrRootFolderPath) ?? ""
        sonarrQualityProfileID = defaults.string(forKey: DefaultsKey.sonarrQualityProfileID) ?? ""
        gatewayEnabled = defaults.bool(forKey: DefaultsKey.gatewayEnabled)
        gatewayURL = defaults.string(forKey: DefaultsKey.gatewayURL) ?? ""
        // Keep the app's saved choice intact. The effective getter adds the
        // system CC + SDH signal; an unset app preference still defaults to on.
        if let stored = defaults.string(forKey: DefaultsKey.captionsPreference),
           let pref = AppleCaptionsPreference(rawValue: stored) {
            storedCaptionsPreference = pref
        } else {
            storedCaptionsPreference = .always
        }
        if let storedLanguages = defaults.stringArray(forKey: AppleSubtitleLanguages.defaultsKey) {
            storedSubtitleLanguages = AppleSubtitleLanguages.sanitized(storedLanguages)
            hasChosenSubtitleLanguages = true
        } else {
            storedSubtitleLanguages = AppleSubtitleLanguages.deviceDefaults()
            hasChosenSubtitleLanguages = false
        }
        audioLanguage = AppleAudioLanguagePreference.storedChoice(defaults: defaults) ?? ""
        autoPlayTrailer = defaults.object(forKey: DefaultsKey.autoPlayTrailer) as? Bool ?? true
        liveBuffer = AppleLiveBufferPreference.stored(in: defaults)
        autoPlayNextEpisode = defaults.object(forKey: DefaultsKey.autoPlayNextEpisode) as? Bool ?? true
        storedWatchProviderIDs = Set((defaults.array(forKey: DefaultsKey.watchProviderIDs) as? [Int]) ?? [])
        autoMuteTrailer = defaults.object(forKey: DefaultsKey.autoMuteTrailer) as? Bool ?? false
        deleteAfterWatching = defaults.bool(forKey: DefaultsKey.deleteAfterWatching)
        systemSearchEnabled = defaults.bool(forKey: DefaultsKey.systemSearchEnabled)
        diagnosticLoggingEnabled = AppleInteractionTrace.isEnabled
        topShelfEnabled = Self.topShelfEnabled(in: defaults)
        liveTVEnabled = defaults.object(forKey: DefaultsKey.liveTVEnabled) as? Bool ?? true
        discoverEnabled = defaults.object(forKey: DefaultsKey.discoverEnabled) as? Bool ?? true
        libraryEnabled = defaults.object(forKey: DefaultsKey.libraryEnabled) as? Bool ?? true
        top10ListsEnabled = defaults.object(forKey: DefaultsKey.top10ListsEnabled) as? Bool ?? false
        discoverRowOrder = defaults.stringArray(forKey: DefaultsKey.discoverRowOrder)
        liveChannelScope = defaults.string(forKey: DefaultsKey.liveChannelScope)
            .flatMap(AppleLiveChannelScope.init(rawValue:)) ?? .providerLineup
        let storedPackage = defaults.string(forKey: DefaultsKey.liveChannelPackage)
            .flatMap(AppleLiveChannelPackage.init(storedValue:))
        selectedLiveChannelPackage = storedPackage
        if let storedPackage {
            defaults.set(storedPackage.rawValue, forKey: DefaultsKey.liveChannelPackage)
        }
        customChannelPackage = defaults.data(forKey: "openstream.settings.live.custom.v1")
            .flatMap { try? JSONDecoder().decode(AppleCustomChannelPackage.self, from: $0) } ?? .init()
        showPayPerViewChannels = defaults.object(forKey: DefaultsKey.showPayPerViewChannels) as? Bool ?? true
        show24x7Channels = defaults.object(forKey: DefaultsKey.show24x7Channels) as? Bool ?? false
        hiddenLiveChannelIDs = Set(defaults.stringArray(forKey: DefaultsKey.hiddenLiveChannelIDs) ?? [])
        hiddenLiveGroups = Set(defaults.stringArray(forKey: DefaultsKey.hiddenLiveGroups) ?? [])
        favoriteLiveChannelOrder = defaults.stringArray(forKey: DefaultsKey.favoriteLiveChannelOrder) ?? []
        guideChannelAssignments = defaults.dictionary(forKey: DefaultsKey.guideChannelAssignments) as? [String: String] ?? [:]
        guideTimeOffsets = (defaults.dictionary(forKey: DefaultsKey.guideTimeOffsets) as? [String: Int] ?? [:]).mapValues { min(14, max(-12, $0)) }
        favoriteChannelIDs = Set(defaults.stringArray(forKey: DefaultsKey.favoriteChannelIDs) ?? [])
        regionalZIPCode = defaults.string(forKey: DefaultsKey.regionalZIPCode) ?? ""
        playbackEngine = ApplePlaybackEngineKind.resolved(launchArguments: ProcessInfo.processInfo.arguments)
        // The old Player picker's saved choice: never read again.
        defaults.removeObject(forKey: DefaultsKey.playbackEngine)
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
        observeSystemCaptions()
    }

    private func observeSystemCaptions() {
        var names = [Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)]
        #if os(iOS) || os(tvOS)
        names.append(UIAccessibility.closedCaptioningStatusDidChangeNotification)
        #endif
        captionObservers = names.map { name in
            captionNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // NotificationCenter delivers on the main queue, including
                // when the system posts the change from a background thread.
                MainActor.assumeIsolated { self?.systemCaptionsRevision &+= 1 }
            }
        }
    }

    isolated deinit {
        for observer in captionObservers {
            captionNotificationCenter.removeObserver(observer)
        }
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

    // Explicit allowlist: importing a file must never write arbitrary defaults keys.
    static var configurationKeys: [String] {
        [
            DefaultsKey.metadataEnabled,
            DefaultsKey.radarrURL,
            DefaultsKey.radarrRootFolderPath,
            DefaultsKey.radarrQualityProfileID,
            DefaultsKey.sonarrURL,
            DefaultsKey.sonarrRootFolderPath,
            DefaultsKey.sonarrQualityProfileID,
            DefaultsKey.gatewayEnabled,
            DefaultsKey.gatewayURL,
            DefaultsKey.captionsAutoOn,
            DefaultsKey.captionsPreference,
            DefaultsKey.autoPlayTrailer,
            DefaultsKey.autoPlayNextEpisode,
            DefaultsKey.watchProviderIDs,
            DefaultsKey.autoMuteTrailer,
            DefaultsKey.deleteAfterWatching,
            DefaultsKey.systemSearchEnabled,
            DefaultsKey.topShelfEnabled,
            DefaultsKey.liveTVEnabled,
            DefaultsKey.discoverEnabled,
            DefaultsKey.libraryEnabled,
            DefaultsKey.top10ListsEnabled,
            DefaultsKey.discoverRowOrder,
            DefaultsKey.liveChannelScope,
            DefaultsKey.liveChannelPackage,
            DefaultsKey.showPayPerViewChannels,
            DefaultsKey.show24x7Channels,
            DefaultsKey.favoriteChannelIDs,
            DefaultsKey.guideTimeOffsets,
            DefaultsKey.guideChannelAssignments,
            DefaultsKey.hiddenLiveChannelIDs,
            DefaultsKey.hiddenLiveGroups,
            DefaultsKey.favoriteLiveChannelOrder,
            DefaultsKey.regionalZIPCode,
            AppleSubtitleLanguages.defaultsKey,
            AppleAudioLanguagePreference.defaultsKey,
            AppleInteractionTrace.preferenceKey,
            "openstream.settings.live.custom.v1",
        ]
    }

    static let configurationURLKeys = [DefaultsKey.radarrURL, DefaultsKey.sonarrURL, DefaultsKey.gatewayURL]

    func configurationValues() throws -> [String: Data] {
        var values: [String: Data] = [:]
        for key in Self.configurationKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
            }
        }
        return values
    }

    static func configurationValue(_ data: Data) throws -> Any {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              values.count == 1 else { throw AppleConfigurationError.invalidFile }
        return values[0]
    }

    func restoreConfiguration(_ values: [String: Data]) throws {
        // Decode before writing, so malformed values cannot leave half-applied settings.
        var decoded: [String: Any] = [:]
        for key in Self.configurationKeys {
            if let data = values[key] { decoded[key] = try Self.configurationValue(data) }
        }
        for key in Self.configurationKeys {
            if let value = decoded[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let restored = AppleSettingsStore(defaults: defaults, keychain: keychain)
        metadataEnabled = restored.metadataEnabled
        radarrURL = restored.radarrURL
        radarrRootFolderPath = restored.radarrRootFolderPath
        radarrQualityProfileID = restored.radarrQualityProfileID
        sonarrURL = restored.sonarrURL
        sonarrRootFolderPath = restored.sonarrRootFolderPath
        sonarrQualityProfileID = restored.sonarrQualityProfileID
        gatewayEnabled = restored.gatewayEnabled
        gatewayURL = restored.gatewayURL
        storedCaptionsPreference = restored.storedCaptionsPreference
        subtitleLanguages = restored.subtitleLanguages
        audioLanguage = restored.audioLanguage
        autoPlayNextEpisode = restored.autoPlayNextEpisode
        watchProviderIDs = restored.watchProviderIDs
        autoPlayTrailer = restored.autoPlayTrailer
        autoMuteTrailer = restored.autoMuteTrailer
        deleteAfterWatching = restored.deleteAfterWatching
        systemSearchEnabled = restored.systemSearchEnabled
        topShelfEnabled = restored.topShelfEnabled
        diagnosticLoggingEnabled = restored.diagnosticLoggingEnabled
        liveTVEnabled = restored.liveTVEnabled
        discoverEnabled = restored.discoverEnabled
        libraryEnabled = restored.libraryEnabled
        top10ListsEnabled = restored.top10ListsEnabled
        discoverRowOrder = restored.discoverRowOrder
        liveChannelScope = restored.liveChannelScope
        selectedLiveChannelPackage = restored.selectedLiveChannelPackage
        customChannelPackage = restored.customChannelPackage
        showPayPerViewChannels = restored.showPayPerViewChannels
        show24x7Channels = restored.show24x7Channels
        favoriteChannelIDs = restored.favoriteChannelIDs
        guideTimeOffsets = restored.guideTimeOffsets
        guideChannelAssignments = restored.guideChannelAssignments
        hiddenLiveChannelIDs = restored.hiddenLiveChannelIDs
        hiddenLiveGroups = restored.hiddenLiveGroups
        favoriteLiveChannelOrder = restored.favoriteLiveChannelOrder
        regionalZIPCode = restored.regionalZIPCode
    }

    func prepareConfigurationKeychain() throws {
        for key in Self.configurationURLKeys {
            if let value = defaults.string(forKey: key), !value.isEmpty {
                try keychain.set(value, for: "backup.url.\(key)")
            } else { try keychain.remove("backup.url.\(key)") }
        }
    }

    func synchronizedConfigurationURLs() throws -> [String: Data] {
        var values: [String: Data] = [:]
        for key in Self.configurationURLKeys {
            if let value = try keychain.string(for: "backup.url.\(key)") {
                values[key] = try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
            }
        }
        return values
    }

    func configurationCredentials() throws -> [String: String] {
        var values: [String: String] = [:]
        for account in Self.configurationSecretAccounts {
            values[account] = try keychain.string(for: account)
        }
        return values
    }

    private static var configurationSecretAccounts: [String] {
        [SecretKey.tmdbAPIKey, SecretKey.omdbAPIKey, SecretKey.radarrAPIKey, SecretKey.sonarrAPIKey, SecretKey.gatewayToken, SecretKey.traktClientID, SecretKey.traktClientSecret]
    }

    func restoreConfigurationCredentials(_ values: [String: String]) throws {
        for account in Self.configurationSecretAccounts {
            if let value = values[account] { try keychain.set(value, for: account) }
        }
        tmdbAPIKey = try keychain.string(for: SecretKey.tmdbAPIKey) ?? ""
        omdbAPIKey = try keychain.string(for: SecretKey.omdbAPIKey) ?? ""
        radarrAPIKey = try keychain.string(for: SecretKey.radarrAPIKey) ?? ""
        sonarrAPIKey = try keychain.string(for: SecretKey.sonarrAPIKey) ?? ""
        gatewayToken = try keychain.string(for: SecretKey.gatewayToken) ?? ""
        traktClientID = try keychain.string(for: SecretKey.traktClientID) ?? ""
        traktClientSecret = try keychain.string(for: SecretKey.traktClientSecret) ?? ""
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
        // v2 (owner 2026-10-10): on by default. v1 was off by default, and a
        // setup import wrote that off value to every device, so the shelf
        // showed only the static image; v1 values are ignored on purpose.
        static let topShelfEnabled = "openstream.settings.privacy.topShelf.v2"
        static let liveTVEnabled = "openstream.settings.live.enabled.v1"
        static let discoverEnabled = "openstream.settings.discover.enabled.v1"
        static let libraryEnabled = "openstream.settings.library.enabled.v1"
        static let top10ListsEnabled = "openstream.settings.discover.top10Lists.v1"
        static let discoverRowOrder = "openstream.settings.discover.rowOrder.v1"
        static let liveChannelScope = "openstream.settings.live.scope.v1"
        static let liveChannelPackage = "openstream.settings.live.package.v1"
        static let showPayPerViewChannels = "openstream.settings.live.showPPV.v1"
        static let show24x7Channels = "openstream.settings.live.show24x7.v1"
        static let hiddenLiveChannelIDs = "openstream.settings.live.hiddenChannelIDs.v1"
        static let hiddenLiveGroups = "openstream.settings.live.hiddenGroups.v1"
        static let favoriteLiveChannelOrder = "openstream.settings.live.favoriteOrder.v1"
        static let guideChannelAssignments = "openstream.settings.live.guideChannelAssignments.v1"
        static let guideTimeOffsets = "openstream.settings.live.guideTimeOffsets.v1"
        static let favoriteChannelIDs = "openstream.settings.live.favoriteChannelIDs.v1"
        static let regionalZIPCode = "openstream.settings.live.regionalZIPCode.v1"
        /// The old Player picker's key, cleared at launch; also the DEBUG
        /// launch argument's name.
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

public extension ApplePlaybackEngineKind {
    /// The engine every play uses: the OpenStream engine. Only a DEBUG build
    /// (`isDebugBuild`) honours `-openstream.playback.engine native` among the
    /// launch arguments, to test the stock AVPlayer route; a Release build
    /// ignores it, as it ignores any saved choice.
    static func resolved(launchArguments: [String], isDebugBuild: Bool = Self.isDebugBuild) -> Self {
        guard isDebugBuild,
              let flag = launchArguments.lastIndex(of: "-openstream.playback.engine"),
              launchArguments.indices.contains(flag + 1),
              let kind = Self(rawValue: launchArguments[flag + 1]) else { return .openStream }
        return kind
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
