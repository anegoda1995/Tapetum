#!/bin/bash
# End-to-end test: a fake call (ffmpeg holds the microphone), a known "remote side" fed in as system audio,
# pause + voice mode toggles, automatic stop, transcription, note checks.
# Usage: tests/e2e.sh [remote-audio-file] [work dir]
#   TEST_CONFIG=<config.json> is copied into the test home: a transcription server (without one the recording
#   must wait for a server and the transcript checks are skipped), or ignore lists for apps on this Mac that
#   would keep the fake call going.
# Needs ffmpeg, and the terminal needs the microphone permission. An installed Tapetum keeps running; its
# automatic recording is paused for the run (tests/tools/installed.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPBIN="$ROOT/build/Tapetum.app/Contents/MacOS/Tapetum"
WORK="${2:-$(mktemp -d)}"
REMOTE="${1:-$WORK/remote.wav}"
rm -rf "${WORK:?}/home" "${WORK:?}/notes" "${WORK:?}/shots"; mkdir -p "$WORK/home" "$WORK/notes" "$WORK/shots"
[ -f "$REMOTE" ] || "$ROOT/tests/tools/make_remote.sh" "$REMOTE"
[ -n "${TEST_CONFIG:-}" ] && cp "$TEST_CONFIG" "$WORK/home/config.json"
. "$ROOT/tests/tools/installed.sh"
pause_installed_tapetum
export TAPETUM_HOME="$WORK/home" TAPETUM_NOTES_DIR="$WORK/notes" TAPETUM_TEST_SYSTEM_FILE="$REMOTE"
export TAPETUM_STOP_GRACE=6 TAPETUM_MIN_SEC=5 TAPETUM_START_DELAY=0
SCREEN_W=$(osascript -e 'tell application "Finder" to get item 3 of (get bounds of window of desktop)' 2>/dev/null || echo 1440)
FAIL=0
ok()   { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; FAIL=$((FAIL+1)); }
st()   { python3 -c "import json,sys;print(json.load(open('$WORK/home/status.json')).get('$1',''))" 2>/dev/null; }
shot() { screencapture -x -R "0,0,$SCREEN_W,24" "$WORK/shots/$1.png"; }
waitfor() { # key value timeout
  for _ in $(seq 1 $(( $3 * 2 ))); do [ "$(st "$1")" = "$2" ] && return 0; sleep 0.5; done; return 1; }

"$APPBIN" -AppleLanguages "(en)" > "$WORK/app.log" 2>&1 &
APP=$!
sleep 3
[ "$(st state)" = "idle" ] && [ "$(st icon)" = "closed" ] && ok "starts idle with a closed eye" || bad "not idle at start: $(st state)/$(st icon)"
shot 1-idle

ffmpeg -hide_banner -loglevel error -f avfoundation -i ":0" -t 45 -y "$WORK/fakecall.wav" </dev/null &
CALL=$!
T0=$(date +%s)
waitfor state recording 10 && ok "call detected, recording in $(( $(date +%s) - T0 )) s" || bad "call not detected"
[ "$(st icon)" = "open" ] && ok "eye is open while recording" || bad "icon $(st icon)"
[ "$(st voiceMode)" = "False" ] && [ "$(st voiceActual)" = "False" ] && ok "voice mode is off by default" || bad "voice mode $(st voiceMode)/$(st voiceActual): $(st micProblem)"
REC0=$(date +%s)
shot 2-recording

sleep $(( 12 - ($(date +%s) - REC0) ))
"$APPBIN" --send pause
waitfor state paused 5 && ok "paused" || bad "pause failed"
[ "$(st icon)" = "half" ] && ok "eye is half closed while paused" || bad "icon $(st icon)"
shot 3-paused
sleep $(( 20 - ($(date +%s) - REC0) ))
"$APPBIN" --send resume
waitfor state recording 5 && ok "resumed" || bad "resume failed"

sleep $(( 25 - ($(date +%s) - REC0) ))
"$APPBIN" --send voice-on
waitfor voiceActual True 6 && ok "voice mode switched on for this call" || bad "voice-on: $(st voiceMode)/$(st voiceActual): $(st micProblem)"
sleep 4
"$APPBIN" --send voice-off
waitfor voiceActual False 6 && [ "$(st voiceMode)" = "False" ] && ok "voice mode off again" || bad "voice-off: $(st voiceMode)/$(st voiceActual)"

wait $CALL
CALL_END=$(date +%s)
echo "      fake call ended at +$(( CALL_END - REC0 )) s"
waitfor state idle 20 && ok "call end detected after the grace period ($(( $(date +%s) - CALL_END )) s)" || bad "did not stop"
shot 4-after-call
for _ in $(seq 1 240); do
  M=$(ls "$WORK/home/recordings"/*/manifest.json 2>/dev/null | head -1)
  S=$(python3 -c "import json;print(json.load(open('$M'))['status'])" 2>/dev/null)
  [ "$S" = "busy" ] || true
  [ "$(st busy)" = "True" ] && [ ! -f "$WORK/shots/5-busy.png" ] && shot 5-busy
  [ "$S" = "done" ] || [ "$S" = "failed" ] && break
  A=$(python3 -c "import json;print(json.load(open('$M')).get('attempts',0))" 2>/dev/null)
  [ "$S" = "pending" ] && [ "${A:-0}" -ge 1 ] && break
  sleep 0.5
done
OFFLINE=0
if [ "$S" = "pending" ]; then
  OFFLINE=1
  ERR=$(python3 -c "import json;print(json.load(open('$M')).get('lastError'))" 2>/dev/null)
  echo "$ERR" | grep -qE "unavailable|No Whisper server set" && ok "no Whisper server: recording kept as pending for retry ($ERR)" || bad "pending for another reason: $ERR"
else
  [ "$S" = "done" ] && ok "transcription done" || bad "job status: $S ($(python3 -c "import json;print(json.load(open('$M')).get('lastError'))" 2>/dev/null))"
fi
shot 6-done

NOTE=$(ls "$WORK/notes"/*.md 2>/dev/null | head -1)
AUDIO=$(ls "$WORK/notes/audio"/*.m4a 2>/dev/null | head -1)
[ -n "$NOTE" ] && ok "note created: $(basename "$NOTE")" || bad "no note"
[ -n "$AUDIO" ] && ok "audio next to the notes: $(basename "$AUDIO") ($(du -h "$AUDIO" | cut -f1))" || bad "no audio"
if [ -n "$NOTE" ] && [ $OFFLINE -eq 1 ]; then
  grep -q "Transcription in progress" "$NOTE" && ok "note has the waiting placeholder" || bad "no placeholder in the waiting note"
  grep -q "Pauses: 1" "$NOTE" && ok "pause noted in the note header" || bad "no pause remark"
  grep -q "^source: \"\[\[" "$NOTE" && ok "frontmatter written" || bad "frontmatter"
  echo "SKIP  transcript content checks (no server)"
elif [ -n "$NOTE" ]; then
  grep -qi "budget" "$NOTE" && ok "remote speech before the pause is in the note" || bad "missing 'budget'"
  grep -qi "pineapple" "$NOTE" && bad "PAUSED speech leaked into the note" || ok "speech during the pause is absent"
  grep -qi "invoice" "$NOTE" && ok "remote speech after the pause is in the note" || bad "missing 'invoice'"
  grep -q "⏸ Paused" "$NOTE" && ok "pause marker in the transcript" || bad "no pause marker"
  grep -q "^source: \"\[\[" "$NOTE" && grep -qE "^languages: \[.+\]" "$NOTE" && ok "frontmatter filled" || bad "frontmatter"
  grep -q "tapetum:transcript:start" "$NOTE" && ! grep -q "Transcription in progress" "$NOTE" && ok "placeholder replaced" || bad "placeholder"
fi
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$AUDIO" 2>/dev/null)
echo "      audio duration ${DUR}s (call ~$(( CALL_END - REC0 )) s minus 8 s pause)"
python3 - "$M" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); print("      manifest:", {k:m.get(k) for k in ("status","durationSec","micSilent","sysSilent","attempts","lastError")}, "intervals:", len(m["intervals"]))
PY
grep -q "falling back to plain mic" "$WORK/app.log" && bad "voice processing fell back to plain mic" || ok "voice processing never fell back"
python3 - "$WORK/app.log" <<'PY' || FAIL=$((FAIL+1))
import re, sys
log = open(sys.argv[1]).read()
lat = {m.group(1): float(m.group(2)) for m in re.finditer(r"latency: (.+?) first audio ([+-]\d+) ms", log)}
print("      latency from the call opening the mic:", ", ".join(f"{k} {v:+.0f} ms" for k, v in lat.items()))
first_mic = min(v for k, v in lat.items() if k.startswith("mic")) if any(k.startswith("mic") for k in lat) else 9e9
ok = first_mic < 500 and lat.get("system audio", 9e9) < 500
print(("PASS" if ok else "FAIL") + "  both sides recorded within 0.5 s of the call opening the mic")
sys.exit(0 if ok else 1)
PY
kill $APP 2>/dev/null; wait $APP 2>/dev/null
echo "      log: $WORK/app.log, screenshots: $WORK/shots"
[ $FAIL -eq 0 ] && echo "E2E PASSED" || echo "E2E: $FAIL FAILED"
exit $FAIL
