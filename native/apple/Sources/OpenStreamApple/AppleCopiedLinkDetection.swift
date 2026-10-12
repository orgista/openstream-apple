#if os(iOS)
import UIKit

/// Pattern detection reads no pasteboard value and does not trigger a paste permission prompt.
enum AppleCopiedLinkDetection {
    @MainActor
    static func detect() async -> Bool {
        let detected = await withCheckedContinuation { continuation in
            UIPasteboard.general.detectPatterns(for: [\.probableWebURL], completionHandler: completion(continuation))
        }
        // On an iPhone a link copied in Safari (Copy, share sheet) is a URL item that
        // pattern detection reports as no web URL (DevPlus, 2026-10-06). `hasURLs`
        // still says a link is there, and it reads no value either.
        let hasURLs = UIPasteboard.general.hasURLs
        appleTrace("copied link detected=\(detected) hasURLs=\(hasURLs)")
        return detected || hasURLs
    }

    // UIKit invokes this completion off the main actor. Creating it in a nonisolated
    // function avoids Swift 6 inheriting the view's actor and asserting at runtime.
    nonisolated private static func completion(_ continuation: CheckedContinuation<Bool, Never>)
        -> (Result<Set<PartialKeyPath<UIPasteboard.DetectedValues>>, any Error>) -> Void {
        { result in
            if case .failure(let error) = result { appleTrace("copied link detection failed: \((error as NSError).code)") }
            continuation.resume(returning: (try? result.get().contains(\.probableWebURL)) == true)
        }
    }
}
#endif
