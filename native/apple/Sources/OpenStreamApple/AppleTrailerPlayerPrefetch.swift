#if os(iOS) || os(visionOS)
import AVFoundation
import UIKit
import WebKit

/// Loads the next hero page's trailer player while the current page shows,
/// after the Apple TV app's prefetch player (REA round 3, 2026-10-17, §1.2):
/// one hidden web view opens the trailer's embed with playback blocked, so
/// YouTube's player page and scripts are in the shared cache when that page
/// asks for its trailer. Skipped when trailers would not autoplay anyway, and
/// during AirPlay, as Apple's is.
@MainActor
final class AppleTrailerPlayerPrefetch: NSObject, WKNavigationDelegate {
    static let shared = AppleTrailerPlayerPrefetch()

    /// One non-persistent store for every trailer web view and the prefetch,
    /// so what one fetched is cached for the next. Gone when the app quits,
    /// as each per-view store was.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    /// Whether a prefetch may run now: the conditions that let a trailer play by itself.
    static func mayPrefetch(autoPlaySetting: Bool) -> Bool {
        AppleHeroTrailerGate.allowsVideo(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                         systemVideoAutoplay: UIAccessibility.isVideoAutoplayEnabled, pressed: false)
            && autoPlaySetting && !UIAccessibility.isReduceMotionEnabled
            && !AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    private var webView: WKWebView?
    private var prefetchedKey: String?
    private var teardown: Task<Void, Never>?

    func prefetch(key: String) {
        guard key != prefetchedKey, let url = AppleTrailerPreviewPolicy.embedURL(for: key) else { return }
        cancel()
        prefetchedKey = key
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: url))
        appleTrace("hero trailer prefetch \(key)")
        scheduleTeardown(after: .seconds(10))
    }

    /// The page has loaded; its scripts get a moment to fetch the player.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleTeardown(after: .seconds(3))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        prefetchedKey = nil
        cancel()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        prefetchedKey = nil
        cancel()
    }

    private func scheduleTeardown(after delay: Duration) {
        teardown?.cancel()
        teardown = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.cancel()
        }
    }

    private func cancel() {
        teardown?.cancel()
        teardown = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }
}
#endif
