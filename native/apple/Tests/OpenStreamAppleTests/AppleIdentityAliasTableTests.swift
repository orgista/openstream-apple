import Foundation
import Testing
@testable import OpenStreamApple

@Suite struct AppleIdentityAliasTableTests {
    @Test func roundTripIsStableAndSorted() throws {
        var table = AppleIdentityAliasTable()
        let changed = table.record(classID: "c", members: ["z", "a", "z"])
        #expect(changed)
        #expect(table.classes["c"] == ["a", "z"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(table)
        let decoded = try JSONDecoder().decode(AppleIdentityAliasTable.self, from: data)
        #expect(decoded == table)
        #expect(try encoder.encode(decoded) == data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["v"] as? Int == 1)
    }
    @Test func membersOfUnknownKeyIsItself() {
        #expect(AppleIdentityAliasTable().members(of: "unknown") == ["unknown"])
        #expect(AppleIdentityAliasTable().classID(of: "unknown") == nil)
    }
    @Test func membersPutsAskedKeyFirst() {
        var table = AppleIdentityAliasTable()
        table.record(classID: "c", members: ["c", "b", "a"])
        #expect(table.members(of: "b") == ["b", "a", "c"])
        #expect(table.classID(of: "b") == "c")
    }
    @Test func recordIsUnionAndNeverRemoves() {
        var table = AppleIdentityAliasTable()
        let initial = table.record(classID: "c", members: ["a", "b"])
        #expect(initial)
        let before = table
        let subset = table.record(classID: "c", members: ["b"])
        #expect(subset == false)
        #expect(table == before)
        let expanded = table.record(classID: "c", members: ["c"])
        #expect(expanded)
        #expect(table.classes["c"] == ["a", "b", "c"])
    }
    @Test func overlappingClassesResolveTransitivelyWithoutRemovingEvidence() {
        var table = AppleIdentityAliasTable()
        table.record(classID: "local", members: ["old", "new"])
        table.record(classID: "legacy", members: ["new", "positional"])
        table.record(classID: "third", members: ["positional", "last"])
        #expect(table.members(of: "old") == ["old", "last", "new", "positional"])
        #expect(table.members(of: "last") == ["last", "new", "old", "positional"])
        #expect(table.classID(of: "old") == "legacy")
        #expect(table.classes == ["local": ["new", "old"], "legacy": ["new", "positional"], "third": ["last", "positional"]])
    }
    @Test func resolutionProgressIsFreshestOverClass() {
        let old = ApplePlaybackProgress(position: 600, duration: 3600, updatedAt: Date(timeIntervalSince1970: 1))
        let new = ApplePlaybackProgress(position: 900, duration: 3600, updatedAt: Date(timeIntervalSince1970: 2))
        #expect(AppleIdentityAliasResolution.progress(keys: ["new", "old"], in: ["old": old, "new": new]) == new)
        #expect(AppleIdentityAliasResolution.progress(keys: ["missing"], in: ["old": old]) == nil)
        let tied = ApplePlaybackProgress(position: 1000, duration: 3600, updatedAt: new.updatedAt)
        #expect(AppleIdentityAliasResolution.progress(keys: ["new", "old"], in: ["new": new, "old": tied]) == tied)
    }
    @Test(arguments: [false, true]) func resolutionHistoryAppliesMergeRules(watchedIsLater: Bool) {
        let earlier = Date(timeIntervalSince1970: 1)
        let later = Date(timeIntervalSince1970: 2)
        let result = AppleIdentityAliasResolution.history(keys: ["new", "old"], watched: ["old": watchedIsLater ? later : earlier], tombstones: ["new": watchedIsLater ? earlier : later])
        #expect(result.watched == (watchedIsLater ? later : nil))
        #expect(result.tombstone == (watchedIsLater ? nil : later))
        let tied = AppleIdentityAliasResolution.history(keys: ["new", "old"], watched: ["old": later], tombstones: ["new": later])
        #expect(tied.watched == nil)
        #expect(tied.tombstone == later)
    }
    @Test func resolutionTerminalsMerge() {
        let first = Date(timeIntervalSince1970: 1)
        let last = Date(timeIntervalSince1970: 2)
        let result = AppleIdentityAliasResolution.terminals(keys: ["new", "old"], in: ["new": .init(resetAt: last), "old": .init(completedAt: first, removedAt: first, playedAt: first)])
        #expect(result == .init(completedAt: first, resetAt: last, removedAt: first, playedAt: first))
        #expect(AppleIdentityAliasResolution.terminals(keys: [], in: [:]) == nil)
    }
    @Test func resolutionLatestDate() {
        let last = Date(timeIntervalSince1970: 2)
        #expect(AppleIdentityAliasResolution.latestDate(keys: ["new", "old"], in: ["new": last, "old": Date(timeIntervalSince1970: 1)]) == last)
        #expect(AppleIdentityAliasResolution.latestDate(keys: ["missing"], in: [:]) == nil)
    }
}
