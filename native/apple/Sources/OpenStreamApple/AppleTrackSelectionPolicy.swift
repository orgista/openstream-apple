/// Which audio track the transport's menu checks.
enum AppleTrackSelectionPolicy {
    /// The viewer's unconfirmed pick wins over the engine's report: until the
    /// rebuilt pipeline lands, the engine still names the old track. Once
    /// there is no pick pending, the engine's report is the truth; when the
    /// engine cannot say, the last known value stays.
    static func audio(engineActive: Int?, pending: Int?, current: Int?) -> Int? {
        if let pending { return pending }
        return engineActive ?? current
    }
}
