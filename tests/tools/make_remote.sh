#!/bin/bash
# Writes a 45 s "remote side" for the tests with macOS text to speech: one phrase before the pause the
# tests make, one that falls inside the pause (it must never reach the note) and one after it.
# Usage: tests/tools/make_remote.sh <out.wav>
set -euo pipefail
OUT="$1"
TMP=$(mktemp -d)
say -o "$TMP/before.aiff" "The quarterly budget review moves to Thursday afternoon."
say -o "$TMP/paused.aiff" "The secret word is pineapple."
say -o "$TMP/after.aiff" "Please send the signed invoice to the accounting team."
ffmpeg -hide_banner -loglevel error -i "$TMP/before.aiff" -i "$TMP/paused.aiff" -i "$TMP/after.aiff" -filter_complex \
  "[0]adelay=2000:all=1[a];[1]adelay=16500:all=1[b];[2]adelay=36000:all=1[c];[a][b][c]amix=inputs=3:normalize=0,apad=whole_dur=45" \
  -ar 48000 -ac 1 -y "$OUT"
rm -rf "$TMP"
