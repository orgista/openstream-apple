import Testing
@testable import OpenStreamApple

@Suite("Settings form actions on the Mac")
struct AppleFormActionLayoutTests {
    @Test func theMacPutsActionsTrailingUnderTheGroup() {
        #expect(AppleFormActionLayout.layout(for: .macOS) == .trailingFooter)
    }

    @Test(arguments: [AppleUIPlatform.iOS, .tvOS, .visionOS])
    func otherPlatformsKeepTheFormRow(_ platform: AppleUIPlatform) {
        #expect(AppleFormActionLayout.layout(for: platform) == .formRow)
    }

    @Test func currentFollowsTheRunningPlatform() {
        #expect(AppleFormActionLayout.current == AppleFormActionLayout.layout(for: .current))
    }
}

@Suite("Settings root Backup & Sync row")
struct AppleSettingsRootEntryTests {
    @Test func backupIsTitledForBothJobsWithAnIcon() {
        #expect(AppleSettingsRootEntry.backup.title == "Backup & Sync")
        #expect(AppleSettingsRootEntry.backup.systemImage == "icloud.and.arrow.up")
    }

    @Test func backupHasItsOwnSectionRightAfterSources() throws {
        let sections = AppleSettingsRootEntry.leadingSections
        let sourcesSection = try #require(sections.firstIndex { $0.contains(.sources) })
        #expect(sections[sourcesSection + 1] == [.backup])
        #expect(sections.flatMap(\.self).filter { $0 == .backup }.count == 1)
    }

    @Test func everyLeadingRowHasATitleAndGlyph() {
        for entry in AppleSettingsRootEntry.allCases {
            #expect(!entry.title.isEmpty)
            #expect(!entry.systemImage.isEmpty)
        }
        #expect(Set(AppleSettingsRootEntry.leadingSections.flatMap(\.self)) == Set(AppleSettingsRootEntry.allCases))
    }
}

@Suite("iCloud sync switch availability")
struct AppleICloudSyncAvailabilityTests {
    @Test func anEntitledSignedInBuildKeepsTheSwitchLive() {
        let availability = AppleICloudSyncAvailability.resolve(isEntitled: true, hasICloudAccount: true)
        #expect(availability == .available)
        #expect(availability.note == nil)
        #expect(availability.allowsChange(from: false))
        #expect(availability.allowsChange(from: true))
    }

    @Test(arguments: [true, false])
    func anUnentitledBuildDisablesTheSwitch(hasAccount: Bool) {
        let availability = AppleICloudSyncAvailability.resolve(isEntitled: false, hasICloudAccount: hasAccount)
        #expect(availability == .notEntitled)
        #expect(availability.note == "iCloud isn't available in this build")
        #expect(!availability.allowsChange(from: false))
        #expect(!availability.allowsChange(from: true))
    }

    @Test func signedOutOnlyHintsAndNeverLocksTheSwitch() {
        let availability = AppleICloudSyncAvailability.resolve(isEntitled: true, hasICloudAccount: false)
        #expect(availability == .signedOut)
        #expect(availability.note == nil)
        #expect(availability.allowsChange(from: false))
        #expect(availability.allowsChange(from: true))
    }

    /// The package's test runner is not signed with the iCloud entitlement.
    @Test func theUnsignedTestRunnerReadsAsNotEntitled() {
        #expect(AppleICloudSyncProbe.current() == .notEntitled)
    }
}
