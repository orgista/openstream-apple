import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Programme reminders")
struct AppleProgrammeReminderTests {
    @Test func identitySurvivesGuideRefreshAndDueWindowRejectsOldProgrammes() {
        let start = Date(timeIntervalSince1970: 1000)
        let reminder = AppleProgrammeReminder(channelID: "a", channelName: "News", title: "Morning", start: start, end: start.addingTimeInterval(3600))
        let refreshed = AppleProgrammeReminder(channelID: "a", channelName: "Renamed", title: "Updated", start: start, end: start.addingTimeInterval(3600))
        #expect(reminder.id == refreshed.id)
        #expect(!reminder.isDue(at: start.addingTimeInterval(-1)))
        #expect(reminder.isDue(at: start))
        #expect(!reminder.isDue(at: start.addingTimeInterval(301)))
    }

    @MainActor @Test func reminderPersistsCancelsAndFiresOnce() throws {
        let key = "reminder-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let now = Date(timeIntervalSince1970: 1000)
        let reminder = AppleProgrammeReminder(channelID: "a", channelName: "News", title: "Morning", start: now.addingTimeInterval(60), end: now.addingTimeInterval(3600))
        let store = AppleProgrammeReminderStore(defaults: defaults)
        #expect(store.save(reminder, now: now))
        let restored = AppleProgrammeReminderStore(defaults: defaults)
        #expect(restored.reminders == [reminder])
        restored.poll(now: reminder.start)
        #expect(restored.banner == reminder)
        #expect(restored.reminders.isEmpty)
        restored.watch(reminder)
        #expect(restored.requestedChannelID == "a")
        #expect(restored.banner == nil)
        let cancelled = AppleProgrammeReminderStore(defaults: defaults)
        #expect(cancelled.reminders.isEmpty)
        #expect(cancelled.save(reminder, now: now))
        cancelled.cancel(reminder.id)
        #expect(AppleProgrammeReminderStore(defaults: defaults).reminders.isEmpty)
    }
}
