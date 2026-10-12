import Foundation
import Observation
#if os(iOS)
import UserNotifications
#endif

@MainActor @Observable
public final class AppleProgrammeReminderStore {
    public static let shared = AppleProgrammeReminderStore()
    public private(set) var reminders: [AppleProgrammeReminder]
    public var banner: AppleProgrammeReminder?
    public var requestedChannelID: String?
    public var notificationError: String?
    private let defaults: UserDefaults
    private static let key = "openstream.live.reminders.v1"
    private static let maximumReminders = 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reminders = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([AppleProgrammeReminder].self, from: $0) } ?? []
    }

    @discardableResult public func save(_ reminder: AppleProgrammeReminder, now: Date = .now) -> Bool {
        guard reminder.start > now, reminder.end > reminder.start,
              reminders.count < Self.maximumReminders || reminders.contains(where: { $0.id == reminder.id }) else { return false }
        reminders.removeAll { $0.id == reminder.id }
        reminders.append(reminder)
        reminders.sort { $0.start < $1.start }
        persist()
        return true
    }

    public func toggle(_ reminder: AppleProgrammeReminder) async {
        if reminders.contains(where: { $0.id == reminder.id }) { cancel(reminder.id); return }
        guard save(reminder) else { return }
        #if os(iOS)
        do {
            let center = UNUserNotificationCenter.current()
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                cancel(reminder.id)
                notificationError = "Notifications are off."
                return
            }
            guard reminders.contains(where: { $0.id == reminder.id }) else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.channelName
            content.sound = .default
            content.categoryIdentifier = "live.reminder"
            content.userInfo = ["channelID": reminder.channelID]
            let delay = reminder.start.timeIntervalSinceNow
            guard delay > 0 else { return }
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)))
        } catch {
            cancel(reminder.id)
            notificationError = "Could not set the reminder."
        }
        #endif
    }

    public func cancel(_ id: String) {
        reminders.removeAll { $0.id == id }
        if banner?.id == id { banner = nil }
        persist()
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        #endif
    }

    public func poll(now: Date = .now) {
        if let banner, !banner.isDue(at: now) { self.banner = nil }
        if banner == nil, let due = reminders.first(where: { $0.isDue(at: now) }) {
            banner = due
            reminders.removeAll { $0.id == due.id }
            persist()
        }
        let retained = reminders.filter { $0.end > now && now.timeIntervalSince($0.start) <= 300 }
        if retained != reminders { reminders = retained; persist() }
    }

    public func watch(_ reminder: AppleProgrammeReminder) {
        cancel(reminder.id)
        requestedChannelID = reminder.channelID
    }

    public func activateNotifications() {
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.delegate = AppleProgrammeNotificationDelegate.shared
        center.setNotificationCategories([UNNotificationCategory(identifier: "live.reminder",
            actions: [UNNotificationAction(identifier: "live.reminder.watch", title: "Watch Now", options: [.foreground])],
            intentIdentifiers: [])])
        #endif
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reminders) { defaults.set(data, forKey: Self.key) }
    }
}

#if os(iOS)
@MainActor private final class AppleProgrammeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppleProgrammeNotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "live.reminder.watch" || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["channelID"] as? String else { return }
        let reminderID = response.notification.request.identifier
        await MainActor.run {
            AppleProgrammeReminderStore.shared.cancel(reminderID)
            AppleProgrammeReminderStore.shared.requestedChannelID = id
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif
