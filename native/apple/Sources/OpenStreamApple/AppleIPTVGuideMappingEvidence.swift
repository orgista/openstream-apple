import Foundation

/// Durable evidence for a local channel's guide assignment. Coverage describes
/// actual cached intervals, not a promise that the whole enclosing window is filled.
public struct AppleIPTVGuideMappingEvidence: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case manual, providerID, name }
    public let providerID: String
    public let declaredProviderID: String?
    public let origin: Origin
    public let confidence: Double
    public let defaultOffsetHours: Double
    public let channelShiftHours: Double
    public let correctionHours: Double
    public let fetchedAt: Date
    public var coverage: [DateInterval]
    public var isStale: Bool

    public var appliedShiftHours: Double { channelShiftHours + correctionHours }

    static func resolve(id: String, declaredID: String?, manualID: String?, name: String,
                        uniqueName: Bool, index: AppleIPTVGuideMatching.Index, available: Set<String>,
                        previous: Self?, defaultOffsetHours: Double = 0,
                        channelShiftHours: Double = 0, correctionHours: Double = 0,
                        fetchedAt: Date) -> Self? {
        let target: String
        let origin: Origin
        let confidence: Double
        if let manualID {
            target = manualID
            origin = .manual
            confidence = 1
        } else if available.contains(declaredID ?? id) {
            target = declaredID ?? id
            origin = .providerID
            confidence = 1
        } else if let previous, previous.origin != .manual, (uniqueName || previous.origin != .name), available.contains(previous.providerID) {
            target = previous.providerID
            origin = previous.origin
            confidence = previous.confidence
        } else if let match = index.match(id: declaredID ?? id, name: uniqueName ? name : "") {
            target = match.channelID
            origin = match.confidence == 1 ? .providerID : .name
            confidence = match.confidence
        } else { return nil }
        return Self(providerID: target, declaredProviderID: declaredID, origin: origin,
                    confidence: confidence, defaultOffsetHours: finite(defaultOffsetHours),
                    channelShiftHours: finite(channelShiftHours), correctionHours: finite(correctionHours),
                    fetchedAt: fetchedAt, coverage: [], isStale: !available.contains(target))
    }

    static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    func project(_ programmes: [AppleIPTVProgramme], channelID: String) -> [AppleIPTVProgramme] {
        programmes.map { programme in
            AppleIPTVProgramme(id: "\(channelID):\(programme.id)", channelID: channelID, title: programme.title,
                subtitle: programme.subtitle, description: programme.description,
                start: programme.start.addingTimeInterval(appliedShiftHours * 3600),
                end: programme.end.addingTimeInterval(appliedShiftHours * 3600),
                category: programme.category, isLive: programme.isLive)
        }
    }

    /// An empty response retains the same station with current shifts and the original fetch time.
    static func replacement(providerProgrammes: [AppleIPTVProgramme], channelID: String,
                            evidence: Self, previousProgrammes: [AppleIPTVProgramme],
                            previousEvidence: Self?) -> (programmes: [AppleIPTVProgramme], evidence: Self) {
        if providerProgrammes.isEmpty, let previousEvidence,
           previousEvidence.providerID == evidence.providerID, !previousProgrammes.isEmpty {
            let delta = (evidence.appliedShiftHours - previousEvidence.appliedShiftHours) * 3600
            let programmes = previousProgrammes.map { programme in
                AppleIPTVProgramme(id: programme.id, channelID: programme.channelID, title: programme.title,
                    subtitle: programme.subtitle, description: programme.description,
                    start: programme.start.addingTimeInterval(delta), end: programme.end.addingTimeInterval(delta),
                    category: programme.category, isLive: programme.isLive)
            }
            let retained = Self(providerID: evidence.providerID, declaredProviderID: evidence.declaredProviderID,
                origin: evidence.origin, confidence: evidence.confidence, defaultOffsetHours: evidence.defaultOffsetHours,
                channelShiftHours: evidence.channelShiftHours, correctionHours: evidence.correctionHours,
                fetchedAt: previousEvidence.fetchedAt, coverage: coverage(of: programmes), isStale: true)
            return (programmes, retained)
        }
        let programmes = evidence.project(providerProgrammes, channelID: channelID)
        var updated = evidence
        updated.coverage = coverage(of: programmes)
        return (programmes, updated)
    }

    static func coverage(of programmes: [AppleIPTVProgramme]) -> [DateInterval] {
        var result: [DateInterval] = []
        for programme in programmes.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, programme.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, programme.end))
            } else { result.append(DateInterval(start: programme.start, end: programme.end)) }
        }
        return result
    }
}
