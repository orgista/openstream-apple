import Foundation

/// The home presentation contract shared by Discover and Library.
enum AppleHomePresentationPolicy {
    enum Platform { case phone, pad, mac, tv, vision }
    enum Hero { case phone, pad, mac, tv, rotating }

    static func hero(platform: Platform, compact: Bool = false, landscape: Bool = false,
                     accessibility: Bool = false) -> Hero {
        switch platform {
        case .mac: .mac
        case .tv: .tv
        case .vision: .rotating
        case .pad: accessibility ? .rotating : .pad
        case .phone: compact && !landscape ? .phone : .rotating
        }
    }

    static func rows(hero: Hero, width: CGFloat, inset: CGFloat) -> AppleDiscoverRowStyle? {
        switch hero {
        case .phone: .phone
        case .mac: .mac(contentWidth: width, inset: inset)
        default: nil
        }
    }
}
