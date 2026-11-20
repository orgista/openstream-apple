import Foundation
import Testing
@testable import OpenStreamApple

@Suite("Storage location")
struct AppleStorageLocationTests {
    @Test(arguments: AppleStorageLocation.Kind.allCases)
    func appleTVNeverResolvesToApplicationSupportOrDocuments(kind: AppleStorageLocation.Kind) {
        #expect(AppleStorageLocation.searchPath(for: kind, on: .appleTV) == .cachesDirectory)
        let folder = AppleStorageLocation.directory(kind, on: .appleTV)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #expect(caches.map { folder.path.hasPrefix($0.path) } == true)
        #expect(folder.lastPathComponent == AppleStorageLocation.appleTVFolder(for: kind))
    }

    @Test func otherDevicesKeepTheirUsualFolders() {
        #expect(AppleStorageLocation.searchPath(for: .applicationSupport, on: .other) == .applicationSupportDirectory)
        #expect(AppleStorageLocation.searchPath(for: .documents, on: .other) == .documentDirectory)
    }

    @Test func theMediaIndexLivesInTheStorageLocation() {
        #expect(AppleMediaIndexRepository.defaultFileURL.path.hasPrefix(AppleStorageLocation.applicationSupport.path))
    }
}

@Suite("Error labels for the trace")
struct AppleErrorLabelTests {
    private enum Fixture: Error {
        case plain
        case carrying(String)
    }

    @Test func aCaseIsNamedWithoutItsValue() {
        let label = appleErrorLabel(Fixture.carrying("https://fixture.example/secret"))
        #expect(label.contains("Fixture.carrying"))
        #expect(!label.contains("fixture.example"))
        #expect(appleErrorLabel(Fixture.plain).contains("Fixture.plain"))
    }

    @Test func aCocoaErrorShowsItsDomainAndCodeButNotItsPath() {
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/private/fixture/OpenStream"])
        let label = appleErrorLabel(error)
        #expect(label.contains("NSCocoaErrorDomain #513"))
        #expect(!label.contains("fixture"))
    }

    @Test func aKeychainStatusIsNamed() {
        #expect(appleErrorLabel(AppleKeychainStoreError.unexpectedStatus(-25_308)).contains("unexpectedStatus"))
    }
}
