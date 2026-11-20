import Foundation

/// Where this install came from, read from the receipt Apple leaves in the
/// bundle: App Store installs carry a `receipt`, DEBUG builds usually none, and
/// a `sandboxReceipt` is carried by TestFlight installs **and** by the build
/// App Review runs. No runtime signal tells those two apart, so nothing that
/// must stay out of the reviewer's build may key off this; such behaviour is
/// compiled in DEBUG only.
public enum AppleBuildChannel {
    /// TestFlight or App Review. Used only for the local interaction trace's
    /// default, which writes to the app's own Caches and never leaves the
    /// device unless the user shares it.
    public static var hasSandboxReceipt: Bool {
        isSandboxReceipt(Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }

    public static func isSandboxReceipt(_ lastPathComponent: String?) -> Bool {
        lastPathComponent == "sandboxReceipt"
    }
}
