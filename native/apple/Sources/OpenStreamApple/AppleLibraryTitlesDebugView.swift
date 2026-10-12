#if DEBUG
import SwiftUI

/// Headless verification enters the production Folder scanner and Library views.
public struct AppleLibraryTitlesDebugView: View {
    @State private var sources: AppleSourceStore
    @State private var settings = AppleSettingsStore()
    /// Its own index file: fixture records never reach the real media index.
    @State private var index = AppleMediaIndexStore(repository: AppleMediaIndexRepository(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "library-titles-fixture-index.json")))
    @State private var catalogs = AppleCatalogStore()

    public init() {
        AppleLocalLibraryStore.persistsScanResults = false
        let defaults = UserDefaults(suiteName: "openstream.library-titles-fixture")!
        let path = ProcessInfo.processInfo.environment["OPENSTREAM_LIBRARY_FIXTURE_PATH"]
        if defaults.string(forKey: "fixture.path") != path {
            defaults.removeObject(forKey: "openstream.sources.v1")
            defaults.set(path, forKey: "fixture.path")
        }
        let store = AppleSourceStore(defaults: defaults)
        if let path {
            _ = try? store.addLibraryFolder(name: "Media", url: URL(fileURLWithPath: path), bookmarkData: nil)
        }
        _sources = State(initialValue: store)
    }

    public var body: some View {
        NavigationStack {
            AppleLibraryView(catalogStore: catalogs, sourceStore: sources, mediaIndex: index, settings: settings, openSettings: {})
                .navigationTitle("Library")
        }.preferredColorScheme(.dark).tint(.white)
        // The app's root starts the scan; this fixture replaces the root.
        .task { await AppleLocalLibraryStore.shared.reload(sourceStore: sources, mediaIndex: index, settings: settings) }
        #if os(macOS)
        // The window shot hangs off the app's normal root, which this
        // fixture replaces; without it the fixture cannot be reviewed headless.
        .task {
            guard let request = AppleMacWindowShot.request() else { return }
            await AppleMacWindowShot.run(request)
        }
        #endif
    }
}
#endif
