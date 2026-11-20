import Foundation

struct AppleHomeRowSetting: Identifiable, Hashable {
    let id: String
    let defaultName: String
    var isService = false

    static func rows(serverRows: [AppleDiscoverServerRows.Row]) -> [Self] {
        AppleDiscoverRowOrder.builtInIDs.compactMap { id in
            AppleDiscoverRowOrder.title(forBuiltIn: id).map { Self(id: id, defaultName: $0) }
        } + serverRows.filter { $0.id.hasPrefix(AppleDiscoverRowOrder.serverPrefix) }
            .map { Self(id: $0.id, defaultName: $0.title) }
    }

    static func services(shelves: [AppleMediaServerLibraryStore.Shelf]) -> [Self] {
        let detected = Set(shelves.compactMap { AppleDiscoverServerRows.streamingService(in: $0.title) })
        return detected.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { Self(id: $0.rawValue, defaultName: $0.displayName, isService: true) }
    }

    @MainActor func title(in settings: AppleSettingsStore) -> String {
        AppleDiscoverRowOrder.title(for: id, defaultTitle: defaultName, customNames: settings.homeRowNames)
    }

    @MainActor func isShown(in settings: AppleSettingsStore) -> Bool {
        !(isService ? settings.homeServicesHidden : settings.homeRowsHidden).contains(id)
    }

    @MainActor func setShown(_ shown: Bool, in settings: AppleSettingsStore) {
        if isService {
            if shown { settings.homeServicesHidden.remove(id) } else { settings.homeServicesHidden.insert(id) }
        } else {
            if shown { settings.homeRowsHidden.remove(id) } else { settings.homeRowsHidden.insert(id) }
        }
    }

    func customName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultName ? nil : trimmed
    }

    @MainActor func setName(_ name: String, in settings: AppleSettingsStore) {
        let value = customName(name)
        guard settings.homeRowNames[id] != value else { return }
        settings.homeRowNames[id] = value
    }

    @MainActor static func resetAll(in settings: AppleSettingsStore) {
        settings.homeRowsHidden = []
        settings.homeRowNames = [:]
        settings.homeServicesHidden = []
    }
}
