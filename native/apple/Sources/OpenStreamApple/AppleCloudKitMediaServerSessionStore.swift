import CloudKit
import CryptoKit
import Foundation

@MainActor
final class AppleCloudKitMediaServerSessionStore: AppleMediaServerSessionCloudStoring {
    private static let recordType = "MediaServerSignInV1"
    private static let zoneID = CKRecordZone.ID(zoneName: "MediaServerSignInsV1", ownerName: CKCurrentUserDefaultName)
    static let subscriptionID = "media-server-signins-v1"
    private static var zoneSetups: [String: Task<Void, any Error>] = [:]
    private static var setupGeneration = UUID()

    static func resetZoneSetup() {
        setupGeneration = UUID()
        for setup in zoneSetups.values { setup.cancel() }
        zoneSetups.removeAll()
    }

    static func prepareZone(accountID: String, setup: @escaping @MainActor () async throws -> Void) async throws {
        if let task = zoneSetups[accountID] {
            appleTrace("source sign-in sync: zone setup reused")
            return try await task.value
        }
        appleTrace("source sign-in sync: zone setup requested")
        let generation = setupGeneration
        let task = Task { try await setup() }
        zoneSetups[accountID] = task
        do { try await task.value }
        catch {
            if generation == setupGeneration { zoneSetups[accountID] = nil }
            throw error
        }
    }

    func fetch() async throws -> AppleMediaServerSessionCloudSnapshot? {
        appleTrace(AppleCloudKitSignInCapabilities.gateTrace)
        guard AppleCloudKitSignInCapabilities.isEntitled else { return nil }
        do { return try await fetchAvailableAccount() }
        catch let error as CKError where error.code == .missingEntitlement || error.code == .notAuthenticated {
            appleTrace("source sign-in sync: CloudKit unavailable reason=\(error.code == .missingEntitlement ? "missing-entitlement" : "not-authenticated") code=\(error.errorCode)")
            return nil
        }
    }

    static func accountUnavailableReason(_ status: CKAccountStatus) -> String? {
        switch status {
        case .available: nil
        case .couldNotDetermine: "could-not-determine"
        case .restricted: "restricted"
        case .noAccount: "no-account"
        case .temporarilyUnavailable: "temporarily-unavailable"
        @unknown default: "unknown"
        }
    }

    static func accountFingerprint(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchAvailableAccount() async throws -> AppleMediaServerSessionCloudSnapshot? {
        let container = CKContainer(identifier: AppleCloudKitSignInCapabilities.containerID)
        appleTrace("source sign-in sync: account status requested")
        let unavailable = Self.accountUnavailableReason(try await container.accountStatus())
        appleTrace("source sign-in sync: account status=\(unavailable ?? "available")")
        guard unavailable == nil else { return nil }
        appleTrace("source sign-in sync: account identity requested")
        let accountID = try await container.userRecordID().recordName
        appleTrace("source sign-in sync: account fingerprint=\(Self.accountFingerprint(accountID))")
        let database = container.privateCloudDatabase
        try await Self.prepareZone(accountID: accountID) {
            _ = try await database.save(CKRecordZone(zoneID: Self.zoneID))
            do {
                // A zone subscription works in the private database without relying on a recordType filter.
                let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.subscriptionID)
                let notification = CKSubscription.NotificationInfo()
                notification.shouldSendContentAvailable = true
                subscription.notificationInfo = notification
                _ = try await database.save(subscription)
            } catch {
                appleTrace("source sign-in sync: subscription unavailable code=\((error as NSError).code); using foreground fetch")
            }
        }
        appleTrace("source sign-in sync: zone ready")
        var records: [UUID: AppleCloudMediaServerSession] = [:]
        var unavailableIDs: Set<UUID> = []
        var token: CKServerChangeToken?
        var moreComing = true
        while moreComing {
            appleTrace("source sign-in sync: fetch page requested")
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            let decoded = Self.decodeRecords(changes.modificationResultsByID.mapValues { $0.map { $0.record } })
            records.merge(decoded.records, uniquingKeysWith: { _, newest in newest })
            unavailableIDs.formUnion(decoded.unavailableIDs)
            for deletion in changes.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) {
                    records[id] = nil
                    unavailableIDs.remove(id)
                }
            }
            token = changes.changeToken
            moreComing = changes.moreComing
        }
        return AppleMediaServerSessionCloudSnapshot(accountID: accountID, records: records, unavailableIDs: unavailableIDs)
    }

    static func decodeRecords(_ results: [CKRecord.ID: Result<CKRecord, any Error>])
        -> (records: [UUID: AppleCloudMediaServerSession], unavailableIDs: Set<UUID>) {
        var records: [UUID: AppleCloudMediaServerSession] = [:]
        var unavailableIDs: Set<UUID> = []
        for (id, result) in results {
            do {
                let record = try result.get()
                guard record.recordType == recordType else {
                    appleTrace("source sign-in sync: record skipped reason=unknown-type")
                    continue
                }
                let entry = try session(from: record)
                records[entry.sourceID] = entry
            } catch {
                if let sourceID = UUID(uuidString: id.recordName) { unavailableIDs.insert(sourceID) }
                appleTrace("source sign-in sync: skipped unreadable record code=\((error as NSError).code)")
            }
        }
        return (records, unavailableIDs)
    }

    func save(_ session: AppleCloudMediaServerSession, accountID: String) async throws {
        let database = try await database(for: accountID)
        let current: CKRecord?
        do { current = try await database.record(for: Self.recordID(session.sourceID)) }
        catch let error as CKError where error.code == .unknownItem { current = nil }
        if let current, let existing = try? Self.session(from: current), existing.validatedAt >= session.validatedAt {
            appleTrace("source sign-in sync: publish skipped reason=cloud-newer-or-equal")
            return
        }
        let record = try Self.record(for: session, replacing: current)
        do { try await save(record, database: database) }
        catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.serverRecord,
                  try Self.session(from: server).validatedAt < session.validatedAt else {
                appleTrace("source sign-in sync: publish skipped reason=cloud-conflict-newer-or-equal")
                return
            }
            try await save(Self.record(for: session, replacing: server), database: database)
        }
    }

    private func save(_ record: CKRecord, database: CKDatabase) async throws {
        let results = try await database.modifyRecords(saving: [record], deleting: [],
            savePolicy: .ifServerRecordUnchanged, atomically: true)
        for result in results.saveResults.values { _ = try result.get() }
    }

    func delete(_ sourceID: UUID, accountID: String) async throws {
        let database = try await database(for: accountID)
        do { _ = try await database.deleteRecord(withID: Self.recordID(sourceID)) }
        catch let error as CKError where error.code == .unknownItem {
            appleTrace("source sign-in sync: delete skipped reason=record-absent")
            return
        }
    }

    private func database(for accountID: String) async throws -> CKDatabase {
        guard AppleCloudKitSignInCapabilities.isEntitled else {
            appleTrace(AppleCloudKitSignInCapabilities.gateTrace)
            throw CKError(.missingEntitlement)
        }
        let container = CKContainer(identifier: AppleCloudKitSignInCapabilities.containerID)
        let unavailable = Self.accountUnavailableReason(try await container.accountStatus())
        appleTrace("source sign-in sync: write account status=\(unavailable ?? "available")")
        guard unavailable == nil else { throw CKError(.notAuthenticated) }
        guard try await container.userRecordID().recordName == accountID else {
            appleTrace("source sign-in sync: write stopped reason=account-changed")
            throw CKError(.notAuthenticated)
        }
        return container.privateCloudDatabase
    }

    private static func recordID(_ sourceID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: sourceID.uuidString.lowercased(), zoneID: zoneID)
    }

    static func record(for entry: AppleCloudMediaServerSession, replacing existing: CKRecord? = nil) throws -> CKRecord {
        try entry.validate()
        let record = existing ?? CKRecord(recordType: recordType, recordID: recordID(entry.sourceID))
        for key in record.encryptedValues.allKeys() { record.encryptedValues[key] = nil }
        record.encryptedValues["payload"] = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self) as NSString
        return record
    }

    static func session(from record: CKRecord) throws -> AppleCloudMediaServerSession {
        guard let id = UUID(uuidString: record.recordID.recordName) else { throw AppleMediaServerError.malformedResponse }
        if let payload = record.encryptedValues["payload"] as? String {
            let entry = try JSONDecoder().decode(AppleCloudMediaServerSession.self, from: Data(payload.utf8))
            guard entry.sourceID == id else { throw AppleMediaServerError.malformedResponse }
            try entry.validate()
            return entry
        }
        // Read build 20's media-server-only records until their next validated login replaces them.
        guard let token = record.encryptedValues["accessToken"] as? String, !token.isEmpty,
              let userID = record.encryptedValues["userID"] as? String, !userID.isEmpty,
              let identity = record.encryptedValues["identity"] as? String,
              let address = record.encryptedValues["baseURL"] as? String, let url = URL(string: address),
              let kindValue = record.encryptedValues["kind"] as? String,
              let kind = AppleMediaServerKind(rawValue: kindValue) else { throw AppleMediaServerError.malformedResponse }
        let entry = AppleCloudMediaServerSession(sourceID: id, session: AppleMediaServerSession(
            kind: kind, baseURL: url, accessToken: token, userID: userID,
            serverID: record.encryptedValues["serverID"] as? String), validatedAt: record.modificationDate ?? .distantPast)
        guard entry.identity == identity else { throw AppleMediaServerError.malformedResponse }
        try entry.validate()
        return entry
    }
}

@MainActor
public enum AppleMediaServerSignInNotifications {
    static var refresh: (() async -> Void)?
    public static var canRegisterForPush: Bool { AppleCloudKitSignInCapabilities.permitsPush }

    @discardableResult
    public static func receive(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID == AppleCloudKitMediaServerSessionStore.subscriptionID,
              let refresh else { return false }
        await refresh()
        return true
    }

    public static func registrationFailed() {
        appleTrace("source sign-in sync: push unavailable; using foreground fetch")
    }
}
