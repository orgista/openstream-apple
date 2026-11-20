import Foundation

@MainActor
final class AppleDiscoverRailCache<Value> {
    struct Key: Equatable {
        var recommendationsPublication = 0
        var serverRowsPublication = 0
        var chartPublication = 0
        var libraryRevision = 0
        var servicesRevision: UInt64 = 0
        var sources: [AppleSource] = []
        var order: [AppleDiscoverView.DiscoverRail] = []
        var hiddenRows: Set<String> = []
        var rowNames: [String: String] = [:]
        var hiddenServices: Set<String> = []
        var top10Enabled = false
        var top10Available = false
    }

    private var key: Key?
    private var prepared: Value?

    func value(for key: Key, build: () -> Value) -> Value {
        if self.key == key, let prepared { return prepared }
        let value = build()
        self.key = key
        prepared = value
        return value
    }
}
