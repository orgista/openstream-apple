import Foundation

/// The home presentation contract shared by Discover and Library.
enum AppleHomePresentationPolicy {
    enum Platform { case iOS, mac, tv, vision }
    enum Hero { case phone, pad, mac, tv, rotating }

    static func hero(platform: Platform, compact: Bool = false, landscape: Bool = false,
                     accessibility: Bool = false, isLargeLayout: Bool = false) -> Hero {
        switch platform {
        case .mac: .mac
        case .tv: .tv
        case .iOS where isLargeLayout: accessibility ? .rotating : .pad
        case .vision: accessibility ? .rotating : .pad
        case .iOS: compact && !landscape ? .phone : .rotating
        }
    }

    static func rows(hero: Hero, width: CGFloat, inset: CGFloat, isLargeLayout: Bool = false) -> AppleDiscoverRowStyle? {
        if isLargeLayout { return .pad(contentWidth: width) }
        return switch hero {
        case .phone: .phone
        case .mac: .mac(contentWidth: width, inset: inset)
        default: nil
        }
    }
}
