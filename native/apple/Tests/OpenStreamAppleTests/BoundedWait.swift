import Testing

/// Polls `condition` until it holds. After `limit` of real time it records an
/// issue naming `what` and returns, so a condition that never comes fails the
/// test instead of hanging the suite. It also returns once the test is
/// cancelled, so a suite's `.timeLimit` can always end it.
func waitFor(
    _ what: @autoclosure () -> String,
    limit: Duration = .seconds(20),
    sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation,
    until condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while await !condition(), !Task.isCancelled {
        guard ContinuousClock.now < deadline else {
            Issue.record("Gave up after \(limit) waiting for \(what())", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
