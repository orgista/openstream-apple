import CryptoKit
import Foundation

struct AppleCloudMediaServerSession: Codable, Equatable, Sendable {
    let formatVersion: Int
    let sourceID: UUID
    let identity: String
    let kind: AppleSourceKind
    let iptvType: AppleIPTVSourceType?
    let sourceURL: URL
    let guideURL: URL?
    let credential: String?
    let session: AppleMediaServerSession?
    let isEnabled: Bool
    let validatedAt: Date

    init(sourceID: UUID, session: AppleMediaServerSession, validatedAt: Date = .now, isEnabled: Bool = true) {
        let serverSession = AppleMediaServerSession(kind: session.kind, baseURL: session.baseURL,
            accessToken: session.accessToken, userID: session.userID, serverID: session.serverID)
        self.init(source: AppleSource(id: sourceID, kind: .mediaServer, name: "", url: session.baseURL, isEnabled: isEnabled,
            lastValidatedAt: validatedAt, serverKind: session.kind,
            mediaServerIdentity: AppleSourceStore.mediaServerIdentity(for: session)),
            credential: nil, session: serverSession)
    }

    init(source: AppleSource, credential: String?, session: AppleMediaServerSession? = nil, validatedAt: Date? = nil) {
        formatVersion = 2
        sourceID = source.id
        kind = source.kind
        iptvType = source.iptvType
        identity = source.mediaServerIdentity ?? "\(source.kind.rawValue):\(source.id.uuidString.lowercased())"
        sourceURL = source.url
        guideURL = source.epgURL
        self.credential = credential
        self.session = session
        isEnabled = source.isEnabled
        self.validatedAt = validatedAt ?? source.lastValidatedAt ?? source.addedAt
    }

    var fingerprint: String {
        let credentialFields = session.map { [$0.accessToken, $0.userID, $0.serverID ?? ""] } ?? [credential ?? ""]
        let fields = [kind.rawValue, iptvType?.rawValue ?? "", identity, sourceURL.absoluteString,
                      guideURL?.absoluteString ?? ""] + credentialFields
        return SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    var version: String { Self.version(fingerprint: fingerprint, validatedAt: validatedAt) }

    static func version(fingerprint: String, validatedAt: Date) -> String {
        fingerprint + "@" + String(validatedAt.timeIntervalSinceReferenceDate)
    }

    func matches(_ source: AppleSource) -> Bool {
        guard kind == source.kind else { return false }
        if kind == .mediaServer {
            return source.mediaServerIdentity == identity && source.serverKind == session?.kind
        }
        return sourceID == source.id && iptvType == source.iptvType
    }

    func validate() throws {
        guard formatVersion == 2, kind != .library, sourceURL.host?.isEmpty == false else {
            throw AppleMediaServerError.malformedResponse
        }
        if kind != .mediaServer, identity != "\(kind.rawValue):\(sourceID.uuidString.lowercased())" {
            throw AppleMediaServerError.malformedResponse
        }
        if let guideURL, !["https", "http"].contains(guideURL.scheme?.lowercased() ?? "") {
            throw AppleMediaServerError.malformedResponse
        }
        switch kind {
        case .mediaServer:
            guard let session, !session.accessToken.isEmpty, !session.userID.isEmpty,
                  session.baseURL == sourceURL, AppleSourceStore.mediaServerIdentity(for: session) == identity,
                  ["https", "http"].contains(sourceURL.scheme?.lowercased() ?? "") else {
                throw AppleMediaServerError.malformedResponse
            }
        case .nas:
            _ = try AppleSMBEndpointPolicy.parts(from: sourceURL)
            if let credential { _ = try JSONDecoder().decode(AppleSMBCredentials.self, from: Data(credential.utf8)) }
        case .liveTV:
            _ = try AppleIPTVEndpointPolicy.normalize(sourceURL.absoluteString)
            if iptvType == .xtream {
                guard let credential else { throw AppleIPTVError.missingCredentials }
                let login = try JSONDecoder().decode(AppleIPTVCredentials.self, from: Data(credential.utf8))
                guard !login.username.isEmpty, !login.password.isEmpty else { throw AppleIPTVError.missingCredentials }
            }
        case .library: throw AppleMediaServerError.malformedResponse
        }
    }
}

struct AppleMediaServerSessionCloudSnapshot {
    let accountID: String
    var records: [UUID: AppleCloudMediaServerSession]
    var unavailableIDs: Set<UUID> = []
}

@MainActor
protocol AppleMediaServerSessionCloudStoring {
    func fetch() async throws -> AppleMediaServerSessionCloudSnapshot?
    func save(_ session: AppleCloudMediaServerSession, accountID: String) async throws
    func delete(_ sourceID: UUID, accountID: String) async throws
}

struct AppleMediaServerSessionMutation: Codable, Equatable {
    let revision: UUID
    let deleted: Bool
    let identity: String?
}

@MainActor
final class AppleMediaServerSessionSync {
    private struct State: Codable, Equatable {
        var accountID: String
        var seen: [UUID: String] = [:]
        var imported: [UUID: String] = [:]
        var lastAppliedEnabled: [UUID: Bool] = [:]
        var rejected: [UUID: String] = [:]
        var blocked: Set<UUID> = []

        init(accountID: String) { self.accountID = accountID }
        private enum CodingKeys: String, CodingKey { case accountID, seen, imported, lastAppliedEnabled, rejected, blocked }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accountID = try values.decode(String.self, forKey: .accountID)
            seen = try values.decodeIfPresent([UUID: String].self, forKey: .seen) ?? [:]
            imported = try values.decodeIfPresent([UUID: String].self, forKey: .imported) ?? [:]
            lastAppliedEnabled = try values.decodeIfPresent([UUID: Bool].self, forKey: .lastAppliedEnabled) ?? [:]
            rejected = try values.decodeIfPresent([UUID: String].self, forKey: .rejected) ?? [:]
            blocked = try values.decodeIfPresent(Set<UUID>.self, forKey: .blocked) ?? []
        }
    }

    private let sources: AppleSourceStore
    private let defaults: UserDefaults
    private let cloud: any AppleMediaServerSessionCloudStoring
    private let publishesSessions: Bool
    private let client: AppleMediaServerClient
    private let plexClient: ApplePlexClient
    private let trace: (String) -> Void
    private var state: State?
    private var syncing = false
    private let retryWait: @Sendable (Duration) async throws -> Void
    private var validationRetry: Task<Void, Never>?
    private var validationRetryAttempt = 0
    private var validationUnavailable = false
    private var requested = false
    private var requestedEnabled = true
    private var generation = UUID()
    private var retrySourceIDs: Set<UUID> = []
    private var recoveredSourceIDs: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastAttemptedMutations: [UUID: AppleMediaServerSessionMutation] = [:]
    nonisolated static let stateKey = "openstream.media-server-signins.sync.v1"
    nonisolated static let resetKey = "openstream.source-signins.delete-all.v1"

    private var mayRestore: Bool {
        requestedEnabled && !defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey)
    }

    private var restoreBlockReason: String {
        defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey) ? "restore-held" : "disabled"
    }

    var hasPendingLocalChanges: Bool {
        defaults.bool(forKey: Self.resetKey)
            || !sources.mediaServerSessionMutations.isEmpty && sources.mediaServerSessionMutations != lastAttemptedMutations
    }

    init(sources: AppleSourceStore, defaults: UserDefaults, cloud: any AppleMediaServerSessionCloudStoring,
         publishesSessions: Bool, client: AppleMediaServerClient = AppleMediaServerClient(),
         plexClient: ApplePlexClient = ApplePlexClient(), trace: @escaping (String) -> Void = { appleTrace($0) },
         retryWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sources = sources
        self.defaults = defaults
        self.cloud = cloud
        self.publishesSessions = publishesSessions
        self.client = client
        self.plexClient = plexClient
        self.trace = trace
        self.retryWait = retryWait
        state = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        for source in sources.sources where state?.imported[source.id] != nil
            && source.credentialReference?.hasPrefix("cloud-session.") == true
            && sources.mediaServerSessionMutations[source.id] == nil {
            if let entry = try? sources.cloudSourceCredentials(for: source) { state?.imported[source.id] = entry.fingerprint }
        }
        sources.refreshCloudSessionAfterUnauthorized = { [weak self] id in
            await self?.recoverAfterUnauthorized(id: id) ?? false
        }
    }

    deinit { validationRetry?.cancel() }

    private func cancelValidationRetry() {
        validationRetry?.cancel()
        validationRetry = nil
        validationRetryAttempt = 0
    }

    private func scheduleValidationRetry() {
        guard validationUnavailable, mayRestore, validationRetry == nil else { return }
        let delay = min(60, 2 << min(validationRetryAttempt, 5))
        validationRetryAttempt += 1
        let wait = retryWait
        let attemptGeneration = generation
        trace("source sign-in sync: validation retry scheduled seconds=\(delay)")
        validationRetry = Task { [weak self] in
            do { try await wait(.seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, let self, self.generation == attemptGeneration, self.mayRestore else { return }
            self.validationRetry = nil
            await self.synchronize()
        }
    }

    func accountChanged() {
        cancelValidationRetry()
        trace("source sign-in sync: account changed; restore held")
        generation = UUID()
        for (id, _) in state?.imported ?? [:] {
            guard sources.mediaServerSessionMutations[id]?.deleted != false else { continue }
            do { try sources.clearCloudSourceCredentials(id: id) }
            catch { trace("source sign-in sync: account credential cleanup unavailable code=\((error as NSError).code)") }
        }
        var updated = State(accountID: "")
        updated.blocked = Set(sources.sources.map(\.id))
        for (id, mutation) in sources.mediaServerSessionMutations {
            sources.completeMediaServerSessionMutation(id: id, revision: mutation.revision)
        }
        defaults.removeObject(forKey: Self.resetKey)
        defaults.set(true, forKey: AppleDeviceReset.cloudRestoreHeldKey)
        save(updated)
    }

    private func recoverAfterUnauthorized(id: UUID) async -> Bool {
        guard requestedEnabled else {
            trace("source sign-in sync: recovery skipped reason=disabled")
            return false
        }
        guard !defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey) else {
            trace("source sign-in sync: recovery skipped reason=restore-held")
            return false
        }
        guard AppleConfigurationSyncPolicy.isEnabled(storedPreference: AppleConfigurationSyncPolicy.storedPreference(in: defaults),
                mode: publishesSessions ? .viewerChoice : .automaticReadOnly) else {
            trace("source sign-in sync: recovery skipped reason=preference-disabled")
            return false
        }
        retrySourceIDs.insert(id)
        recoveredSourceIDs.remove(id)
        await synchronize()
        retrySourceIDs.remove(id)
        let recovered = recoveredSourceIDs.remove(id) != nil
        trace("source sign-in sync: recovery restored=\(recovered)")
        return recovered
    }

    func synchronize(enabled: Bool = true) async {
        let held = defaults.bool(forKey: AppleDeviceReset.cloudRestoreHeldKey)
        trace("source sign-in sync: start enabled=\(enabled) held=\(held) publishes=\(publishesSessions) sources=\(sources.sources.count)")
        requestedEnabled = enabled && !held
        if !requestedEnabled { cancelValidationRetry() }
        lastAttemptedMutations = sources.mediaServerSessionMutations
        guard !Task.isCancelled else {
            trace("source sign-in sync: stopped reason=cancelled")
            return
        }
        if syncing {
            requested = true
            trace("source sign-in sync: queued reason=already-syncing")
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        syncing = true
        defer {
            syncing = false
            if validationUnavailable { scheduleValidationRetry() }
            else { cancelValidationRetry() }
            let completed = waiters
            waiters.removeAll()
            for waiter in completed { waiter.resume() }
        }
        repeat {
            requested = false
            validationUnavailable = false
            do { try await reconcile(enabled: requestedEnabled) }
            catch is CancellationError { trace("source sign-in sync: stopped reason=cancelled") }
            catch {
                let failure = error as NSError
                trace("source sign-in sync: unavailable domain=\(failure.domain) code=\(failure.code)")
            }
        } while requested && !Task.isCancelled
    }

    private func reconcile(enabled: Bool) async throws {
        var imported = 0
        var validated = 0
        var enabledCount = 0
        var publishCandidates = 0
        var submitted = 0
        var deleted = 0
        var completedReaderDeletions: [UUID] = []
        if !publishesSessions {
            for (id, mutation) in sources.mediaServerSessionMutations where mutation.deleted {
                // Remember the current login as declined, without a permanent mutation tombstone.
                completedReaderDeletions.append(id)
                if var updated = state {
                    if let fingerprint = updated.imported[id] {
                        let date = sources.sources.first { $0.id == id }?.lastValidatedAt ?? .distantPast
                        updated.rejected[id] = AppleCloudMediaServerSession.version(fingerprint: fingerprint, validatedAt: date)
                    }
                    updated.imported[id] = nil
                    updated.lastAppliedEnabled[id] = nil
                    save(updated)
                }
                sources.completeMediaServerSessionMutation(id: id, revision: mutation.revision)
            }
            defaults.removeObject(forKey: Self.resetKey)
        }
        let hasDeletions = sources.mediaServerSessionMutations.values.contains { $0.deleted } || defaults.bool(forKey: Self.resetKey)
        let attemptGeneration = generation
        guard enabled || publishesSessions && hasDeletions else {
            trace("source sign-in sync: skipped reason=\(restoreBlockReason)")
            return
        }
        trace("source sign-in sync: fetch requested cleanup=\(!enabled)")
        guard var snapshot = try await cloud.fetch() else {
            trace("source sign-in sync: skipped reason=cloud-unavailable")
            return
        }
        trace("source sign-in sync: fetch records=\(snapshot.records.count) unreadable=\(snapshot.unavailableIDs.count)")
        guard generation == attemptGeneration else {
            trace("source sign-in sync: stopped reason=generation-changed-after-fetch")
            return
        }
        var next = state ?? State(accountID: snapshot.accountID)
        if !next.accountID.isEmpty, next.accountID != snapshot.accountID {
            accountChanged()
            trace("source sign-in sync: stopped reason=account-changed")
            return
        }
        next.accountID = snapshot.accountID
        for id in completedReaderDeletions {
            next.rejected[id] = snapshot.records[id]?.version ?? next.rejected[id]
            next.imported[id] = nil
            next.lastAppliedEnabled[id] = nil
        }
        defer { if generation == attemptGeneration { save(next) } }
        try Task.checkCancellation()

        if enabled && mayRestore {
            // Only credentials imported from this account may be revoked by its missing records.
            for (id, identity) in next.seen where snapshot.records[id] == nil && !snapshot.unavailableIDs.contains(id) {
                guard !snapshot.records.values.contains(where: { $0.identity == identity }) else { continue }
                for source in sources.sources where next.imported[source.id] != nil
                    && (source.mediaServerIdentity == identity || source.id == id) {
                    guard sources.mediaServerSessionMutations[source.id]?.deleted != false else { continue }
                    try sources.clearCloudSourceCredentials(id: source.id)
                    next.imported[source.id] = nil
                    next.lastAppliedEnabled[source.id] = nil
                    next.rejected[source.id] = nil
                }
            }
        }

        if publishesSessions {
            if defaults.bool(forKey: Self.resetKey) {
                for id in snapshot.records.keys {
                    try await cloud.delete(id, accountID: snapshot.accountID)
                    deleted += 1
                    guard generation == attemptGeneration else {
                        trace("source sign-in sync: stopped reason=generation-changed-after-reset")
                        return
                    }
                    snapshot.records[id] = nil
                }
                defaults.removeObject(forKey: Self.resetKey)
            }
            for (id, mutation) in sources.mediaServerSessionMutations where mutation.deleted {
                let matchingIDs = snapshot.records.values.filter { $0.identity == mutation.identity }.map(\.sourceID)
                for recordID in Set(matchingIDs + [id]) {
                    try Task.checkCancellation()
                    try await cloud.delete(recordID, accountID: snapshot.accountID)
                    deleted += 1
                    guard generation == attemptGeneration else {
                        trace("source sign-in sync: stopped reason=generation-changed-after-delete")
                        return
                    }
                    snapshot.records[recordID] = nil
                }
                sources.completeMediaServerSessionMutation(id: id, revision: mutation.revision)
                next.imported[id] = nil
                next.lastAppliedEnabled[id] = nil
            }
        }

        if enabled && mayRestore {
            var handledIdentities: Set<String> = []
            // Restore local shares and IPTV before any server round trip can suspend this import.
            let entries = snapshot.records.values.sorted {
                if ($0.session == nil) != ($1.session == nil) { return $0.session == nil }
                return $0.validatedAt > $1.validatedAt
            }
            for entry in entries {
                guard handledIdentities.insert(entry.identity).inserted else {
                    trace("source sign-in sync: import skipped reason=duplicate-identity")
                    continue
                }
                try Task.checkCancellation()
                guard generation == attemptGeneration, mayRestore else {
                    trace("source sign-in sync: stopped reason=\(generation != attemptGeneration ? "generation-changed-before-import" : restoreBlockReason)")
                    return
                }
                guard let source = sources.sources.first(where: { entry.matches($0) }) else {
                    trace("source sign-in sync: import skipped reason=no-matching-source")
                    continue
                }
                guard sources.mediaServerSessionMutations[source.id]?.deleted != true else {
                    trace("source sign-in sync: import skipped reason=local-deletion")
                    continue
                }
                let retrying = retrySourceIDs.contains(source.id)
                if sources.mediaServerSessionMutations[source.id]?.deleted == false && !retrying {
                    next.imported[source.id] = nil
                    next.lastAppliedEnabled[source.id] = nil
                    trace("source sign-in sync: import skipped reason=local-edit")
                    continue
                }
                let local = try sources.cloudSourceCredentials(for: source)
                if let local, !retrying {
                    if source.kind == .mediaServer {
                        guard next.imported[source.id] == local.fingerprint else {
                            trace("source sign-in sync: import skipped reason=local-sign-in")
                            continue
                        }
                        if local.fingerprint != entry.fingerprint && local.validatedAt > entry.validatedAt {
                            trace("source sign-in sync: import skipped reason=local-newer")
                            continue
                        }
                    }
                    if local.fingerprint == entry.fingerprint && next.lastAppliedEnabled[source.id] == entry.isEnabled {
                        trace("source sign-in sync: import skipped reason=unchanged")
                        continue
                    }
                }
                guard retrying || next.rejected[source.id] != entry.version else {
                    trace("source sign-in sync: import skipped reason=previously-rejected")
                    continue
                }
                do {
                    try entry.validate()
                    if let session = entry.session { try await client.validateSession(session, plexClient: plexClient) }
                    validated += 1
                    try Task.checkCancellation()
                    guard generation == attemptGeneration, mayRestore else {
                        trace("source sign-in sync: import skipped reason=\(generation != attemptGeneration ? "generation-changed-after-validation" : restoreBlockReason)")
                        continue
                    }
                    guard let currentSource = sources.sources.first(where: { $0.id == source.id }),
                          currentSource.configurationRevision == source.configurationRevision,
                          sources.mediaServerSessionMutations[source.id] == nil || retrying else {
                        trace("source sign-in sync: import skipped reason=source-changed-during-validation")
                        continue
                    }
                    try sources.installCloudSourceCredentials(entry, for: currentSource)
                    sources.didRestoreCloudCredentials()
                    trace("source sign-in sync: refresh restored sources")
                    imported += 1
                    if let restored = sources.sources.first(where: { $0.id == source.id }) {
                        if !currentSource.isEnabled && restored.isEnabled { enabledCount += 1 }
                        trace("source sign-in sync: credentials restored kind=\(restored.kind.rawValue) isEnabled=\(restored.isEnabled)"
                            + " needsSignIn=\(restored.needsSignIn) isEnabledAfterSignIn=\(restored.isEnabledAfterSignIn.map { String($0) } ?? "nil")")
                    }
                    next.imported[source.id] = entry.fingerprint
                    next.lastAppliedEnabled[source.id] = entry.isEnabled
                    next.rejected[source.id] = nil
                    if retrying { recoveredSourceIDs.insert(source.id) }
                } catch AppleMediaServerError.invalidCredentials {
                    next.rejected[source.id] = entry.version
                    trace("source sign-in sync: token rejected; existing credentials and cloud record retained")
                } catch {
                    try Task.checkCancellation()
                    validationUnavailable = true
                    trace("source sign-in sync: validation unavailable code=\((error as NSError).code); retry in background")
                }
            }
            trace("source sign-in sync: import validated=\(validated) imported=\(imported) enabled=\(enabledCount)")

            if publishesSessions {
                for source in sources.sources where source.kind != .library && !source.needsSignIn {
                    try Task.checkCancellation()
                    guard generation == attemptGeneration, mayRestore else {
                        trace("source sign-in sync: stopped reason=\(generation != attemptGeneration ? "generation-changed-before-publish" : restoreBlockReason)")
                        return
                    }
                    let mutation = sources.mediaServerSessionMutations[source.id]
                    guard mutation?.deleted != true, !retrySourceIDs.contains(source.id),
                          !next.blocked.contains(source.id) || mutation?.deleted == false else {
                        trace("source sign-in sync: publish skipped reason=\(mutation?.deleted == true ? "local-deletion" : retrySourceIDs.contains(source.id) ? "recovering" : "account-blocked")")
                        continue
                    }
                    guard let entry = try sources.cloudSourceCredentials(for: source) else {
                        trace("source sign-in sync: publish skipped reason=credentials-unavailable")
                        continue
                    }
                    if next.imported[source.id] == entry.fingerprint && mutation == nil {
                        trace("source sign-in sync: publish skipped reason=imported-sign-in")
                        continue
                    }
                    publishCandidates += 1
                    // A cached publication may belong to another CloudKit environment or a removed record.
                    if snapshot.records[source.id]?.fingerprint != entry.fingerprint
                        || snapshot.records[source.id]?.isEnabled != entry.isEnabled || mutation != nil {
                        trace("source sign-in sync: publish requested")
                        try await cloud.save(entry, accountID: snapshot.accountID)
                        submitted += 1
                        guard generation == attemptGeneration else {
                            trace("source sign-in sync: stopped reason=generation-changed-after-publish")
                            return
                        }
                        snapshot.records[source.id] = entry
                    } else { trace("source sign-in sync: publish skipped reason=unchanged") }
                    next.imported[source.id] = nil
                    next.lastAppliedEnabled[source.id] = entry.isEnabled
                    next.blocked.remove(source.id)
                    if let mutation { sources.completeMediaServerSessionMutation(id: source.id, revision: mutation.revision) }
                }
                trace("source sign-in sync: publish candidates=\(publishCandidates) submitted=\(submitted) deleted=\(deleted)")
            } else {
                for (id, mutation) in sources.mediaServerSessionMutations where !mutation.deleted {
                    next.imported[id] = nil
                    next.lastAppliedEnabled[id] = nil
                    sources.completeMediaServerSessionMutation(id: id, revision: mutation.revision)
                }
                // The Apple TV shares a sign-in only for a server iCloud has never held one for: the
                // owner signed in on a TV and expects the other TVs to have it. A record this device has
                // seen and that is gone now is a sign-out from another device, so it is never put back.
                for source in sources.sources where source.kind != .library && !source.needsSignIn {
                    try Task.checkCancellation()
                    guard generation == attemptGeneration, mayRestore else {
                        trace("source sign-in sync: stopped reason=\(generation != attemptGeneration ? "generation-changed-before-publish" : restoreBlockReason)")
                        return
                    }
                    guard next.imported[source.id] == nil, !next.blocked.contains(source.id),
                          let entry = try sources.cloudSourceCredentials(for: source),
                          !snapshot.records.values.contains(where: { $0.sourceID == source.id || $0.identity == entry.identity }),
                          next.seen[source.id] == nil, !next.seen.values.contains(entry.identity) else { continue }
                    publishCandidates += 1
                    trace("source sign-in sync: publish requested")
                    try await cloud.save(entry, accountID: snapshot.accountID)
                    submitted += 1
                    guard generation == attemptGeneration else {
                        trace("source sign-in sync: stopped reason=generation-changed-after-publish")
                        return
                    }
                    snapshot.records[source.id] = entry
                    next.seen[source.id] = entry.identity
                    next.lastAppliedEnabled[source.id] = entry.isEnabled
                }
                trace("source sign-in sync: publish read-only candidates=\(publishCandidates) submitted=\(submitted)")
            }
        } else {
            trace("source sign-in sync: restore skipped reason=\(restoreBlockReason)")
            if publishesSessions && hasDeletions {
                trace("source sign-in sync: publish candidates=0 submitted=0 deleted=\(deleted)")
            }
        }
        next.seen = snapshot.records.mapValues(\.identity).merging(
            next.seen.filter { snapshot.unavailableIDs.contains($0.key) }, uniquingKeysWith: { current, _ in current })
    }

    private func save(_ updated: State) {
        guard updated != state || defaults.data(forKey: Self.stateKey) == nil else {
            trace("source sign-in sync: state unchanged")
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(updated), forKey: Self.stateKey)
            state = updated
        } catch { trace("source sign-in sync: could not save local sync state code=\((error as NSError).code)") }
    }
}
