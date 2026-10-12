import Foundation

enum AppleTrailerSoundBridge {
    static func toggledState(from isMuted: Bool) -> Bool {
        !isMuted
    }

    static func javascriptCommand(isMuted: Bool) -> String {
        "window.setTrailerMuted(\(isMuted ? "true" : "false"));"
    }

    /// Lifts (or reinstates) the muted-only rule on an already-loaded page —
    /// an explicit "Play Trailer" press, after the preview autoplayed muted
    /// (`requiresMutedWebPlayback`, which the document bakes in at load time
    /// unless `allowsSound` was already true). Carries the desired mute state
    /// alongside it so the two never race: `window.setTrailerMuted` alone,
    /// called first or second, could still be clamped mute by the stale flag.
    static func allowsSoundJavascriptCommand(allowsSound: Bool, isMuted: Bool) -> String {
        "window.setTrailerAllowsSound(\(allowsSound ? "true" : "false"), \(isMuted ? "true" : "false"));"
    }

    /// A tap on the trailer's sound control. Turning sound on is an explicit
    /// request, like Play Trailer, so it also lifts the autoplay's muted-only
    /// rule (owner 2026-10-09: autoplay starts muted, but the viewer must be
    /// able to unmute); muting again leaves the rule lifted for this trailer.
    static func tapped(isMuted: Bool, allowsSound: Bool) -> (isMuted: Bool, allowsSound: Bool) {
        isMuted ? (false, true) : (true, allowsSound)
    }

    static func accessibilityLabel(isMuted: Bool) -> String {
        isMuted ? "Turn trailer sound on" : "Mute trailer"
    }

    static func accessibilityValue(isMuted: Bool) -> String {
        isMuted ? "Muted" : "Sound on"
    }
}

enum AppleYouTubePreviewHTML {
    /// `allowsSound` lifts the muted-only rule for a host whose web view does
    /// not take over the device's audio session — the Mac hero, whose mute
    /// button is how a viewer asks to hear it. Every other caller stays muted.
    ///
    /// `layoutScale` lays the player out that many times larger in CSS pixels
    /// and scales it back down from its top-left corner, so it draws in
    /// exactly the same place and size while YouTube, which picks its stream
    /// from the player's own size, picks a sharper one
    /// (`AppleTrailerPreviewPolicy.macLayoutScale`).
    static func document(
        embedURL: URL, startsPlaying: Bool, isLandscape: Bool = false, startsMuted: Bool = true, allowsSound: Bool = false,
        layoutScale: Int = 1, startupChromeCanShow: Bool = AppleTrailerRevealPolicy.startupChromeCanShow
    ) -> String {
        let requiresMutedPlayback = ApplePlaybackSessionPolicy.trailer.requiresMutedWebPlayback && !allowsSound
        let effectiveMuted = requiresMutedPlayback || startsMuted
        var components = URLComponents(url: embedURL, resolvingAgainstBaseURL: false)
        let existingItems = components?.queryItems ?? []
        // Honor only an offset supplied by the source. No guessed title-card
        // duration: sources without chapter/offset information start at zero.
        let suppliedStart = existingItems.first { $0.name == "start" }?.value.flatMap(Double.init) ?? 0
        let start = suppliedStart.isFinite && suppliedStart >= 0 && suppliedStart <= 86_400 ? Int(suppliedStart) : 0
        components?.queryItems = existingItems.filter { !["mute", "autoplay", "playsinline", "start"].contains($0.name) }
            + [URLQueryItem(name: "start", value: String(start)),
               URLQueryItem(name: "mute", value: effectiveMuted ? "1" : "0"),
               URLQueryItem(name: "autoplay", value: startsPlaying ? "1" : "0"),
               URLQueryItem(name: "playsinline", value: "1")]
        let videoKeyJSON = (try? JSONEncoder().encode(embedURL.lastPathComponent))
            .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        let safeSource = htmlEscaped((components?.url ?? embedURL).absoluteString)
        let safeAutoplay = startsPlaying ? 1 : 0
        let safeDesiredPlaying = startsPlaying ? "true" : "false"
        let scale = min(max(layoutScale, 1), 3)
        let scaledLayout = scale == 1 ? "" : """

        iframe{width:\(scale * 100)%;height:\(scale * 100)%;transform:scale(\(1 / Double(scale)));transform-origin:0 0}
        """
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html,body{position:relative;margin:0;width:100%;height:100%;background:transparent;overflow:hidden}
        iframe{position:absolute;inset:0;margin:0;width:100%;height:100%;background:#000;border:0;opacity:1;pointer-events:none}
        body.ready iframe{opacity:1;transition:opacity .12s linear}
        @media(prefers-reduced-motion:reduce){iframe{transition:none}}\(scaledLayout)
        </style>
        </head><body>
        <iframe id="player" src="\(safeSource)" allow="autoplay; encrypted-media" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        <script>
        var player = null;
        // Mutable: an explicit press can lift it after the page has already
        // loaded muted for autoplay (`window.setTrailerAllowsSound`).
        var requiresMutedPlayback = \(requiresMutedPlayback ? "true" : "false");
        var desiredMuted = \(effectiveMuted ? "true" : "false");
        // Debug `-OpenStreamMuteAudio`: silent whatever the page asks for.
        var testMuteAll = \(AppleTestAudioMute.isActive ? "true" : "false");
        var lastPlayerWidth = 0, lastPlayerHeight = 0;
        var layoutScale = \(scale);
        var desiredPlaying = \(safeDesiredPlaying);
        var playerReady = false;
        var actualPlayerState = null;
        var captionSuppressionAttempts = 0;
        var syncAttempts = 0;
        var revealTimer = null;
        var revealWatchdogTimer = null;
        var hasSeenPlaying = false;
        var hasRevealed = false;
        var landscape = \(isLandscape ? "true" : "false");
        var playingSince = null;
        // Media time when PLAYING was seen: the reveal waits for it to advance.
        var playingMediaTime = null;
        // AppleTrailerRevealPolicy: [minimum wait ms, media advance s, cap ms].
        var revealRules = \(AppleTrailerRevealPolicy.javascriptRules(startupChromeCanShow: startupChromeCanShow));
        var playbackGeneration = 0;
        var previewCapTimer = null;
        var previewCapDeadlineTimer = null;
        var previewEnding = false;
        var previewCapSeconds = 60; // owner 2026-09-24: give each hero page about a minute of trailer
        // Ends early enough for the 0.4 s crossfade back to the art to finish
        // over live frames, before YouTube can paint its end screen.
        var previewHideLeadSeconds = 0.8;
        // A duration shorter than this is not the trailer's: the player can
        // report a provisional length (a pre-roll, the first buffered range)
        // as it starts, and capping at it ended the trailer the moment it
        // was revealed. The 60 s cap and YouTube's own ENDED still apply.
        var minimumTrustedDuration = 10;
        var api = document.createElement('script');
        api.src = 'https://www.youtube.com/iframe_api';
        document.head.appendChild(api);

        function notifyNative(state, mutedOverride, errorCode) {
          try {
            var muted = typeof mutedOverride === 'boolean'
              ? mutedOverride
              : (player && typeof player.isMuted === 'function' ? player.isMuted() : desiredMuted);
            var mediaTime = player && typeof player.getCurrentTime === 'function' ? player.getCurrentTime() : 0;
            var quality = player && typeof player.getPlaybackQuality === 'function' ? player.getPlaybackQuality() : '';
            var duration = player && typeof player.getDuration === 'function' ? player.getDuration() : 0;
            var payload = {videoKey: \(videoKeyJSON), state: state, muted: Boolean(muted), mediaTime: mediaTime, quality: quality, duration: duration};
            if (typeof errorCode === 'number') payload.errorCode = errorCode;
            window.webkit.messageHandlers.trailerState.postMessage(payload);
          } catch (_) {}
        }

        function applyAudioPreference() {
          if (!player || typeof player.setVolume !== 'function') return;
          if (desiredMuted || testMuteAll) {
            if (typeof player.mute === 'function') player.mute();
            player.setVolume(0);
          } else {
            if (typeof player.unMute === 'function') player.unMute();
            player.setVolume(100);
          }
        }

        function refreshAudioState() {
          if (!player || !playerReady) return;
          applyAudioPreference();
        }

        function clearRevealTimers() {
          if (revealTimer) {
            clearInterval(revealTimer);
            revealTimer = null;
          }
          if (revealWatchdogTimer) {
            clearTimeout(revealWatchdogTimer);
            revealWatchdogTimer = null;
          }
        }

        function clearPreviewCapTimers() {
          if (previewCapTimer) {
            clearInterval(previewCapTimer);
            previewCapTimer = null;
          }
          if (previewCapDeadlineTimer) {
            clearTimeout(previewCapDeadlineTimer);
            previewCapDeadlineTimer = null;
          }
        }

        function hidePlayer() {
          clearRevealTimers();
          clearPreviewCapTimers();
          hasRevealed = false;
          hasSeenPlaying = false;
          playingSince = null;
          playingMediaTime = null;
          document.body.classList.remove('ready');
        }

        function resizePlayer() {
          if (!player || !playerReady || typeof player.setSize !== 'function') return;
          var width = Math.round(window.innerWidth * layoutScale), height = Math.round(window.innerHeight * layoutScale);
          if (width === lastPlayerWidth && height === lastPlayerHeight) return;
          lastPlayerWidth = width; lastPlayerHeight = height;
          player.setSize(width, height);
        }

        function currentMediaTime() {
          return player && typeof player.getCurrentTime === 'function' ? player.getCurrentTime() : 0;
        }

        // Past the cap, or past the minimum wait with the video really advancing.
        function revealAllowed() {
          var rule = landscape ? revealRules.landscape : revealRules.portrait;
          var waited = Date.now() - playingSince;
          if (waited >= rule[2]) return true;
          if (waited < rule[0] || playingMediaTime === null) return false;
          return currentMediaTime() - playingMediaTime >= rule[1];
        }

        function revealPlayer(reason) {
          if (!desiredPlaying || !playerReady || hasRevealed || !hasSeenPlaying) return;
          if (!revealAllowed()) return;
          if (reason === 'watchdog') console.log('[OpenStream] trailer reveal watchdog: PLAYING was seen without a reveal');
          resizePlayer();
          document.body.classList.add('ready');
          hasRevealed = true;
          clearRevealTimers();
          notifyNative('revealed');
        }

        function revealAfterPlaybackStarts() {
          if (!desiredPlaying || !playerReady || hasRevealed) return;
          if (revealTimer) return;
          if (playingMediaTime === null) playingMediaTime = currentMediaTime();
          // Polled: revealPlayer clears it once the rule allows the reveal.
          revealTimer = setInterval(function() {
            if (hasSeenPlaying) revealPlayer('playing-delay');
          }, 50);
        }

        window.setTrailerLandscape = function(value) {
          if (landscape === Boolean(value)) return;
          landscape = Boolean(value);
          // Keep the same player and playback position when rotating, but
          // conceal it while the new geometry and reveal delay settle.
          clearRevealTimers();
          hasRevealed = false;
          document.body.classList.remove('ready');
          notifyNative('concealed');
          if (hasSeenPlaying && desiredPlaying) {
            playingSince = Date.now();
            playingMediaTime = null;
            revealAfterPlaybackStarts();
          }
        };

        function startPlayback() {
          hidePlayer();
          playbackGeneration += 1;
          previewEnding = false;
          applyAudioPreference();
          player.playVideo();
          // An autoplaying iframe can reach PLAYING before onReady. playVideo
          // then emits no new state transition, so seed the reveal gate here.
          if (typeof player.getPlayerState === 'function' && player.getPlayerState() === YT.PlayerState.PLAYING) {
            hasSeenPlaying = true;
            playingSince = Date.now();
            revealAfterPlaybackStarts();
          }
          previewCapTimer = setInterval(function() {
            if (!desiredPlaying || previewEnding || !player || !playerReady || typeof player.getCurrentTime !== 'function') return;
            var duration = typeof player.getDuration === 'function' ? player.getDuration() : 0;
            var cap = duration >= minimumTrustedDuration ? Math.min(duration, previewCapSeconds) : previewCapSeconds;
            if (player.getCurrentTime() >= cap - previewHideLeadSeconds) finishPreview();
          }, 250);
          // Keep the cap independent of YouTube's current-time reporting. The
          // IFrame API can briefly return a stale value while the player is
          // buffering or resizing, but the preview must still end at 45 s.
          previewCapDeadlineTimer = setTimeout(finishPreview, (previewCapSeconds - previewHideLeadSeconds) * 1000);
          revealWatchdogTimer = setTimeout(function() {
            if (hasSeenPlaying && !hasRevealed) revealPlayer('watchdog');
            revealWatchdogTimer = null;
          }, 6000);
        }

        function finishPreview() {
          if (!desiredPlaying || previewEnding) return;
          previewEnding = true;
          desiredPlaying = false;
          hidePlayer();
          // Hide HTML immediately, then let native acknowledge alpha == 0
          // before issuing pauseVideo (which can display related videos).
          notifyNative('ended');
        }

        window.completeTrailerEnd = function() {
          if (desiredPlaying) return;
          hidePlayer();
          if (player && typeof player.pauseVideo === 'function') player.pauseVideo();
        };

        function scheduleEndCleanup(hidePlayer) {
          setTimeout(hidePlayer, 650);
        }

        window.setTrailerMuted = function(isMuted) {
          desiredMuted = requiresMutedPlayback || Boolean(isMuted);
          applyAudioPreference();
          refreshAudioState();
          // The IFrame API updates its internal mute state asynchronously.
          // Report the requested state here so native UI does not immediately
          // overwrite a user's tap with the previous player state.
          notifyNative(desiredMuted ? 'muted' : 'unmuted', desiredMuted);
          return desiredMuted;
        };

        // An explicit "Play Trailer" press: lifts (or reinstates) the
        // muted-only rule and applies the mute state that goes with it in
        // the same call, so the two flags this depends on can never be seen
        // half-updated regardless of call order.
        window.setTrailerAllowsSound = function(allows, isMuted) {
          requiresMutedPlayback = !Boolean(allows);
          desiredMuted = requiresMutedPlayback || Boolean(isMuted);
          applyAudioPreference();
          refreshAudioState();
          notifyNative(desiredMuted ? 'muted' : 'unmuted', desiredMuted);
          return desiredMuted;
        };

        window.setTrailerPlaying = function(isPlaying) {
          desiredPlaying = Boolean(isPlaying);
          if (!player || !playerReady) return desiredPlaying;
          if (desiredPlaying) {
            startPlayback();
          } else {
            hidePlayer();
            player.pauseVideo();
            notifyNative('paused');
          }
          return desiredPlaying;
        };

        window.restartTrailer = function() {
          desiredPlaying = true;
          if (!player || !playerReady) return true;
          clearPreviewCapTimers();
          previewEnding = false;
          if (typeof player.seekTo === 'function') player.seekTo(\(start), true);
          startPlayback();
          return true;
        };

        function suppressCaptions() {
          if (!player || captionSuppressionAttempts >= 4) return;
          captionSuppressionAttempts += 1;
          try { player.setOption('captions', 'track', {}); } catch (_) {}
          try {
            if (typeof player.unloadModule === 'function') player.unloadModule('captions');
          } catch (_) {}
        }

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            playerVars: {
              start: \(start),
              autoplay: \(safeAutoplay),
              mute: \(effectiveMuted ? 1 : 0),
              playsinline: 1,
              controls: 0,
              disablekb: 1,
              iv_load_policy: 3,
              enablejsapi: 1,
              rel: 0,
              fs: 0,
              origin: 'https://openstream.app'
            },
            events: {
              'onReady': function(event) {
                  suppressCaptions();
                  setTimeout(suppressCaptions, 350);
                  playerReady = true;
                  applyAudioPreference();
                  resizePlayer();
                  hidePlayer();
                  if (desiredPlaying) {
                    startPlayback();
                  }
                  notifyNative('ready');
              },
              'onStateChange': function(event) {
                actualPlayerState = event.data;
                notifyNative('iframe-state-' + event.data);
                if (event.data === YT.PlayerState.PLAYING) {
                  if (!desiredPlaying) { hidePlayer(); return; }
                  if (!hasSeenPlaying) playingSince = Date.now();
                  hasSeenPlaying = true;
                  suppressCaptions();
                  resizePlayer();
                  revealAfterPlaybackStarts();
                  notifyNative('playing');
                } else if (event.data === YT.PlayerState.PAUSED) {
                  hidePlayer();
                  notifyNative('paused');
                } else if (event.data === YT.PlayerState.ENDED) {
                  desiredPlaying = false;
                  hidePlayer();
                  notifyNative('ended');
                  // A second cleanup covers a late iframe end-screen paint;
                  // never let an old callback conceal a newly replayed video.
                  var endedGeneration = playbackGeneration;
                  scheduleEndCleanup(function() {
                    if (playbackGeneration === endedGeneration && !desiredPlaying) {
                      document.body.classList.remove('ready');
                    }
                  });
                }
              },
              'onApiChange': function() {
                suppressCaptions();
                refreshAudioState();
                notifyNative('apiChange');
              },
              'onAutoplayBlocked': function() {
              hidePlayer();
              notifyNative('autoplay-blocked');
              },
              'onError': function(event) {
                desiredPlaying = false;
                hidePlayer();
                notifyNative('error', true, event.data);
              }
            }
          });
        }

        window.addEventListener('resize', resizePlayer);
        window.setInterval(function() {
          if (!playerReady || syncAttempts > 4 || actualPlayerState === null) return;
          syncAttempts += 1;
          refreshAudioState();
          if (actualPlayerState === YT.PlayerState.PLAYING) {
            notifyNative('playing');
          } else if (actualPlayerState === YT.PlayerState.PAUSED) {
            notifyNative('paused');
          } else if (actualPlayerState === YT.PlayerState.ENDED) {
            notifyNative('ended');
          }
        }, 800);
        </script>
        </body></html>
        """
    }

    /// YouTube's own chrome that `controls: 0` still draws: the play/pause
    /// glyph in the middle of the picture and the caption window.
    private static let playerChromeHidingCSS =
        #".ytp-bezel,.ytp-bezel-text-wrapper,.ytp-caption-window-container,.caption-window{display:none!important}"#

    /// Injected into every frame of the title page's web view on iPhone and
    /// iPad, it acts only in YouTube's own player page, which the host page
    /// cannot reach across origins. Without it the mobile player left a large
    /// pause glyph over the playing trailer (N49 #17); the Apple TV app draws
    /// nothing over a playing preview. Pausing stays with the native shield
    /// over the web view, which never passes a touch to YouTube.
    ///
    /// It also reports when YouTube's `<video>` has really drawn frames
    /// (`AppleTrailerFirstFrameGate`): the host keeps the art up until then.
    static let playerChromeScript = """
    (function() {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      var style = document.createElement('style');
      style.textContent = '\(playerChromeHidingCSS)';
      (document.head || document.documentElement).appendChild(style);
    \(AppleTrailerFirstFrameGate.frameScript)
    })();
    """

    /// Injected into every frame of the Mac hero's web view, it acts only in
    /// YouTube's own player page, which the host page cannot reach across
    /// origins (macOS WebKit runs user scripts there):
    /// - the play/pause glyph YouTube flashes in the middle of the picture
    ///   (it showed at the crossfade, N31) and its caption window never draw
    ///   (`playerChromeHidingCSS`);
    /// - it reports the player page's size and where its `<video>` is drawn
    ///   whenever either changes (`geometry`). YouTube re-lays its video out
    ///   a few frames after the page is resized, so the host waits for this
    ///   to settle at the web view's new size before the art fades (N31: the
    ///   picture came in at the art's size, then grew once the cover was going).
    static let macPlayerFrameScript = """
    (function() {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      var style = document.createElement('style');
      style.textContent = '\(playerChromeHidingCSS)';
      (document.head || document.documentElement).appendChild(style);
      var last = '';
      function report() {
        var video = document.querySelector('video');
        var box = video ? video.getBoundingClientRect() : null;
        var geometry = {state: 'geometry', frame: [innerWidth, innerHeight],
          video: box ? [box.left, box.top, box.width, box.height] : null,
          source: video ? [video.videoWidth, video.videoHeight] : null};
        var key = JSON.stringify(geometry);
        if (key === last) return;
        last = key;
        try { window.webkit.messageHandlers.trailerState.postMessage(geometry); } catch (_) {}
      }
      addEventListener('resize', report);
      setInterval(report, 50);
    })();
    """

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// The art stays over a starting trailer until YouTube's `<video>` has
/// presented `minimumFrames` frames with advancing media time, reported by
/// `requestVideoFrameCallback` inside YouTube's own frame (owner item 4,
/// 2026-10-09: the trailer "flashes as it begins"). PLAYING and advancing
/// `currentTime` alone came before the first decoded frame was on screen on
/// a device, where the video is a hardware layer. Each new `playing` event
/// (a resume, a replay) arms it again. `cap` reveals anyway for a WebKit
/// that never calls back.
enum AppleTrailerFirstFrameGate {
    static let framesState = "frames"
    static let minimumFrames = 3
    static let cap: TimeInterval = 2.5

    static var frameScript: String {
        """
          (function() {
            var key = location.pathname.split('/').pop();
            function arm(video) {
              if (!video || typeof video.requestVideoFrameCallback !== 'function') return;
              var seen = 0, last = -1, sent = false;
              function onFrame(now, meta) {
                var time = meta && typeof meta.mediaTime === 'number' ? meta.mediaTime : video.currentTime;
                if (time !== last) { seen += 1; last = time; }
                if (seen >= \(minimumFrames)) {
                  if (!sent) {
                    sent = true;
                    try { window.webkit.messageHandlers.trailerState.postMessage({videoKey: key, state: '\(framesState)'}); } catch (_) {}
                  }
                  return;
                }
                video.requestVideoFrameCallback(onFrame);
              }
              video.addEventListener('playing', function() {
                seen = 0; last = -1; sent = false;
                video.requestVideoFrameCallback(onFrame);
              });
              video.requestVideoFrameCallback(onFrame);
            }
            var hooked = null;
            setInterval(function() {
              var video = document.querySelector('video');
              if (video && video !== hooked) { hooked = video; arm(video); }
            }, 100);
          })();
        """
    }
}
