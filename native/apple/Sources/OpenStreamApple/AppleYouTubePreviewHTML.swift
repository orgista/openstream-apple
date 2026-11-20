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
        layoutScale: Int = 1, startupChromeCanShow: Bool
    ) -> String {
        let requiresMutedPlayback = ApplePlaybackSessionPolicy.trailer.requiresMutedWebPlayback && !allowsSound
        let effectiveMuted = requiresMutedPlayback || startsMuted
        var components = URLComponents(url: embedURL, resolvingAgainstBaseURL: false)
        let existingItems = components?.queryItems ?? []
        // Honor only an offset supplied by the source. No guessed title-card
        // duration: sources without chapter/offset information start at zero.
        let suppliedStart = existingItems.first { $0.name == "start" }?.value.flatMap(Double.init) ?? 0
        let start = suppliedStart.isFinite && suppliedStart >= 0 && suppliedStart <= 86_400 ? Int(suppliedStart) : 0
        components?.queryItems = existingItems.filter { !["mute", "autoplay", "playsinline", "start", "origin"].contains($0.name) }
            + [URLQueryItem(name: "start", value: String(start)),
               URLQueryItem(name: "mute", value: effectiveMuted ? "1" : "0"),
               URLQueryItem(name: "autoplay", value: startsPlaying ? "1" : "0"),
               URLQueryItem(name: "playsinline", value: "1"),
               URLQueryItem(name: "origin", value: AppleTrailerPreviewPolicy.embedOrigin.absoluteString)]
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
        iframe{position:absolute;inset:0;margin:0;width:100%;height:100%;background:#000;border:0;opacity:1}
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
        var playbackStartTimer = null;
        var hasSeenPlaying = false;
        var hasRevealed = false;
        var landscape = \(isLandscape ? "true" : "false");
        var playingSince = null;
        // Media time when PLAYING was seen: the reveal waits for it to advance.
        var playingMediaTime = null;
        var lastPlayingMediaTime = null;
        var lastPlayingWallTime = null;
        var mediaJumpSlack = \(AppleTrailerRevealPolicy.mediaJumpSlack);
        var startupChromeCanShow = \(startupChromeCanShow ? "true" : "false");
        // AppleTrailerRevealPolicy: [minimum wait ms, media advance s].
        var revealRule = \(AppleTrailerRevealPolicy.javascriptRule(startupChromeCanShow: startupChromeCanShow));
        var playbackGeneration = 0;
        var previewCapTimer = null;
        var previewCapDeadlineTimer = null;
        var previewEnding = false;
        var previewCapSeconds = 60; // owner 2026-09-24: give each hero page about a minute of trailer
        // Ends early enough for the crossfade back to the art (`crossfadeDuration`) to finish
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
          if (playbackStartTimer) {
            clearTimeout(playbackStartTimer);
            playbackStartTimer = null;
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
          lastPlayingMediaTime = null;
          lastPlayingWallTime = null;
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

        function playerIsPlaying() {
          return player && typeof player.getPlayerState === 'function' && player.getPlayerState() === YT.PlayerState.PLAYING;
        }

        function recordPlayingTime() {
          var mediaTime = currentMediaTime();
          var now = Date.now();
          var advance = mediaTime - lastPlayingMediaTime;
          var elapsed = (now - lastPlayingWallTime) / 1000;
          // A seek is not played frames; buffering keeps accumulated advance.
          var sought = lastPlayingMediaTime !== null && (advance < 0 || advance > elapsed + mediaJumpSlack);
          if (playingMediaTime === null || sought) {
            playingSince = now;
            playingMediaTime = mediaTime;
            if (revealWatchdogTimer === null || sought) armRevealWatchdog();
          }
          lastPlayingMediaTime = mediaTime;
          lastPlayingWallTime = now;
        }

        function revealAllowed() {
          return playerIsPlaying() && playingSince !== null && playingMediaTime !== null &&
            Date.now() - playingSince >= revealRule[0] && currentMediaTime() - playingMediaTime >= revealRule[1];
        }

        function revealPlayer() {
          if (!desiredPlaying || !playerReady || hasRevealed || !hasSeenPlaying) return;
          if (playerIsPlaying()) recordPlayingTime();
          if (!revealAllowed()) return;
          resizePlayer();
          document.body.classList.add('ready');
          hasRevealed = true;
          clearRevealTimers();
          notifyNative('revealed');
        }

        function revealAfterPlaybackStarts() {
          if (!desiredPlaying || !playerReady || hasRevealed) return;
          if (playerIsPlaying()) recordPlayingTime();
          if (revealTimer) return;
          revealTimer = setInterval(revealPlayer, 50);
        }

        window.setTrailerLandscape = function(value) {
          if (landscape === Boolean(value)) return;
          landscape = Boolean(value);
          // iPhone's fast gate waits afresh for the rotated geometry to settle.
          if (!startupChromeCanShow) {
            playingSince = null;
            playingMediaTime = null;
          }
          if (revealTimer) {
            clearInterval(revealTimer);
            revealTimer = null;
          }
          hasRevealed = false;
          document.body.classList.remove('ready');
          notifyNative('concealed');
          if (hasSeenPlaying && desiredPlaying) {
            revealAfterPlaybackStarts();
          }
        };

        function armRevealWatchdog() {
          if (playbackStartTimer) {
            clearTimeout(playbackStartTimer);
            playbackStartTimer = null;
          }
          if (revealWatchdogTimer) clearTimeout(revealWatchdogTimer);
          revealWatchdogTimer = setTimeout(function() {
            revealWatchdogTimer = null;
            if (!hasRevealed) finishPreview();
          }, \(Int(AppleTrailerRevealPolicy.revealTimeout * 1000)));
        }

        function startPlayback() {
          hidePlayer();
          playbackGeneration += 1;
          previewEnding = false;
          playbackStartTimer = setTimeout(function() {
            playbackStartTimer = null;
            if (!hasSeenPlaying) finishPreview();
          }, \(Int(AppleTrailerRevealPolicy.playbackStartTimeout * 1000)));
          applyAudioPreference();
          player.playVideo();
          // An autoplaying iframe can reach PLAYING before onReady. playVideo
          // then emits no new state transition, so seed the reveal gate here.
          if (playerIsPlaying()) {
            hasSeenPlaying = true;
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
          // buffering or resizing, but the preview must still end at its cap.
          previewCapDeadlineTimer = setTimeout(finishPreview, (previewCapSeconds - previewHideLeadSeconds) * 1000);
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
              origin: '\(AppleTrailerPreviewPolicy.embedOrigin.absoluteString)'
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

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
