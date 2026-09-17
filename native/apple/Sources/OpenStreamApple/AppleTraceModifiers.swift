import SwiftUI

/// App-wide trace hooks, so navigating the app writes its own timeline.
///
/// The one-off `AppleInteractionTrace.record` calls only covered the live
/// guide, which meant a walk through Discover, Library, Search or Settings
/// left no record at all — the owner asked to "turn on traces for every
/// function … so I can nav through and note any issues". These modifiers make
/// that cheap: a screen declares its name once and every appearance,
/// disappearance and selection lands in the log with a timestamp.
///
/// These ship in release builds too, so a TestFlight build records the same
/// timeline a local one does.
public extension View {
    /// Records when this screen appears and goes away.
    ///
    /// Put it on the top level of anything the viewer can navigate to. The
    /// `detail` closure runs only while tracing is on, so counting rows or
    /// formatting state costs nothing in a normal build.
    func appleTraceScreen(
        _ name: String,
        detail: @escaping @autoclosure () -> String = ""
    ) -> some View {
        return onAppear {
            let extra = AppleInteractionTrace.isEnabled ? detail() : ""
            AppleInteractionTrace.record(.screen, extra.isEmpty ? "\(name) appeared" : "\(name) appeared — \(extra)")
        }
        .onDisappear {
            AppleInteractionTrace.record(.screen, "\(name) gone")
        }
    }

    /// Records a value the viewer changed — a tab, a picker, a toggle.
    func appleTraceSelection<Value: Equatable>(
        _ name: String,
        value: Value
    ) -> some View {
        return onChange(of: value) { _, updated in
            AppleInteractionTrace.record(.press, "\(name) → \(updated)")
        }
    }
}

/// Records something the viewer did that has no view to hang off — a button
/// action, a store mutation, a request that failed. One boolean check when
/// tracing is off.
@inlinable
public func appleTrace(_ detail: @autoclosure () -> String) {
    AppleInteractionTrace.record(.press, detail())
}

/// Records a failure the viewer can see.
@inlinable
public func appleTraceFailure(_ detail: @autoclosure () -> String) {
    AppleInteractionTrace.record(.failure, detail())
}
