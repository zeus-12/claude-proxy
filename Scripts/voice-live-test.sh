#!/usr/bin/env bash
#
# Live end-to-end check of the voice endpoint against the REAL Claude backend.
#
#   ./Scripts/voice-live-test.sh                 # default phrase on :8765
#   ./Scripts/voice-live-test.sh 8790 "hello world"
#
# It synthesises speech, streams it through a local --voice-server at real time
# (the upstream drops audio pushed faster than real time), and prints the
# transcript that comes back. This makes a real API call, so it needs:
#   * Keychain access to the Claude Code OAuth token — approve the macOS prompt
#     once, the same one dictation triggers.
#   * a network connection.
#
# Exits non-zero if no transcript comes back.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-8765}"
PHRASE="${2:-the quick brown fox jumps over the lazy dog}"
BIN=".build/debug/LLMProxy"
WORK="$(mktemp -d)"
SERVER_PID=""
ACCESS_KEY="llmp-voice-isolation"
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "==> Building"
swift build >/dev/null

echo "==> Synthesising speech: \"$PHRASE\""
say -o "$WORK/speech.aiff" "$PHRASE"
# Headerless signed 16-bit little-endian, 16 kHz mono — the format the client
# declares to the server in the query string below.
ffmpeg -y -loglevel error -i "$WORK/speech.aiff" -f s16le -ar 16000 -ac 1 "$WORK/speech.pcm"

echo "==> Starting voice server on :$PORT"
LLM_PROXY_ACCESS_KEY_VOICE="$ACCESS_KEY" "$BIN" --voice-server "$PORT" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "server exited before it was ready"; exit 1; }
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
    sleep 0.1
done

echo "==> Streaming and transcribing"
URL="ws://127.0.0.1:$PORT/v1/listen?encoding=linear16&sample_rate=16000&channels=1&token=$ACCESS_KEY"
"$BIN" --voice-client "$URL" "$WORK/speech.pcm"
