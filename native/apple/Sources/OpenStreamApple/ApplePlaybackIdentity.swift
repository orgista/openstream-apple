import CryptoKit
import Foundation

/// Produces opaque, deterministic persistence keys without writing a media
/// URL, local path, or provider identifier into UserDefaults or cache names.
public enum ApplePlaybackIdentity {
    private static let prefix = "sha256:"
    private static let hexadecimal = Array("0123456789abcdef".utf8)

    public static func storageKey(for mediaID: String) -> String? {
        let normalized = mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if isStorageKey(normalized) { return normalized }
        return prefix + digest(for: normalized)
    }

    public static func storageKey(for url: URL) -> String {
        let value = url.isFileURL
            ? url.standardizedFileURL.absoluteString
            : url.absoluteString
        return prefix + digest(for: value)
    }

    public static func digest(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        var result: [UInt8] = []
        result.reserveCapacity(64)
        for byte in digest {
            result.append(hexadecimal[Int(byte >> 4)])
            result.append(hexadecimal[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    public static func isStorageKey(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
