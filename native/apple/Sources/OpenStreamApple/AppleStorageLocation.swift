import Foundation

/// Where the app keeps files that should outlive a launch.
///
/// Apple TV hardware refuses writes to Application Support and Documents
/// ("You don't have permission to save the file “OpenStream” in the folder
/// “Application Support”", build 17, 2026-10-09). Only Caches and tmp are
/// writable there; user defaults, the keychain and iCloud are the only storage
/// the system keeps. The tvOS simulator allows both folders, so simulators
/// never showed it. Every file under these folders on Apple TV must therefore
/// rebuild itself or be mirrored to defaults/iCloud when the system purges it.
///
/// Always resolve these folders through here, never through
/// `FileManager.urls(for: .applicationSupportDirectory …)` directly.
public enum AppleStorageLocation {
    public enum Kind: Sendable, CaseIterable {
        /// Application Support everywhere but Apple TV.
        case applicationSupport
        /// Documents everywhere but Apple TV.
        case documents
    }

    public enum Platform: Sendable {
        case appleTV, other

        public static var current: Platform {
            #if os(tvOS)
            .appleTV
            #else
            .other
            #endif
        }
    }

    /// The folder `kind` resolves to on `platform`. Pure, so it is tested for
    /// Apple TV on any machine.
    public static func searchPath(for kind: Kind, on platform: Platform = .current) -> FileManager.SearchPathDirectory {
        switch (platform, kind) {
        case (.appleTV, _): .cachesDirectory
        case (.other, .applicationSupport): .applicationSupportDirectory
        case (.other, .documents): .documentDirectory
        }
    }

    /// This device's folder for `kind`; tmp when the system names none. On
    /// Apple TV it is a subfolder of Caches named after `kind`, so it never
    /// shares a folder with the real caches that Clear Cache empties.
    public static func directory(_ kind: Kind, on platform: Platform = .current,
                                 fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: searchPath(for: kind, on: platform), in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        guard platform == .appleTV else { return root }
        return root.appending(path: appleTVFolder(for: kind), directoryHint: .isDirectory)
    }

    static func appleTVFolder(for kind: Kind) -> String {
        switch kind {
        case .applicationSupport: "Application Support"
        case .documents: "Documents"
        }
    }

    public static var applicationSupport: URL { directory(.applicationSupport) }
    public static var documents: URL { directory(.documents) }
}
