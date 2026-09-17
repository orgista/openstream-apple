import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Drives the download Live Activity from the coordinator's state changes.
///
/// Attached through `AppleOfflineDownloadCoordinator.stateDidChange`, so the
/// coordinator knows nothing about ActivityKit and the download logic stays
/// testable on every platform.
@MainActor
public final class AppleDownloadLiveActivityController {
    public static let shared = AppleDownloadLiveActivityController()

    #if canImport(ActivityKit) && os(iOS)
    // ActivityKit's Activity is not Sendable. Keep only its identifier on the
    // main actor; resolve the framework object where its async API is called.
    private var activityID: String?
    #endif

    public init() {}

    /// True when the system will actually show one: the capability exists and
    /// the viewer has not turned Live Activities off for the app.
    /// Logged once per process: `apply` runs on every progress tick, and the
    /// trace is for diagnosis, not for filling the timeline.
    private var loggedUnavailable = false

    public var isAvailable: Bool {
        #if canImport(ActivityKit) && os(iOS)
        ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        false
        #endif
    }

    /// Starts or updates the activity, and ends it on a terminal state.
    ///
    /// Safe to call on every progress tick — the coordinator emits several a
    /// second and this only ever holds one activity.
    public func apply(
        title: String,
        subtitle: String?,
        destination: String,
        state: AppleDownloadActivityState
    ) {
        #if canImport(ActivityKit) && os(iOS)
        // Both failure paths below used to be silent, so a Live Activity that
        // never appeared left nothing to look at — the single hardest kind of
        // bug to answer when the owner says "it doesn't work".
        guard isAvailable else {
            if !loggedUnavailable {
                loggedUnavailable = true
                appleTrace("live activity: unavailable — Live Activities are off for this app")
            }
            return
        }
        if state.isFinal {
            end(with: state)
            return
        }
        if let activityID {
            Task { await Self.updateActivity(id: activityID, state: state) }
            return
        }
        let attributes = AppleDownloadActivityAttributes(
            title: title, subtitle: subtitle, destination: destination
        )
        do {
            activityID = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            ).id
            appleTrace("live activity: started for \(title)")
        } catch {
            appleTraceFailure("live activity: request failed — \(error.localizedDescription)")
        }
        #endif
    }

    /// Ends the activity, leaving the final state on screen briefly so a
    /// completed download is seen rather than vanishing mid-glance.
    public func end(with state: AppleDownloadActivityState? = nil) {
        #if canImport(ActivityKit) && os(iOS)
        guard let activityID else { return }
        self.activityID = nil
        Task { await Self.endActivity(id: activityID, state: state) }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    private nonisolated static func updateActivity(id: String, state: AppleDownloadActivityState) async {
        guard let activity = Activity<AppleDownloadActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func endActivity(id: String, state: AppleDownloadActivityState?) async {
        guard let activity = Activity<AppleDownloadActivityAttributes>.activities.first(where: { $0.id == id }) else {
            return
        }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: .after(.now.addingTimeInterval(4)))
    }
    #endif
}
