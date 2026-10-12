import Foundation

/// Where this install came from, read from the receipt Apple leaves in the
/// bundle: App Store installs carry a `receipt`, DEBUG builds usually none, and
/// a `sandboxReceipt` is carried by TestFlight installs **and** by the build
/// App Review runs. No runtime signal tells those two apart, so nothing that
/// must stay out of the reviewer's build may key off this; such behaviour is
/// compiled in DEBUG only (`AppleTestCatalogSeedPolicy`).
public enum AppleBuildChannel {
    /// TestFlight or App Review. Used only for the local interaction trace's
    /// default, which writes to the app's own Caches and never leaves the
    /// device unless the user shares it.
    public static var hasSandboxReceipt: Bool {
        isSandboxReceipt(Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }

    public static func isSandboxReceipt(_ lastPathComponent: String?) -> Bool {
        lastPathComponent == "sandboxReceipt"
    }
}

/// Whether this build pre-adds the testers' catalogs. DEBUG only: a Release
/// archive (TestFlight, App Review, App Store) starts with no sources at all,
/// and does not even contain the catalog addresses.
///
/// The addresses are not in the source tree either (a configured add-on URL
/// is a login token). A debug run seeds the stremio entries of the owner's
/// private dev-sources file (`scripts/dev-sources.py`), found through the
/// `-OpenStreamDevSources <path>` launch argument or the
/// `OPENSTREAM_DEV_SOURCES` environment variable (an Xcode scheme setting).
/// No file, nothing seeded. Testers on TestFlight add add-ons the way users
/// do: paste the address, Web Management, or a backup.
public enum AppleTestCatalogSeedPolicy {
    /// Environment variable naming the dev-sources file a debug run seeds from.
    public static let devSourcesEnvironmentKey = "OPENSTREAM_DEV_SOURCES"

    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func seedsTestCatalogs(isDebugBuild: Bool) -> Bool {
        isDebugBuild
    }

    /// The catalogs a build starts with: the dev-sources add-ons in a DEBUG
    /// build, nothing in Release whatever is passed in.
    public static func manifests(isDebugBuild: Bool, devSourceManifests: [String]) -> [String] {
        guard isDebugBuild else { return [] }
        #if DEBUG
        return devSourceManifests
        #else
        return []
        #endif
    }

    /// The dev-sources file a debug run seeds from: the launch argument wins,
    /// then the environment variable; `nil` when neither is set.
    public static func devSourcesPath(launchArgument: String?, environment: [String: String]) -> String? {
        if let path = launchArgument?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty { return path }
        if let path = environment[devSourcesEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty { return path }
        return nil
    }

    #if DEBUG
    /// The stremio manifest addresses of a dev-sources file, in file order,
    /// without duplicates. Other kinds (IPTV, shares, media servers) are not
    /// seeded here: they carry credentials and are added by
    /// `AppleDevSourcesImport` when the file is handed over at launch.
    static func devSourceManifests(in data: Data) -> [String] {
        guard let file = try? AppleDevSourcesPolicy.decode(data) else { return [] }
        var seen = Set<String>()
        return file.sources.compactMap { source in
            guard case .stremio(_, let manifestURL) = source, !manifestURL.isEmpty,
                  seen.insert(manifestURL).inserted else { return nil }
            return manifestURL
        }
    }

    /// Reads the file at `path`. The file is only read, never moved or
    /// deleted; the import flow deletes its own copy.
    static func devSourceManifests(fileAt path: String?) -> [String] {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return [] }
        return devSourceManifests(in: data)
    }

    /// What this process seeds, resolved once per launch.
    static let debugManifests: [String] = devSourceManifests(fileAt: devSourcesPath(
        launchArgument: UserDefaults.standard.string(forKey: AppleDevSourcesPolicy.launchKey),
        environment: ProcessInfo.processInfo.environment))
    #endif
}
