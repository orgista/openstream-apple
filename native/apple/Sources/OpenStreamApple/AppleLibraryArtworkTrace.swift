import Foundation

@MainActor
final class AppleLibraryArtworkTrace {
    static let shared = AppleLibraryArtworkTrace()
    private let clock: any AppleClock
    private let record: (String) -> Void
    private var startedAt: ContinuousClock.Instant?
    private var catalogIDs: Set<String> = []
    private var cards: [UUID: (catalogID: String, hasPoster: Bool)] = [:]
    private var firstPosterShown = false
    private var checkpoints: Task<Void, Never>?
    var isActive: Bool { startedAt != nil }

    init(clock: any AppleClock = AppleSystemClock(), record: @escaping (String) -> Void = { AppleArtworkTrace.record($0) }) {
        self.clock = clock
        self.record = record
    }

    deinit { checkpoints?.cancel() }

    func start() {
        stop()
        let startedAt = clock.now
        self.startedAt = startedAt
        record("cold-library scan-start")
        checkpoints = Task { [weak self, clock] in
            for seconds in [10, 30] {
                do { try await clock.sleep(until: startedAt.advanced(by: .seconds(seconds))) }
                catch { return }
                guard !Task.isCancelled, let self, self.startedAt == startedAt else { return }
                let placeholders = cards.values.filter { !$0.hasPoster }.count
                record("cold-library checkpoint seconds=\(seconds) scan_ms=\(elapsedMilliseconds) cards=\(cards.count) placeholders=\(placeholders)")
                if seconds == 30 { stop() }
            }
        }
    }

    func stop() {
        checkpoints?.cancel()
        checkpoints = nil
        startedAt = nil
        catalogIDs.removeAll()
        cards.removeAll()
        firstPosterShown = false
    }

    func updateCatalogIDs(_ ids: Set<String>) {
        guard isActive else { return }
        catalogIDs = ids
        cards = cards.filter { ids.contains($0.value.catalogID) }
    }

    // Count mounted Library cards, including Home; cache fills are not shown posters.
    func cardAppeared(_ card: UUID, catalogID: String, hasPoster: Bool) {
        guard isActive, catalogIDs.contains(catalogID) else { return }
        cards[card] = (catalogID, hasPoster)
        if hasPoster { posterShown(card) }
    }

    func cardDisappeared(_ card: UUID) {
        cards[card] = nil
    }

    func posterShown(_ card: UUID) {
        guard cards[card] != nil, isActive else { return }
        cards[card]?.hasPoster = true
        guard !firstPosterShown else { return }
        firstPosterShown = true
        record("cold-library first-poster scan_ms=\(elapsedMilliseconds)")
    }

    func posterChanged(_ card: UUID, hasPoster: Bool) {
        guard cards[card] != nil else { return }
        cards[card]?.hasPoster = hasPoster
        if hasPoster { posterShown(card) }
    }

    private var elapsedMilliseconds: Int64 {
        startedAt.map { AppleLaunchMarks.milliseconds($0.duration(to: clock.now)) } ?? 0
    }
}
