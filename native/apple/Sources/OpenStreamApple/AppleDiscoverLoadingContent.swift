import SwiftUI
import CoreFoundation

/// Static surface shapes occupy the same hero slot and rail gutters as content.
/// No timers or animation, including when Reduce Motion is enabled.
struct AppleDiscoverLoadingContent: View {
    let presentation: AppleHomePresentationPolicy.Hero
    let viewport: CGSize
    let phoneLayout: AppleHomePhoneHeroLayout
    let wideLayout: AppleMacHeroLayout
    let rowStyle: AppleDiscoverRowStyle?

    private var heroHeight: CGFloat {
        switch presentation {
        case .tv: AppleTVBillboardMetrics.artHeight
        case .phone: phoneLayout.artHeight
        case .mac, .pad: wideLayout.height
        case .rotating:
            #if os(tvOS)
            AppleTVBillboardMetrics.artHeight
            #else
            AppleFeaturedHeroMetrics.artHeight(viewport: viewport)
            #endif
        }
    }

    private var topOverlap: CGFloat {
        switch presentation {
        case .phone: phoneLayout.topOverlap
        case .mac, .pad: wideLayout.topOverlap
        default: 0
        }
    }

    private var bottomOverlap: CGFloat {
        switch presentation {
        case .tv: AppleTVBillboardMetrics.rowOverlap
        case .phone: AppleHomePhoneHeroLayout.trailingOverlap
        default: 0
        }
    }

    var body: some View {
        Rectangle()
            .fill(AppleDesignTokens.surface)
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .padding(.top, -topOverlap)
            .padding(.bottom, -bottomOverlap)
            #if os(tvOS)
            .padding(.horizontal, -AppleTVChromeMetrics.horizontalSafeInset)
            #elseif !os(macOS)
            .padding(.horizontal, presentation == .rotating ? 16 : 0)
            #endif
        ForEach(0..<3) { index in
            AppleDiscoverLoadingRail(landscape: index == 0, rowStyle: rowStyle, sizing: index == 1 ? .portraitPromo : nil)
        }
    }
}

/// Keeps the first deck hidden until its hero and visible row artwork are decoded.
enum AppleDiscoverLaunchHold: Equatable {
    case restoring
    case warmingHero
    case released

    enum Content { case blank, hidden, page }

    static func content(_ hold: Self) -> Content {
        switch hold {
        case .restoring: .blank
        case .warmingHero: .hidden
        case .released: .page
        }
    }
}

enum AppleDiscoverLaunchReadiness {
    enum Decision: Equatable { case waiting, ready, failed }

    static func decision(artwork: [Bool?], wordmark: Bool?, hasWordmark: Bool,
        lookupPending: Bool = false, timedOut: Bool) -> Decision {
        if timedOut { return .failed }
        guard !lookupPending, artwork.allSatisfy({ $0 != nil }), !hasWordmark || wordmark != nil else { return .waiting }
        return artwork.contains(false) || (hasWordmark && wordmark == false) ? .failed : .ready
    }
}

/// Matches the cache variants the hidden first viewport is drawing, including the trimmed wordmark.
struct AppleDiscoverLaunchArtwork: View {
    let requests: [AppleArtworkPrefetchPolicy.Request]
    let wordmark: URL?
    let wordmarkSize: CGSize
    let wordmarkLookupPending: Bool
    let onSettled: (_ wordmarkFailed: Bool, _ timedOut: Bool) -> Void
    @State private var results: [AppleArtworkPrefetchPolicy.Request: Bool] = [:]
    @State private var wordmarkResult: Bool?
    @State private var timedOut = false

    private var decision: AppleDiscoverLaunchReadiness.Decision {
        AppleDiscoverLaunchReadiness.decision(artwork: requests.map { results[$0] },
            wordmark: wordmarkResult, hasWordmark: wordmark != nil,
            lookupPending: wordmarkLookupPending, timedOut: timedOut)
    }

    var body: some View {
        ZStack {
            ForEach(requests, id: \.self) { request in
                AppleRemoteImage(url: request.url, placeholderSystemImage: "",
                    onLoad: { _ in results[request] = true }, onFailure: { results[request] = false },
                    fixedPixelDimension: request.maximumPixelDimension, priority: .foreground)
                    .frame(width: 1, height: 1)
            }
            if let wordmark {
                AppleTrimmedTitleLogo(url: wordmark) { wordmarkResult = $0 }
                    .frame(width: wordmarkSize.width, height: wordmarkSize.height)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            do { try await Task.sleep(for: AppleHeroPageSwap.artTimeout) } catch { return }
            timedOut = true
        }
        .task(id: decision) {
            guard decision != .waiting else { return }
            // Let the actual hero and row publish their shared cache results before revealing them.
            await withCheckedContinuation { continuation in
                let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                    CFRunLoopActivity.afterWaiting.rawValue, false, 0) { observer, _ in
                        CFRunLoopObserverInvalidate(observer)
                        continuation.resume()
                    }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            guard !Task.isCancelled else { return }
            onSettled(wordmark != nil && wordmarkResult != true, timedOut)
        }
    }
}

/// The billboard still the last launch drew, read back as soon as Discover
/// appears, alongside the saved deck. Asked for only once the hidden page was
/// built, the test Apple TV's still queued its disk read and decode behind the first rows'
/// tiles and decoded ~170 ms after the deck, past the hold's limit, in 5 of 6
/// launches (polish-1107). A different hero from the deck costs one decode.
enum AppleLaunchHeroStill {
    private static let key = "openstream.discover.launchHeroStill.v1"

    static func remember(_ request: AppleArtworkPrefetchPolicy.Request, defaults: UserDefaults = .standard) {
        guard saved(defaults: defaults) != request else { return }
        defaults.set(["url": request.url.absoluteString, "pixels": request.maximumPixelDimension], forKey: key)
    }

    static func saved(defaults: UserDefaults = .standard) -> AppleArtworkPrefetchPolicy.Request? {
        guard let entry = defaults.dictionary(forKey: key), let text = entry["url"] as? String,
              let url = URL(string: text), let pixels = entry["pixels"] as? Int else { return nil }
        return .init(url: url, maximumPixelDimension: pixels)
    }

    static func warm() async {
        guard let still = saved() else { return }
        _ = try? await AppleRemoteImageCache.shared.image(url: still.url, maximumPixelDimension: still.maximumPixelDimension,
                                                          priority: .foreground)
    }
}
