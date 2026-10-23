#!/usr/bin/env bash
# Applies this repo's changes to a checkout of VD39/subsonic-player.
# Run from the root of the upstream checkout.
#
# Env:
#   BASE         Pages base path, e.g. "/music" (empty when served from "/")
#   CLIENT_NAME  Name the Subsonic server shows for this client
#
# Every change is checked afterwards, so if upstream code moves the build
# fails instead of silently shipping without the fix.
set -euo pipefail

fail() { echo "::error::$*"; exit 1; }

PWA=config/pwa.config.ts
HEAD_PLUGIN=plugins/head.ts
API_UTILS=composables/useApi/utils.ts
PLAYER=composables/useAudioPlayer/player.ts

# --- 1. Serve from a sub-path --------------------------------------------
# Upstream assumes "/". A project Pages site lives under "/<repo>/".
if [ -n "${BASE:-}" ]; then
  sed -i \
    -e "s#scope: '/'#scope: '$BASE/'#" \
    -e "s#start_url: '/'#start_url: '$BASE/'#" \
    -e "s#navigateFallback: '/'#navigateFallback: '$BASE/'#" \
    -e "s#baseUrl: '/'#baseUrl: '$BASE/'#" \
    -e "s#src: \`/pwa-#src: \`$BASE/pwa-#" \
    -e "s#^    url,\$#    url: '$BASE' + url,#" \
    "$PWA"
  sed -i "s#href: '/favicon.svg'#href: '$BASE/favicon.svg'#" "$HEAD_PLUGIN"

  for pattern in "scope: '$BASE/'" "start_url: '$BASE/'" \
                 "navigateFallback: '$BASE/'" "baseUrl: '$BASE/'" \
                 "$BASE/pwa-" "url: '$BASE' + url"; do
    grep -qF "$pattern" "$PWA" || fail "Base path patch failed: $pattern"
  done
  grep -qF "$BASE/favicon.svg" "$HEAD_PLUGIN" || fail "Favicon patch failed"
fi

# --- 2. Client name ------------------------------------------------------
# Shown in Navidrome's player list instead of "web".
CLIENT_NAME="${CLIENT_NAME:-GithubPlayer}"
sed -i "s#c: 'web',#c: '$CLIENT_NAME',#" "$API_UTILS"
grep -qF "c: '$CLIENT_NAME'," "$API_UTILS" || fail "Client name patch failed"

# --- 3. Audio bypasses the service worker --------------------------------
# Upstream caches streams through the service worker. When the browser stops
# the worker mid-download (Firefox does), the audio is cut short and the
# player treats it as "song ended", skipping to the next track.
sed -i 's#/^https?:\\/\\/\.\*(\\/stream|\\.(mp3|ogg|wav|flac|m4a))(\\?\.\*)?\$/i,#/(?!)/, // audio bypasses the service worker#' "$PWA"
# Keep stream/download out of the generic API cache rule too.
sed -i 's#/^https?:\\/\\/\.\*\\/rest\\/\.\*/i,#/^https?:\\/\\/.*\\/rest\\/(?!stream|download|hls)/i,#' "$PWA"
grep -qF "audio bypasses the service worker" "$PWA" \
  && grep -qF '(?!stream|download|hls)' "$PWA" \
  || fail "Audio caching patch failed"

# --- 4. Click-free track start -------------------------------------------
# Fade each new track in over 30 ms once it starts playing. Without it the
# audio jumps straight to full level, which can click at the start of every
# song. Crossfades already fade, so only the instant swap is changed.
export FADE_IN_METHOD='
  private fadeInOnPlay(track: TrackInstance) {
    const gainNode = track.crossfadeGainNode;
    const context = this.audioContext;

    if (!gainNode || !context) {
      return;
    }

    gainNode.gain.value = 0;
    track.element.addEventListener(
      "playing",
      () => {
        const now = context.currentTime;
        gainNode.gain.cancelScheduledValues(now);
        gainNode.gain.setValueAtTime(0, now);
        gainNode.gain.linearRampToValueAtTime(1, now + 0.03);
      },
      { once: true },
    );
  }
'
perl -0pi -e '
  s{(private instantSwap\(track: TrackInstance\) \{.*?track\.connect\(this\.currentReplayGainValue\);)}{$1\n    this.fadeInOnPlay(track);}s
    or die "instantSwap anchor not found\n";
  s{(\n  private startCrossfade\()}{$ENV{FADE_IN_METHOD}$1}
    or die "startCrossfade anchor not found\n";
' "$PLAYER" || fail "Fade-in patch failed"

echo "Upstream patched."
