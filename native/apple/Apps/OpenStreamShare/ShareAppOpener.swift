import UIKit

/// Best-effort responder-chain handoff requested by the owner. Opening the containing app
/// from a Share extension has no public API and may be refused by iOS. This isolated bridge
/// invokes open(_:options:completionHandler:) without UIApplication.shared; the pending
/// app-group link is always written first and remains the reliable next-foreground fallback.
@MainActor
enum ShareAppOpener {
    static func open(_ url: URL, from responder: UIResponder) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var current: UIResponder? = responder
        while let next = current {
            if next.responds(to: selector), let implementation = next.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let invoke = unsafeBitCast(implementation, to: Open.self)
                invoke(next, selector, url as NSURL, [:] as NSDictionary, nil)
                return
            }
            current = next.next
        }
    }
}
