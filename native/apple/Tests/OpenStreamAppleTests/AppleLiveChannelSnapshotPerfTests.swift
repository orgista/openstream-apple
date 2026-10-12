import Foundation
import Testing
@testable import OpenStreamApple

@Suite(.serialized) struct AppleLiveChannelSnapshotPerfTests {
    @Test func buildPerformanceAndStability() async throws {
        let counter = AppleLiveChannelSnapshot.DebugCounter()
        // A private cache, not a process-wide "never clear" switch: that switch
        // also stopped every other suite's lineup change from clearing the
        // shared cache, so they read matches made against an older lineup.
        AppleLiveChannelSnapshot.$debugMatchCache.withValue(AppleLiveChannelMatchCache()) {
            AppleLiveChannelSnapshot.$debugMatchCallsCounter.withValue(counter) {
                
                // Create 10 synthetic channels
                let channels = (0..<10).map { i in
                    AppleIPTVChannel(
                        id: "channel-\(i)",
                        sourceID: UUID(),
                        name: "Channel \(i)",
                        group: "All",
                        logoURL: nil,
                        streamURL: URL(string: "http://example.com/\(i).m3u8")!
                    )
                }
                let groups = [AppleIPTVChannelGroup(name: "All", channels: channels)]
                
                let custom = AppleCustomChannelPackage()
                let entries = (0..<10).map { i in
                    AppleChannelLineupEntry(
                        number: i,
                        name: "Channel \(i)",
                        aliases: [],
                        category: "Entertainment"
                    )
                }
                
                // First build
                counter.calls.withLock { $0 = 0 }
                let firstSnapshot = AppleLiveChannelSnapshot.build(
                    groups: groups,
                    package: .everything,
                    custom: custom,
                    entries: entries,
                    favoriteIDs: [],
                    category: "All"
                )
                let firstCalls = counter.calls.withLock { $0 }
                
                // Second build (same input)
                counter.calls.withLock { $0 = 0 }
                let secondSnapshot = AppleLiveChannelSnapshot.build(
                    groups: groups,
                    package: .everything,
                    custom: custom,
                    entries: entries,
                    favoriteIDs: [],
                    category: "All"
                )
                let secondCalls = counter.calls.withLock { $0 }
                
                // Verify output is identical
                #expect(firstSnapshot.channelIDs == secondSnapshot.channelIDs)
                
                // Structural memoisation assertion
                #expect(firstCalls == 10)
                #expect(secondCalls == 0)
                
                // A changed channel name should trigger exactly one match
                let modifiedChannels = channels.map {
                    if $0.id == "channel-0" {
                        return AppleIPTVChannel(
                            id: $0.id,
                            sourceID: $0.sourceID,
                            name: "Channel 0 Modified",
                            group: $0.group,
                            logoURL: $0.logoURL,
                            streamURL: $0.streamURL
                        )
                    }
                    return $0
                }
                
                counter.calls.withLock { $0 = 0 }
                _ = AppleLiveChannelSnapshot.build(
                    groups: [AppleIPTVChannelGroup(name: "All", channels: modifiedChannels)],
                    package: .everything,
                    custom: custom,
                    entries: entries,
                    favoriteIDs: [],
                    category: "All"
                )
                
                let thirdCalls = counter.calls.withLock { $0 }
                #expect(thirdCalls == 1)
            }
        }
    }
}
