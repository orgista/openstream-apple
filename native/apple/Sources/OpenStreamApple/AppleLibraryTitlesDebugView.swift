#if DEBUG
import SwiftUI

/// Headless verification enters the production Folder scanner and Library views.
public struct AppleLibraryTitlesDebugView: View {
    @State private var sources: AppleSourceStore
    @State private var settings = AppleSettingsStore()
    @State private var index = AppleMediaIndexStore()

    public init() {
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
            AppleLibraryView(sourceStore: sources, mediaIndex: index, settings: settings, openSettings: {})
                .navigationTitle("Library")
        }.preferredColorScheme(.dark).tint(.white)
    }
}
#endif
