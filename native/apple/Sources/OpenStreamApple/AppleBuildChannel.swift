import Foundation

/// Where this install came from, read from the receipt Apple leaves in the
/// bundle. TestFlight installs carry a `sandboxReceipt`; App Store installs a
/// `receipt`; DEBUG builds usually none.
public enum AppleBuildChannel {
    public static var isTestFlight: Bool {
        isTestFlightReceipt(Bundle.main.appStoreReceiptURL?.lastPathComponent)
    }

    public static func isTestFlightReceipt(_ lastPathComponent: String?) -> Bool {
        lastPathComponent == "sandboxReceipt"
    }
}
