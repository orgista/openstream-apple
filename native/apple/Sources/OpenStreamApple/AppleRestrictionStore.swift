import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AppleRestrictionStore {
    static let shared = AppleRestrictionStore()
    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
    }
    private(set) var policy: AppleRestrictionPolicy
    private(set) var hasPIN = false
    private(set) var sessionUnlocked = false
    private(set) var prompt: Prompt?
    private(set) var error: String?
    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: any AppleCredentialStoring
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var protectedPlayers: [ObjectIdentifier: () -> Void] = [:]
    private static let storageKey = "openstream.restrictions.device.v1"
    private static let account = "pin-verifier"

    init(defaults: UserDefaults = .standard, credentials: any AppleCredentialStoring = AppleRestrictionKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        policy = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(AppleRestrictionPolicy.self, from: $0) } ?? .init()
        do { hasPIN = try credentials.string(for: Self.account) != nil }
        catch { hasPIN = true; self.error = "Could not read the PIN." }
    }

    private static func digest(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + ":" + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func setPIN(_ pin: String) throws {
        guard AppleRestrictionPolicy.validPIN(pin), !hasPIN || sessionUnlocked else { throw AppleKeychainStoreError.invalidData }
        let salt = UUID().uuidString
        try credentials.set(salt + ":" + Self.digest(pin, salt: salt), for: Self.account)
        hasPIN = true
        sessionUnlocked = true
        revision &+= 1
    }
    func update(_ change: (inout AppleRestrictionPolicy) -> Void) {
        guard hasPIN && sessionUnlocked else { return }
        change(&policy)
        defaults.set(try? JSONEncoder().encode(policy), forKey: Self.storageKey)
        revision &+= 1
    }
    func needsUnlock(channelID: String, group: String) -> Bool {
        hasPIN && !sessionUnlocked && policy.isLocked(channelID: channelID, group: group)
    }
    var settingsLocked: Bool { hasPIN && policy.lockSettings && !sessionUnlocked }

    func authorize(channelID: String, group: String, title: String, settings: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard hasPIN && !sessionUnlocked && (settings || policy.isLocked(channelID: channelID, group: group)) else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                if prompt == nil { error = nil; prompt = Prompt(title: title) }
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(returning: false)
                if self.waiters.isEmpty { self.prompt = nil }
            }
        }
    }
    @discardableResult func submit(_ pin: String) -> Bool {
        guard AppleRestrictionPolicy.validPIN(pin) else { error = "Enter four digits."; return false }
        do {
            guard let record = try credentials.string(for: Self.account) else { error = "Could not read the PIN."; return false }
            let parts = record.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { error = "Could not read the PIN."; return false }
            let candidate = Array(Self.digest(pin, salt: String(parts[0])).utf8)
            let saved = Array(parts[1].utf8)
            guard candidate.count == saved.count,
                  zip(candidate, saved).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                error = "Incorrect PIN."; return false
            }
            sessionUnlocked = true
            error = nil
            complete(true)
            revision &+= 1
            return true
        } catch { self.error = "Could not read the PIN."; return false }
    }
    func cancelPrompt() { error = nil; complete(false) }
    private func complete(_ result: Bool) {
        let pending = waiters.values
        waiters.removeAll()
        prompt = nil
        for continuation in pending { continuation.resume(returning: result) }
    }
    func protect(_ coordinator: ApplePlaybackCoordinator) {
        protectedPlayers[ObjectIdentifier(coordinator)] = { [weak coordinator] in coordinator?.stop() }
    }
    func background() {
        sessionUnlocked = false
        complete(false)
        let players = protectedPlayers.values
        protectedPlayers.removeAll()
        for stop in players { stop() }
        revision &+= 1
    }
    func removeRestrictions() throws {
        try credentials.remove(Self.account)
        defaults.removeObject(forKey: Self.storageKey)
        policy = .init()
        hasPIN = false
        sessionUnlocked = false
        error = nil
        complete(false)
        revision &+= 1
    }
}
