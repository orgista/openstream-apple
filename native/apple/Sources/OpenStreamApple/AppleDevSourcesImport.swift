#if DEBUG && OPENSTREAM_ADDONS
import Foundation

/// `-OpenStreamDevSources <absolute path>`: adds every source in the owner's
/// private dev-sources file through the same store calls the add screens use,
/// and applies its service keys. Debug builds only; `scripts/seed-sim.sh`
/// copies the file into the simulator app's container and passes its path.
///
/// The file is read and deleted in `App.init`, before
/// `-OpenStreamResetOnLaunch` empties the container, and imported once the
/// root view's stores exist. An in-app Reset recreates those stores; the
/// file is already consumed then, so nothing comes back.
@MainActor
public enum AppleDevSourcesImport {
    private static var pendingData: Data?
    private static var pendingReadFailure: String?

    /// A dev-sources file was handed over at launch and not yet imported.
    public static var isPending: Bool { pendingData != nil || pendingReadFailure != nil }

    public static func captureIfRequested(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        guard let path = defaults.string(forKey: AppleDevSourcesPolicy.launchKey), !path.isEmpty else {
            // A stubbed run (`-OpenStreamStubNetwork <dir>`) takes the sources
            // beside its fixtures, read in place: that file is a repo fixture,
            // not a copy, so it is never deleted.
            if let stubbed = AppleNetworkStub.devSourcesURL { pendingData = try? Data(contentsOf: stubbed) }
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            pendingData = try Data(contentsOf: url)
        } catch {
            pendingReadFailure = "cannot read the file (\(url.lastPathComponent))"
        }
        try? fileManager.removeItem(at: url)
    }

    public static func importPendingIfNeeded(sourceStore: AppleSourceStore, settings: AppleSettingsStore) async {
        if let failure = pendingReadFailure {
            pendingReadFailure = nil
            appleTrace("\(AppleDevSourcesPolicy.tracePrefix) failed \(failure)")
            appleTrace(AppleDevSourcesPolicy.summaryLine(added: 0, exists: 0, failed: 0, skipped: 0))
            return
        }
        guard let data = pendingData else { return }
        pendingData = nil
        let file: AppleDevSourcesFile
        do {
            file = try AppleDevSourcesPolicy.decode(data)
        } catch {
            appleTrace("\(AppleDevSourcesPolicy.tracePrefix) failed \(error)")
            appleTrace(AppleDevSourcesPolicy.summaryLine(added: 0, exists: 0, failed: 0, skipped: 0))
            return
        }
        for problem in file.problems { appleTrace("\(AppleDevSourcesPolicy.tracePrefix) skipped \(problem)") }
        for kind in file.ignoredKinds { appleTrace("\(AppleDevSourcesPolicy.tracePrefix) ignored unknown kind \(kind)") }

        var added = 0, exists = 0, failed = 0
        for source in file.sources {
            let outcome = await add(source, to: sourceStore)
            switch outcome {
            case .added: added += 1
            case .exists: exists += 1
            case .failed: failed += 1
            }
            appleTrace(AppleDevSourcesPolicy.traceLine(for: source, outcome: outcome))
        }
        apply(file.settings, to: settings)
        let skipped = file.problems.count + file.ignoredKinds.count
        appleTrace(AppleDevSourcesPolicy.summaryLine(added: added, exists: exists, failed: failed, skipped: skipped))
    }

    private static func add(_ source: AppleDevSource, to store: AppleSourceStore) async -> AppleDevSourcesPolicy.Outcome {
        if AppleDevSourcesPolicy.alreadyAdded(source, in: store.sources) { return .exists }
        do {
            switch source {
            case .stremio(_, let manifestURL):
                let (url, manifest) = try await AppleManifestClient().load(manifestURL)
                try store.addStremio(manifestURL: url, manifest: manifest)
            case .xtream(let name, let serverURL, let username, let password, let epgURL):
                try AppleIPTVEndpointPolicy.validateCredentials(username: username, password: password)
                try store.addIPTV(name: name, type: .xtream, endpoint: serverURL, username: username,
                                  password: password, epgURL: epgURL, capabilities: ["Live channels", "Playback"])
            case .m3u(let name, let playlistURL, let epgURL):
                try store.addIPTV(name: name, type: .m3u, endpoint: playlistURL, epgURL: epgURL,
                                  capabilities: ["Live channels", "Playback"])
            case .smb(let name, let host, let port, let share, let path, let username, let password, let domain):
                try store.addNetworkShare(name: name, host: host, port: port, share: share, path: path,
                                          username: username, password: password, domain: domain)
            case .mediaServer(let kind, let name, let urlText, let credential):
                guard let baseURL = AppleMediaServerFormPolicy.normalizedBaseURL(urlText) else {
                    return .failed("the server address is not valid")
                }
                let session = try await mediaServerSession(kind: kind, name: name, baseURL: baseURL, credential: credential)
                let info = kind == .plex ? nil : try? await AppleMediaServerClient().publicInfo(baseURL: baseURL)
                let finalName = AppleMediaServerFormPolicy.defaultName(kind: kind, typedName: name,
                                                                       publicInfo: info, host: baseURL.host)
                _ = try store.addMediaServer(kind: kind, name: finalName, session: session)
            case .folder(let name, let path):
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return .failed("the folder does not exist")
                }
                try store.addLibraryFolder(name: name.isEmpty ? "Folder" : name,
                                           url: URL(fileURLWithPath: path, isDirectory: true), bookmarkData: nil)
            }
            return .added
        } catch {
            return .failed(AppleDevSourcesPolicy.failureReason(error, hiding: source.secrets))
        }
    }

    /// The Jellyfin/Emby sign-in the add screen does; for Plex, the owner's
    /// token stands in for the plex.tv PIN sign-in.
    private static func mediaServerSession(
        kind: AppleMediaServerKind, name: String, baseURL: URL, credential: AppleDevSource.Credential
    ) async throws -> AppleMediaServerSession {
        switch credential {
        case .password(let username, let password):
            return try await AppleMediaServerClient().authenticate(baseURL: baseURL, kind: kind,
                                                                   username: username, password: password)
        case .token(let token):
            let account = try await ApplePlexClient().account(token: token)
            return AppleMediaServerSession(kind: .plex, baseURL: baseURL, accessToken: token,
                                           userID: String(account.id), serverName: name.isEmpty ? nil : name,
                                           userName: account.username ?? account.title, accountToken: token)
        }
    }

    static func apply(_ values: AppleDevSettings, to settings: AppleSettingsStore) {
        // A key without the switch left Use Metadata APIs off after seeding
        // (full test 2026-09-30); the seed is for testing with metadata.
        if let key = values.tmdbAPIKey {
            settings.tmdbAPIKey = key
            if !key.isEmpty { settings.metadataEnabled = true }
        }
        if let radarr = values.radarr {
            settings.radarrURL = radarr.url
            settings.radarrAPIKey = radarr.apiKey
            if !radarr.rootFolderPath.isEmpty { settings.radarrRootFolderPath = radarr.rootFolderPath }
            if !radarr.qualityProfileID.isEmpty { settings.radarrQualityProfileID = radarr.qualityProfileID }
        }
        if let sonarr = values.sonarr {
            settings.sonarrURL = sonarr.url
            settings.sonarrAPIKey = sonarr.apiKey
            if !sonarr.rootFolderPath.isEmpty { settings.sonarrRootFolderPath = sonarr.rootFolderPath }
            if !sonarr.qualityProfileID.isEmpty { settings.sonarrQualityProfileID = sonarr.qualityProfileID }
        }
        if let trakt = values.traktClientID { settings.traktClientID = trakt }
        let names = values.appliedNames
        if !names.isEmpty {
            appleTrace("\(AppleDevSourcesPolicy.tracePrefix) settings \(names.joined(separator: ", ")): applied")
        }
    }
}
#endif
