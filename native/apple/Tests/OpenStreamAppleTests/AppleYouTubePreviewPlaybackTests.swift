import Foundation
import JavaScriptCore
import Testing
@testable import OpenStreamApple

@MainActor
@Suite("YouTube preview stays under the art until playback advances")
struct AppleYouTubePreviewPlaybackTests {
    @Test(arguments: [true, false])
    func aPlayingEventWithoutFramesNeverReveals(startupChromeCanShow: Bool) throws {
        let page = try Page(startupChromeCanShow: startupChromeCanShow)
        try page.evaluate("changeState(1, 0); tick(20000, 0);")
        #expect(page.revealed == false)
        #expect(page.revealMessages == 0)
    }

    @Test(arguments: [2, 3, -1])
    func aPreviousPlayingEventCannotRevealWhileThePlayerIsStopped(state: Int) throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 0); changeState(\(state), 5); tick(20000, 5);")
        #expect(page.revealed == false)
        #expect(page.revealMessages == 0)
    }

    @Test(arguments: [true, false])
    func iPhoneStillRevealsAfterHalfASecondOfAdvancingVideo(isLandscape: Bool) throws {
        let page = try Page(startupChromeCanShow: false, isLandscape: isLandscape)
        try page.evaluate("changeState(1, 0); tick(490, 0.3);")
        #expect(page.revealed == false)
        try page.evaluate("tick(10, 0.4);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func theUncroppedPlayerWaitsForStartupChromeToSettle() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 0); tick(4300, 4.2);")
        #expect(page.revealed == false)
        try page.evaluate("tick(300, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func aStalledFirstBufferCannotUseTheWatchdogToReveal() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 0); tick(20000, 1);")
        #expect(page.revealed == false)
        #expect(page.revealMessages == 0)
    }

    @Test func autoplayAlreadyPlayingBeforeReadyCanStillReveal() throws {
        let page = try Page(startupChromeCanShow: false, initialState: 1, initialTime: 3)
        try page.evaluate("tick(500, 3.4);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func replayKeepsTheArtUntilNewFramesArrive() throws {
        let page = try Page(startupChromeCanShow: false)
        try page.evaluate("changeState(1, 0); tick(500, 0.4); window.setTrailerPlaying(false);")
        #expect(page.revealed == false)
        try page.evaluate("window.restartTrailer(); changeState(1, 0); tick(500, 0);")
        #expect(page.revealed == false)
        try page.evaluate("tick(50, 0.4);")
        #expect(page.revealed)
        #expect(page.revealMessages == 2)
    }

    @Test(arguments: [true, false])
    func stalledPlaybackStopsWaitingUnderTheArt(startupChromeCanShow: Bool) throws {
        let page = try Page(startupChromeCanShow: startupChromeCanShow)
        try page.evaluate("changeState(1, 0); tick(12000, 0);")
        #expect(page.revealed == false)
        #expect(page.revealMessages == 0)
        #expect(try page.evaluate("revealTimer === null && revealWatchdogTimer === null && !desiredPlaying").toBool())
        try page.evaluate("changeState(1, 10); tick(500, 11);")
        #expect(page.revealed == false)
    }

    @Test(arguments: [true, false])
    func rotationDoesNotCancelTheStartupDeadline(startupChromeCanShow: Bool) throws {
        let page = try Page(startupChromeCanShow: startupChromeCanShow)
        try page.evaluate("changeState(1, 0); tick(400, 0); window.setTrailerLandscape(true); tick(11600, 0);")
        #expect(page.revealed == false)
        #expect(try page.evaluate("revealTimer === null && !desiredPlaying").toBool())
    }

    @Test func aPlayerThatNeverReportsPlayingAlsoStopsWaiting() throws {
        let page = try Page(startupChromeCanShow: false)
        try page.evaluate("tick(29999, 0);")
        #expect(try page.evaluate("desiredPlaying").toBool())
        try page.evaluate("tick(1, 0);")
        #expect(page.revealed == false)
        #expect(try page.evaluate("!desiredPlaying && playbackStartTimer === null && revealWatchdogTimer === null").toBool())
    }

    @Test func aSlowFirstBufferStillGetsTheFullRevealWindow() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("tick(20000, 0); changeState(1, 0); tick(4500, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
        #expect(try page.evaluate("messages.filter(x => x.state === 'ended').length").toInt32() == 0)
    }

    @Test func theStalledRevealDeadlineStartsAtFirstPlaying() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("tick(20000, 0); changeState(1, 0); tick(11999, 0);")
        #expect(try page.evaluate("desiredPlaying").toBool())
        try page.evaluate("tick(1, 0);")
        #expect(page.revealed == false)
        #expect(try page.evaluate("!desiredPlaying && revealWatchdogTimer === null").toBool())
    }

    @Test func bufferingKeepsTheFirstPlayingBaseline() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 0); tick(3000, 3); changeState(3, 3); tick(1000, 3); changeState(1, 3);")
        #expect(page.revealed == false)
        try page.evaluate("tick(1500, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test(arguments: [true, false])
    func aBackwardSeekRearmsTheAdvanceBaseline(startupChromeCanShow: Bool) throws {
        let page = try Page(startupChromeCanShow: startupChromeCanShow)
        try page.evaluate("changeState(1, 20); tick(200, 20.1); changeState(3, 0); changeState(1, 0); tick(500, 0);")
        #expect(page.revealed == false)
        try page.evaluate("tick(4500, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func aSeekWhileBufferingWaitsForPlayingToRearmTheBaseline() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 20); tick(500, 20); changeState(3, 0); window.setTrailerLandscape(true); tick(1000, 0);")
        #expect(try page.evaluate("playingMediaTime === 20").toBool())
        try page.evaluate("changeState(1, 0); tick(4500, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func aLateBackwardSeekGetsItsOwnBoundedRevealWait() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 20); tick(11000, 20); changeState(3, 0); changeState(1, 0); tick(1500, 1.5);")
        #expect(page.revealed == false)
        try page.evaluate("tick(3000, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func aBackwardSeekWithoutAStateChangeRearmsTheBaseline() throws {
        let page = try Page(startupChromeCanShow: false)
        try page.evaluate("changeState(1, 20); tick(200, 20.1); tick(50, 0); tick(500, 0.4);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func rotationKeepsAccumulatedMediaAdvance() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 0); tick(3000, 3); window.setTrailerLandscape(true); tick(1500, 4.5);")
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func iPhoneRotationWaitsAnotherHalfSecond() throws {
        let page = try Page(startupChromeCanShow: false)
        try page.evaluate("changeState(1, 0); tick(500, 0.4); window.setTrailerLandscape(true); tick(490, 0.8);")
        #expect(page.revealed == false)
        try page.evaluate("tick(10, 0.9);")
        #expect(page.revealed)
        #expect(page.revealMessages == 2)
    }

    @Test(arguments: [true, false])
    func aForwardSeekDoesNotCountAsPlayedFrames(startupChromeCanShow: Bool) throws {
        let page = try Page(startupChromeCanShow: startupChromeCanShow)
        try page.evaluate("changeState(1, 0); tick(500, 12);")
        #expect(page.revealed == false)
        try page.evaluate("tick(490, 12.4);")
        #expect(page.revealed == false)
        if startupChromeCanShow {
            try page.evaluate("tick(4010, 16.5);")
        } else {
            try page.evaluate("tick(10, 12.5);")
        }
        #expect(page.revealed)
        #expect(page.revealMessages == 1)
    }

    @Test func checkingRevealEligibilityDoesNotRearmPlayback() throws {
        let page = try Page(startupChromeCanShow: true)
        try page.evaluate("changeState(1, 20); tick(400, 20); position = 0;")
        #expect(try page.evaluate("revealAllowed()").toBool() == false)
        #expect(try page.evaluate("playingSince === 0 && playingMediaTime === 20 && lastPlayingMediaTime === 20").toBool())
    }

    private struct Page {
        let context: JSContext

        var revealed: Bool { context.objectForKeyedSubscript("hasRevealed").toBool() }
        var revealMessages: Int32 { context.evaluateScript("messages.filter(x => x.state === 'revealed').length").toInt32() }

        init(startupChromeCanShow: Bool, isLandscape: Bool = false, initialState: Int = -1, initialTime: Double = 0) throws {
            context = try #require(JSContext())
            try evaluate("""
            var clock = 0, position = \(initialTime), playbackState = \(initialState);
            var messages = [], intervals = [], timeouts = [], callbacks;
            var window = this;
            var document = {
              createElement: function() { return {}; },
              head: {appendChild: function() {}},
              body: {classList: {add: function() {}, remove: function() {}}}
            };
            window.webkit = {messageHandlers: {trailerState: {postMessage: function(value) { messages.push(value); }}}};
            window.addEventListener = function() {};
            window.innerWidth = 1024; window.innerHeight = 576;
            Date.now = function() { return clock; };
            function setInterval(callback) { intervals.push(callback); return intervals.length; }
            function clearInterval(id) { intervals[id - 1] = null; }
            function setTimeout(callback, delay) { timeouts.push({callback: callback, due: clock + delay}); return timeouts.length; }
            function clearTimeout(id) { timeouts[id - 1] = null; }
            var mockPlayer = {
              getCurrentTime: function() { return position; }, getPlayerState: function() { return playbackState; },
              getDuration: function() { return 120; }, getPlaybackQuality: function() { return 'hd1080'; },
              isMuted: function() { return true; }, mute: function() {}, unMute: function() {},
              setVolume: function() {}, setSize: function() {}, setOption: function() {}, unloadModule: function() {},
              playVideo: function() {}, pauseVideo: function() { playbackState = 2; },
              seekTo: function(time) { position = time; }
            };
            var YT = {PlayerState: {PLAYING: 1, PAUSED: 2, ENDED: 0}, Player: function(id, options) {
              callbacks = options.events; return mockPlayer;
            }};
            function changeState(state, time) { playbackState = state; position = time; callbacks.onStateChange({data: state}); }
            function tick(milliseconds, time) {
              clock += milliseconds; position = time;
              intervals.slice().forEach(function(callback) { if (callback) callback(); });
              timeouts.slice().forEach(function(timer, index) {
                if (timer && timer.due <= clock) { timeouts[index] = null; timer.callback(); }
              });
            }
            """)
            let embed = try #require(AppleTrailerPreviewPolicy.embedURL(for: "trailer_456"))
            let html = AppleYouTubePreviewHTML.document(embedURL: embed, startsPlaying: true, isLandscape: isLandscape,
                                                       startupChromeCanShow: startupChromeCanShow)
            let start = try #require(html.range(of: "<script>"))
            let end = try #require(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
            try evaluate(String(html[start.upperBound..<end.lowerBound]))
            try evaluate("onYouTubeIframeAPIReady(); callbacks.onReady({});")
        }

        @discardableResult
        func evaluate(_ script: String) throws -> JSValue {
            let result = context.evaluateScript(script)
            try #require(context.exception == nil, Comment(rawValue: context.exception?.toString() ?? ""))
            return try #require(result)
        }
    }
}
