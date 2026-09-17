import Foundation

/// Remembers a browser that has already proved it was in the room.
///
/// The pairing code is shown on the television, so entering it proves physical
/// presence — which is a stronger claim than any password, and the reason this
/// does not ship a default one. The owner's actual complaint was the repetition
/// (2026-09-15: *"can we have them create an admin user so they don't need a
/// pairing code? usually default is like 1234"*), not the code itself: a
/// default credential that is never changed is a permanent way onto someone's
/// media sources from anywhere on the network, whereas a code on the screen
/// expires with the session.
///
/// So the code stays, and the repetition goes: a browser that enters it once is
/// issued a long-lived secret and is not asked again. Forgetting every browser
/// is one rotation away.
// Not `Sendable`: it holds a `UserDefaults`, and it is only ever used from the
// main-actor web server. Marking it `@unchecked Sendable` would be a claim
// about thread safety this type has no need to make.
public struct AppleWebManagementTrust {
    /// Long enough that a household browser is never asked twice in normal use,
    /// short enough that an abandoned laptop stops being trusted.
    public static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let cookieName = "openstream_trusted"

    private static let storageKey = "openstream.webmanagement.trust.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The current secret, minted on first use so a fresh install has one.
    public var secret: String {
        if let existing = defaults.string(forKey: Self.storageKey), !existing.isEmpty {
            return existing
        }
        let minted = AppleWebManagementProtocol.makeToken()
        defaults.set(minted, forKey: Self.storageKey)
        return minted
    }

    /// Whether this browser has paired before. Compared in constant time, like
    /// every other secret here.
    public func trusts(cookieHeader: String?) -> Bool {
        guard let presented = AppleWebManagementProtocol.cookieValue(
            Self.cookieName, in: cookieHeader
        ), !presented.isEmpty else { return false }
        return AppleWebManagementProtocol.secretsMatch(presented, secret)
    }

    /// Stops trusting every browser at once. The next visit needs the code
    /// again — this is the "sign everyone out" the pairing model otherwise
    /// lacks.
    public func forgetAllBrowsers() {
        defaults.set(AppleWebManagementProtocol.makeToken(), forKey: Self.storageKey)
    }

    /// The header that remembers this browser.
    public var cookieHeaderValue: String {
        "\(Self.cookieName)=\(secret); Max-Age=\(Int(Self.lifetime)); SameSite=Strict; HttpOnly; Path=/"
    }
}
