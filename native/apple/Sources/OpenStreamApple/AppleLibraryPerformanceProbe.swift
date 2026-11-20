#if DEBUG && os(tvOS)
import UIKit

/// Same opt-in frame-arrival measurement for the cold-load and scroll comparisons.
@MainActor
final class AppleLibraryPerformanceProbe: NSObject {
    static let shared = AppleLibraryPerformanceProbe()
    private var link: CADisplayLink?
    private var previous: CFTimeInterval?
    private var reportStart: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var longest: CFTimeInterval = 0
    private var posters = Set<String>()
    private var stalls: [(epoch: Int64, milliseconds: Int)] = []

    func startIfRequested() {
        guard link == nil, UserDefaults.standard.bool(forKey: "OpenStreamLibraryPerfProbe") else { return }
        reportStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func posterReady(_ id: String) {
        guard link != nil, posters.insert(id).inserted else { return }
        let elapsed = AppleLaunchMarks.launchAge().map(AppleLaunchMarks.milliseconds) ?? -1
        appleTrace("library.perf.poster count=\(posters.count) launch_ms=\(elapsed)")
    }

    func metadataPublished(_ count: Int) {
        guard link != nil else { return }
        let elapsed = AppleLaunchMarks.launchAge().map(AppleLaunchMarks.milliseconds) ?? -1
        appleTrace("library.perf.metadata count=\(count) launch_ms=\(elapsed)")
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previous {
            let gap = now - previous
            longest = max(longest, gap)
            if gap > max(0.033, link.duration * 2) {
                hitches += 1
                stalls.append((Int64(Date().timeIntervalSince1970 * 1000), Int((gap - link.duration) * 1000)))
            }
        }
        previous = now
        frames += 1
        if now - reportStart >= 5 {
            let events = stalls.map { "\($0.epoch):\($0.milliseconds)" }.joined(separator: ",")
            appleTrace("library.perf epoch=\(Date().timeIntervalSince1970) frames=\(frames) hitches=\(hitches) longest_ms=\(Int(longest * 1000)) stalls=\(events)")
            reportStart = now
            frames = 0; hitches = 0; longest = 0
            stalls.removeAll(keepingCapacity: true)
        }
    }
}
#endif
