import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Disc images that took the app down while the engine was opening them.
///
/// A malformed disc can crash the engine's disc reader, and the title page
/// offers it again on the next launch. Infuse refuses such an item ("seems to
/// be crashing, won't open it", REA 2026-10-17); so does this. A mark is
/// written before each disc open and cleared when the open returns, so a mark
/// found at launch is a disc whose open never returned. The app leaving the
/// foreground clears the mark too, so swiping it away mid-open is not a crash.
/// The refusal lasts for this build: an update may have fixed the reader.
@MainActor
final class AppleDiscCrashGuard {
    static let shared = AppleDiscCrashGuard()

    static let refusalMessage = "oStream closed while opening this disc last time, so it won't open it again."
    static let openingKey = "OpenStreamDiscOpening"
    static let crashedKey = "OpenStreamCrashedDiscs"
    static let remembered = 20

    private let defaults: UserDefaults
    private let build: String
    private var crashed: [String]

    init(defaults: UserDefaults = .standard,
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
        self.defaults = defaults
        self.build = build
        crashed = defaults.stringArray(forKey: Self.crashedKey) ?? []
        if let interrupted = defaults.string(forKey: Self.openingKey) {
            defaults.removeObject(forKey: Self.openingKey)
            if !crashed.contains(interrupted) {
                crashed = Array((crashed + [interrupted]).suffix(Self.remembered))
                defaults.set(crashed, forKey: Self.crashedKey)
            }
        }
        #if canImport(UIKit)
        // Queue .main delivers on the main thread, where this guard lives.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaults.removeObject(forKey: Self.openingKey) }
        }
        #endif
    }

    /// The guard's name for a disc request's file; nil for anything else.
    func key(for request: ApplePlaybackRequest) -> String? {
        guard request.hints.disc != nil, !request.isLive else { return nil }
        return "\(build)|\((request.hints.libraryFileURL ?? request.url).absoluteString)"
    }

    func refuses(_ key: String) -> Bool { crashed.contains(key) }

    func opening(_ key: String) { defaults.set(key, forKey: Self.openingKey) }

    /// Only the disc being opened clears the mark; a newer open owns it.
    func opened(_ key: String) {
        guard defaults.string(forKey: Self.openingKey) == key else { return }
        defaults.removeObject(forKey: Self.openingKey)
    }
}
