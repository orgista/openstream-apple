import Testing
@testable import OpenStreamApple

@MainActor
@Suite struct ApplePlaybackEventStreamTests {
    @Test func cancelledObserversAreRemovedAndDoNotAccumulateOnChannelSwitches() async {
        let events = ApplePlaybackEventStream()
        for _ in 0..<100 {
            let stream = events.stream()
            let observer = Task { for await _ in stream {} }
            observer.cancel()
            await observer.value
        }
        for _ in 0..<100 where events.subscriberCount > 0 { await Task.yield() }
        #expect(events.subscriberCount == 0)
    }

    @Test func slowObserverHasBoundedBufferAndRetainsTheLatestPosition() async {
        let events = ApplePlaybackEventStream()
        let stream = events.stream()
        for index in 0..<1000 { events.emit(.position(Double(index))) }
        var iterator = stream.makeAsyncIterator()
        guard case .position(let first) = await iterator.next() else { Issue.record("Missing position"); return }
        #expect(first == 936)
    }
}
