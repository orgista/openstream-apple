import Foundation

struct AppleTVScrubInput {
    static let secondsPerStep: Double = 10
    private static let pointsPerStep: Double = 40
    private static let radiansPerStep = Double.pi / 4
    private var consumedTranslation: Double = 0
    private var previousX = 0.0
    private var previousY = 0.0
    private var tangent: Double?
    private var rotation = 0.0
    private var isRotating = false
    private var isTouchActive = false
    private var suppressDirectionsUntil: ContinuousClock.Instant?

    mutating func begin() { isTouchActive = true }

    mutating func move(translation: Double) -> Double? {
        guard translation.isFinite else { return nil }
        let steps = ((translation - consumedTranslation) / Self.pointsPerStep).rounded(.towardZero)
        guard steps != 0 else { return nil }
        consumedTranslation += steps * Self.pointsPerStep
        return steps * Self.secondsPerStep
    }

    mutating func move(x: Double, y: Double) -> Double? {
        guard x.isFinite, y.isFinite else { return nil }
        let dx = x - previousX
        let dy = y - previousY
        guard hypot(dx, dy) >= 1 else { return nil }
        previousX = x
        previousY = y
        let angle = atan2(dy, dx)
        if let tangent {
            // The tangent turns once per clickpad revolution, independent of its radius.
            var turn = angle - tangent
            if turn > .pi { turn -= 2 * .pi }
            if turn < -.pi { turn += 2 * .pi }
            // A straight swipe reversing direction is not a half-turn of the ring.
            if abs(turn) < .pi / 2 { rotation += turn }
        }
        tangent = angle
        if abs(rotation) >= Self.radiansPerStep { isRotating = true }
        guard isRotating else { return move(translation: x) }
        let steps = (rotation / Self.radiansPerStep).rounded(.towardZero)
        guard steps != 0 else { return nil }
        rotation -= steps * Self.radiansPerStep
        return steps * Self.secondsPerStep
    }

    func directionalStep(_ direction: Double, now: ContinuousClock.Instant = .now) -> Double? {
        guard !isTouchActive, suppressDirectionsUntil.map({ now >= $0 }) ?? true else { return nil }
        return direction * Self.secondsPerStep
    }

    mutating func end(now: ContinuousClock.Instant = .now) {
        self = Self(suppressDirectionsUntil: now.advanced(by: .milliseconds(200)))
    }
}
