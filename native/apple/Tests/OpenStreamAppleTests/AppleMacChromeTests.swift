import Foundation
import Testing
@testable import OpenStreamApple

/// The Mac window's own metrics, and the two constants that decide whether a
/// macOS screen is laid out at all.
@Suite("Mac chrome")
struct AppleMacChromeTests {
    @Test("A window narrower than 760 pt keeps the stacked layout")
    func narrowWindowIsNotRegular() {
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 700, height: 500)) == false)
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 759, height: 400)) == false)
    }

    @Test("A wide landscape window takes the wide layout")
    func wideLandscapeWindowIsRegular() {
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 760, height: 500)))
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 1280, height: 860)))
    }

    /// A Mac window can be dragged into any shape, including taller than it is
    /// wide. iOS asks a size class; there is none here, so the proportions are
    /// the whole answer and a tall window must not get the landscape hero.
    @Test("A tall window stays portrait however wide it is")
    func portraitWindowIsNeverRegular() {
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 1000, height: 1400)) == false)
        #expect(AppleMacChromeMetrics.isRegularLayout(viewport: CGSize(width: 900, height: 900)) == false)
    }

    /// 560 pt is a phone column; centred in a 1280 pt Mac window it read as a
    /// narrow strip of rows. Not a magic number in the modifier — the modifier
    /// reads this.
    @Test("The settings column is wider than the phone column it replaced")
    func settingsColumnIsNotAPhoneColumn() {
        #expect(AppleMacChromeMetrics.settingsColumnWidth == 720)
        #expect(AppleMacChromeMetrics.settingsColumnWidth > 560)
    }

    /// The owner's rule is "no scroll indicators", and on macOS `.hidden` does
    /// not deliver it: the platform is free to draw legacy scrollbars anyway,
    /// and did — a light track down the right edge of every settings pane.
    /// Only `.never` holds. The gate runs on macOS, so this test is checking
    /// the macOS value.
    @Test("macOS hides scroll indicators with .never, not .hidden")
    func scrollIndicatorsAreNever() {
        #expect(AppleDesignTokens.scrollIndicatorVisibility == .never)
    }
}

/// The shared app group identifier, which has to differ by platform.
@Suite("Shared app group identifier")
struct AppleAppGroupIdentifierTests {
    /// A sandboxed Mac app's group container is `<TeamID>.group.…`; asking for
    /// the bare iOS form returned a URL that then failed every read and write
    /// with EPERM, which is why the `guard let` at the snapshot call sites
    /// never caught it. The gate runs on macOS, so this is the macOS value.
    @Test("macOS uses the team-id-prefixed form")
    func macOSGroupCarriesTheTeamPrefix() {
        #expect(AppleTopShelfSnapshotWriter.appGroup == "2VQ74PD5YG.group.com.orgista.openstream")
        #expect(AppleTopShelfSnapshotWriter.appGroup.hasSuffix("group.com.orgista.openstream"))
    }

    /// The entitlement that grants the group must use the build setting, not a
    /// literal team id — the id is written out once, in the package constant,
    /// where a mismatch fails to launch rather than failing silently.
    @Test("The macOS entitlements grant the group through $(TeamIdentifierPrefix)")
    func entitlementsUseTheBuildSetting() throws {
        let packageRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlements = try String(
            contentsOf: packageRoot.appending(path: "Apps/Shared/OpenStreamMacOS.entitlements"),
            encoding: .utf8
        )
        #expect(entitlements.contains("com.apple.security.application-groups"))
        #expect(entitlements.contains("$(TeamIdentifierPrefix)group.com.orgista.openstream"))
        #expect(entitlements.contains("<string>2VQ74PD5YG.group") == false)
    }
}

#if os(macOS)
/// The DEBUG-only screen capture hook. macOS screens could not be reviewed
/// from a headless session at all before it, so its argument parsing is worth
/// holding still.
@Suite("Mac window shot arguments")
struct AppleMacWindowShotTests {
    @Test("A WxH size parses")
    func sizeParses() throws {
        let size = try #require(AppleMacWindowShot.parseSize("1280x860"))
        #expect(size == CGSize(width: 1280, height: 860))
        #expect(AppleMacWindowShot.parseSize("900X450") == CGSize(width: 900, height: 450))
    }

    @Test("Nonsense and out-of-range sizes are refused so the default is used")
    func badSizesAreRefused() {
        #expect(AppleMacWindowShot.parseSize("") == nil)
        #expect(AppleMacWindowShot.parseSize("1280") == nil)
        #expect(AppleMacWindowShot.parseSize("wide x tall") == nil)
        #expect(AppleMacWindowShot.parseSize("10x10") == nil)
        #expect(AppleMacWindowShot.parseSize("99999x99999") == nil)
    }

    @Test("No argument means no capture, so an ordinary launch is untouched")
    func captureIsOptIn() {
        #expect(AppleMacWindowShot.request(arguments: ["OpenStream"]) == nil)
    }

    /// A filename, never a path: the app is sandboxed and writes inside its own
    /// container, and a caller-supplied path would be both refused and a way
    /// out of it.
    @Test("A path is refused; a filename is accepted")
    func onlyAFilenameIsAccepted() throws {
        #expect(AppleMacWindowShot.request(
            arguments: ["OpenStream", "-OpenStreamWindowShot", "/etc/shot.png"]) == nil)
        let request = try #require(AppleMacWindowShot.request(
            arguments: ["OpenStream", "-OpenStreamWindowShot", "shot.png",
                        "-OpenStreamWindowShotSize", "900x450",
                        "-OpenStreamWindowShotDelay", "4"]))
        #expect(request.filename == "shot.png")
        #expect(request.size == CGSize(width: 900, height: 450))
        #expect(request.delay == 4)
    }
}
#endif

