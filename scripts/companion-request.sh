#!/usr/bin/env bash
#
# Sends a signed request to PlayPrio's iPhone remote API, the way the iPhone page does.
#
#   scripts/companion-request.sh GET /api/state                 # current state at once
#   scripts/companion-request.sh GET '/api/state?since=7'       # waits until it changes (≤ 25 s)
#   scripts/companion-request.sh POST /api/command '{"action":"playPause"}'
#   scripts/companion-request.sh POST /api/command '{"action":"next"}'
#   scripts/companion-request.sh POST /api/command '{"action":"playPause","id":"<row id>"}'
#
# Actions: playPause, play, pause, next, previous (routed like the media keys; with a row's
# "id" from /api/state, sent to that source), seek {"position": seconds}, volume {"value": 0…1},
# repeat, shuffle, playItem {"id": a shelf item's id}, playTrack {"videoId", "playlistId", "params"}.
set -euo pipefail

METHOD="${1:?method}"
TARGET="${2:?path}"
BODY="${3:-}"
KEY="$(defaults read local.PlayPrio companionKey)"
PORT="$(defaults read local.PlayPrio companionPort 2>/dev/null || echo 47269)"
HOST="${PLAYPRIO_HOST:-127.0.0.1}"

TIME="$(date +%s)"
NONCE="$(openssl rand -hex 16)"
SIGNATURE="$(printf '%s\n%s\n%s\n%s\n%s' "$METHOD" "$TARGET" "$TIME" "$NONCE" "$BODY" \
  | openssl dgst -sha256 -hmac "$KEY" -r | cut -d' ' -f1)"

ARGS=(-sS -X "$METHOD" "http://$HOST:$PORT$TARGET"
  -H "X-PlayPrio-Time: $TIME" -H "X-PlayPrio-Nonce: $NONCE" -H "X-PlayPrio-Signature: $SIGNATURE")
if [ -n "$BODY" ]; then ARGS+=(-H "Content-Type: application/json" --data "$BODY"); fi
curl "${ARGS[@]}"
echo
