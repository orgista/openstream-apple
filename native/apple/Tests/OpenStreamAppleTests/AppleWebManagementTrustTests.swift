import Foundation
import Testing
@testable import OpenStreamApple

/// Owner 2026-09-15: *"can we have them create an admin user so they don't need
/// a pairing code? usually default is like 1234"*.
///
/// The answer is to keep the code — it is shown on the television, so entering
/// it proves presence in the room, which a default password never does — and
/// remove the repetition instead. A browser that enters it once is remembered.
@Suite("Web Management trusted browsers")
struct AppleWebManagementTrustTests {
    private func store(_ name: String = UUID().uuidString) -> (AppleWebManagementTrust, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        return (AppleWebManagementTrust(defaults: defaults), defaults)
    }

    @Test func aSecretIsMintedOnceAndThenReused() {
        let (trust, defaults) = store()
        let first = trust.secret
        #expect(!first.isEmpty)
        #expect(trust.secret == first)
        // A second instance over the same storage agrees, so a restart does not
        // silently un-trust every browser.
        #expect(AppleWebManagementTrust(defaults: defaults).secret == first)
    }

    @Test func onlyTheRightCookieIsTrusted() {
        let (trust, _) = store()
        #expect(trust.trusts(cookieHeader: "openstream_trusted=\(trust.secret)"))
        #expect(!trust.trusts(cookieHeader: nil))
        #expect(!trust.trusts(cookieHeader: ""))
        #expect(!trust.trusts(cookieHeader: "openstream_trusted="))
        #expect(!trust.trusts(cookieHeader: "openstream_trusted=wrong"))
        // A different cookie of the right shape must not be mistaken for it.
        #expect(!trust.trusts(cookieHeader: "openstream_token=\(trust.secret)"))
    }

    @Test func theCookieIsFoundAlongsideOthers() {
        let (trust, _) = store()
        let header = "theme=dark; openstream_token=abc; openstream_trusted=\(trust.secret); other=1"
        #expect(trust.trusts(cookieHeader: header))
    }

    @Test func forgettingBrowsersStopsTrustingTheOldCookie() {
        let (trust, _) = store()
        let old = trust.secret
        trust.forgetAllBrowsers()
        #expect(trust.secret != old)
        #expect(!trust.trusts(cookieHeader: "openstream_trusted=\(old)"))
        #expect(trust.trusts(cookieHeader: "openstream_trusted=\(trust.secret)"))
    }

    @Test func theCookieCarriesTheProtectionsASecretNeeds() {
        let (trust, _) = store()
        let value = trust.cookieHeaderValue
        // Not readable from script, not sent cross-site, scoped to the portal,
        // and long-lived enough to be worth having.
        #expect(value.contains("HttpOnly"))
        #expect(value.contains("SameSite=Strict"))
        #expect(value.contains("Path=/"))
        #expect(value.contains("Max-Age=\(Int(AppleWebManagementTrust.lifetime))"))
        #expect(AppleWebManagementTrust.lifetime == 30 * 24 * 60 * 60)
    }

    @Test func namedCookiesAreReadIndependently() {
        #expect(AppleWebManagementProtocol.cookieValue("a", in: "a=1; b=2") == "1")
        #expect(AppleWebManagementProtocol.cookieValue("b", in: "a=1; b=2") == "2")
        #expect(AppleWebManagementProtocol.cookieValue("c", in: "a=1; b=2") == nil)
        #expect(AppleWebManagementProtocol.cookieValue("a", in: nil) == nil)
        // Cookie names are case-insensitive in practice.
        #expect(AppleWebManagementProtocol.cookieValue("A", in: "a=1") == "1")
    }
}
