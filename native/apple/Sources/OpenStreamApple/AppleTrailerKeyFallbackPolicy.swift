import Foundation

/// Which trailer to try after YouTube refuses one.
///
/// Errors 101 and 150 mean the video's owner blocked embedding, and 100 that
/// the video is gone or private: the video is the problem, not the player,
/// so the next key the metadata named may still play. Each remaining key is
/// tried once, in order, before the art is left alone. Any other error keeps
/// the old behaviour for the caller (the hero gives up).
enum AppleTrailerKeyFallbackPolicy {
    static let videoUnavailableErrorCodes: Set<Int> = [100, 101, 150]

    static func triesNextKey(errorCode: Int?) -> Bool {
        guard let errorCode else { return false }
        return videoUnavailableErrorCodes.contains(errorCode)
    }

    /// The next key's index, or nil when this error does not move on or no
    /// key is left.
    static func nextKeyIndex(after index: Int, errorCode: Int?, keyCount: Int) -> Int? {
        guard triesNextKey(errorCode: errorCode), index >= 0 else { return nil }
        let next = index + 1
        return next < keyCount ? next : nil
    }

    /// The keys in the order they are tried: a pressed key first, then the
    /// metadata's own, each once.
    static func orderedKeys(preferred: String?, keys: [String]) -> [String] {
        var seen = Set<String>()
        return ([preferred].compactMap { $0 } + keys).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
