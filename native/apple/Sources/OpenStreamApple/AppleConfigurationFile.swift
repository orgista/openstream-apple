import CommonCrypto
import CryptoKit
import Foundation

public struct AppleConfigurationSecrets: Codable, Equatable, Sendable {
    public var sourceCredentials: [UUID: String] = [:]
    public var sourceAddresses: [UUID: URL] = [:]
    public var guideAddresses: [UUID: URL] = [:]
    public var settingsCredentials: [String: String] = [:]
    public var privateSettings: [String: Data] = [:]

    public init(sourceCredentials: [UUID: String] = [:], sourceAddresses: [UUID: URL] = [:],
                guideAddresses: [UUID: URL] = [:], settingsCredentials: [String: String] = [:],
                privateSettings: [String: Data] = [:]) {
        self.sourceCredentials = sourceCredentials
        self.sourceAddresses = sourceAddresses
        self.guideAddresses = guideAddresses
        self.settingsCredentials = settingsCredentials
        self.privateSettings = privateSettings
    }
}

public struct AppleConfigurationFile: Codable, Sendable {
    public var snapshot: AppleConfigurationSnapshot
    var encryption: EncryptedCredentials?

    struct EncryptedCredentials: Codable, Sendable {
        let algorithm: String
        let rounds: UInt32
        let salt: Data
        let sealed: Data
    }

    public static func encode(snapshot: AppleConfigurationSnapshot,
                              secrets: AppleConfigurationSecrets = .init(), passphrase: String = "") throws -> Data {
        try snapshot.validate()
        var portable = snapshot
        portable.sources = snapshot.sources.map(AppleConfigurationSnapshot.portableSource)
        var file = Self(snapshot: portable)
        if !passphrase.isEmpty {
            let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let key = try deriveKey(passphrase, salt: salt)
            let sealed = try AES.GCM.seal(AppleConfigurationSnapshot.encoder.encode(secrets), using: key,
                authenticating: AppleConfigurationSnapshot.encoder.encode(portable))
            guard let combined = sealed.combined else { throw AppleConfigurationError.invalidFile }
            file.encryption = .init(algorithm: "PBKDF2-SHA256-AES256-GCM", rounds: 600_000, salt: salt, sealed: combined)
        }
        return try AppleConfigurationSnapshot.encoder.encode(file)
    }

    public static func inspect(_ data: Data) throws -> Self {
        guard data.count <= 10_000_000 else { throw AppleConfigurationError.tooLarge }
        let file = try JSONDecoder().decode(Self.self, from: data)
        try file.snapshot.validate()
        return file
    }

    public var isEncrypted: Bool { encryption != nil }

    public static func decode(_ data: Data, passphrase: String = "") throws
        -> (snapshot: AppleConfigurationSnapshot, secrets: AppleConfigurationSecrets?) {
        let file = try inspect(data)
        guard let encryption = file.encryption else { return (file.snapshot, nil) }
        guard !passphrase.isEmpty else { throw AppleConfigurationError.passphraseRequired }
        guard encryption.algorithm == "PBKDF2-SHA256-AES256-GCM", encryption.rounds == 600_000,
              encryption.salt.count == 32 else { throw AppleConfigurationError.invalidFile }
        do {
            let key = try deriveKey(passphrase, salt: encryption.salt)
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encryption.sealed), using: key,
                authenticating: AppleConfigurationSnapshot.encoder.encode(file.snapshot))
            return (file.snapshot, try JSONDecoder().decode(AppleConfigurationSecrets.self, from: data))
        } catch { throw AppleConfigurationError.wrongPassphrase }
    }

    @concurrent static func exportData(snapshot: AppleConfigurationSnapshot,
                                      secrets: AppleConfigurationSecrets, passphrase: String) async throws -> Data {
        try encode(snapshot: snapshot, secrets: secrets, passphrase: passphrase)
    }

    @concurrent static func importData(_ data: Data, passphrase: String) async throws
        -> (snapshot: AppleConfigurationSnapshot, secrets: AppleConfigurationSecrets?) {
        try decode(data, passphrase: passphrase)
    }

    static func deriveKey(_ passphrase: String, salt: Data) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &key, 32)
            }
        }
        guard status == kCCSuccess else { throw AppleConfigurationError.invalidFile }
        return SymmetricKey(data: key)
    }
}
