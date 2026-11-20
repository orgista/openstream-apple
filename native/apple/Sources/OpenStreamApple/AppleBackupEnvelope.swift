import CryptoKit
import Foundation

/// The backup file (format 2): a short readable header and one AES-GCM box
/// holding the whole configuration with every sign-in. Nothing else is in
/// clear: no source names, hosts, counts or dates.
///
/// Sealed with the Apple Account's backup key from iCloud Keychain
/// (`AppleBackupKeyStoring`) by default, so any device on that account imports
/// it without a prompt; or with a key derived from a passphrase, for a device
/// on another Apple Account. Files from before this format are plain
/// `AppleConfigurationFile`s and still import.
struct AppleBackupEnvelope: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case iCloudKey = "icloudKey"
        case passphrase
    }

    struct Payload: Codable, Equatable, Sendable {
        var snapshot: AppleConfigurationSnapshot
        var secrets: AppleConfigurationSecrets
    }

    static let magicValue = "OSBK"
    static let currentVersion = 2
    static let passphraseRounds: UInt32 = 600_000

    let magic: String
    let version: Int
    let mode: Mode
    /// First 8 bytes of the key's SHA-256, hex. Tells "another account's key"
    /// apart from a damaged file without revealing anything about the key.
    let keyID: String?
    let salt: Data?
    let rounds: UInt32?
    let sealed: Data

    /// The header when `data` is a format-2 backup; nil for any other file.
    static func header(of data: Data) -> Self? {
        guard let envelope = try? JSONDecoder().decode(Self.self, from: data),
              envelope.magic == magicValue else { return nil }
        return envelope
    }

    static func keyID(for key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func seal(_ payload: Payload, key: SymmetricKey) throws -> Data {
        try seal(payload, key: key, mode: .iCloudKey, keyID: keyID(for: key), salt: nil, rounds: nil)
    }

    static func seal(_ payload: Payload, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw AppleConfigurationError.passphraseRequired }
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let key = try AppleConfigurationFile.deriveKey(passphrase, salt: salt)
        return try seal(payload, key: key, mode: .passphrase, keyID: nil, salt: salt, rounds: passphraseRounds)
    }

    @concurrent static func sealData(_ payload: Payload, passphrase: String) async throws -> Data {
        try seal(payload, passphrase: passphrase)
    }

    /// Opens with the iCloud key or the passphrase, whichever the file's mode
    /// asks for. `otherAppleAccount` when the file wants a key this device
    /// does not hold; `passphraseRequired`/`wrongPassphrase` for a passphrase file.
    func open(key: SymmetricKey?, passphrase: String) throws -> Payload {
        guard magic == Self.magicValue else { throw AppleConfigurationError.invalidFile }
        guard version == Self.currentVersion else { throw AppleConfigurationError.unsupportedVersion }
        switch mode {
        case .iCloudKey:
            guard let key, keyID == Self.keyID(for: key) else { throw AppleConfigurationError.otherAppleAccount }
            do { return try openBox(with: key) } catch { throw AppleConfigurationError.invalidFile }
        case .passphrase:
            guard !passphrase.isEmpty else { throw AppleConfigurationError.passphraseRequired }
            guard let salt, salt.count == 32, rounds == Self.passphraseRounds else {
                throw AppleConfigurationError.invalidFile
            }
            do {
                return try openBox(with: AppleConfigurationFile.deriveKey(passphrase, salt: salt))
            } catch { throw AppleConfigurationError.wrongPassphrase }
        }
    }

    @concurrent func openData(key: SymmetricKey?, passphrase: String) async throws -> Payload {
        try open(key: key, passphrase: passphrase)
    }

    private static func seal(_ payload: Payload, key: SymmetricKey, mode: Mode, keyID: String?,
                             salt: Data?, rounds: UInt32?) throws -> Data {
        try payload.snapshot.validate()
        let header = Self(magic: magicValue, version: currentVersion, mode: mode, keyID: keyID,
                          salt: salt, rounds: rounds, sealed: Data())
        let box = try AES.GCM.seal(AppleConfigurationSnapshot.encoder.encode(payload), using: key,
                                   authenticating: header.authenticatedData)
        guard let combined = box.combined else { throw AppleConfigurationError.invalidFile }
        let file = Self(magic: magicValue, version: currentVersion, mode: mode, keyID: keyID,
                        salt: salt, rounds: rounds, sealed: combined)
        return try AppleConfigurationSnapshot.encoder.encode(file)
    }

    private func openBox(with key: SymmetricKey) throws -> Payload {
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key,
                                    authenticating: authenticatedData)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        try payload.snapshot.validate()
        return payload
    }

    /// The header, bound to the box so no field can be swapped.
    private var authenticatedData: Data {
        Data([magic, String(version), mode.rawValue, keyID ?? "", salt?.base64EncodedString() ?? "",
              rounds.map(String.init) ?? ""].joined(separator: "|").utf8)
    }
}

/// Where the Apple Account's backup key lives.
protocol AppleBackupKeyStoring: Sendable {
    /// The key this device holds, nil when there is none (yet).
    func existingKey() throws -> SymmetricKey?
    /// The key to seal an export with: the existing one, or a new one saved
    /// first. Throws `backupKeyUnavailable` when no key can be kept.
    func exportKey() throws -> SymmetricKey
}

/// One 256-bit key per Apple Account, a synchronizable generic password in
/// iCloud Keychain, made on the first export.
struct AppleICloudBackupKeychain: AppleBackupKeyStoring {
    static let defaultService = "com.orgista.openstream.backup-key"
    private static let account = "backup-key.v1"
    private let store: AppleKeychainStore

    init(service: String = Self.defaultService) {
        store = AppleKeychainStore(service: service, alwaysSynchronizable: true)
    }

    func existingKey() throws -> SymmetricKey? {
        guard let text = try store.string(for: Self.account),
              let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func exportKey() throws -> SymmetricKey {
        if let key = try? existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        let text = key.withUnsafeBytes { Data($0).base64EncodedString() }
        do { try store.set(text, for: Self.account) } catch { throw AppleConfigurationError.backupKeyUnavailable }
        // A review build's keychain writes nothing; read back so that case asks too.
        guard let saved = try? existingKey(), Self.same(saved, key) else {
            throw AppleConfigurationError.backupKeyUnavailable
        }
        return saved
    }

    private static func same(_ lhs: SymmetricKey, _ rhs: SymmetricKey) -> Bool {
        AppleBackupEnvelope.keyID(for: lhs) == AppleBackupEnvelope.keyID(for: rhs)
    }
}

/// What the import sheet knows about a file before Import.
struct AppleBackupPreview: Sendable {
    /// Readable now (a plain old file, or sealed with this account's key).
    let snapshot: AppleConfigurationSnapshot?
    let needsPassphrase: Bool
    /// Why this device cannot open the file at all.
    let failure: AppleConfigurationError?
}
