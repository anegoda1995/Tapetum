#!/bin/bash
# 1) Tapetum is killed (kill -9) in the middle of a call and started again: the cut recording must be finished.
# 2) Pause and stop sent back to back: the note must keep the audio recorded before the pause.
# 3) A frozen remote track: the watchdog must restart it.
# 4) Muted in the call app: the mic is released but the app keeps playing, so the recording must go on with
#    Tapetum's own mic released too, and the mic must come back when the app unmutes.
# 5) A call app on voice processing (like FaceTime): Tapetum must turn voice processing on too.
# Usage: tests/crash_and_race.sh [remote-audio-file] [work dir]. Same requirements as tests/e2e.sh.
# The mute test plays the remote side through the speakers; MUTECALL_OUTPUT=<device name> sends it to another
# output device instead (a virtual one keeps the test silent).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; APPBIN="$ROOT/build/Tapetum.app/Contents/MacOS/Tapetum"
WORK="${2:-$(mktemp -d)}"; REMOTE="${1:-$WORK/remote.wav}"
[ -f "$REMOTE" ] || "$ROOT/tests/tools/make_remote.sh" "$REMOTE"
. "$ROOT/tests/tools/installed.sh"
pause_installed_tapetum
export TAPETUM_HOME="$WORK/home" TAPETUM_NOTES_DIR="$WORK/notes" TAPETUM_TEST_SYSTEM_FILE="$REMOTE"
export TAPETUM_STOP_GRACE=5 TAPETUM_MIN_SEC=5 TAPETUM_START_DELAY=0
# A fresh test home (with TEST_CONFIG, if given) and notes folder for every scenario.
home() {
  rm -rf "${WORK:?}/home" "${WORK:?}/notes"; mkdir -p "$WORK/home" "$WORK/notes"
  [ -n "${TEST_CONFIG:-}" ] && cp "$TEST_CONFIG" "$WORK/home/config.json"
  return 0
}
home
FAIL=0; ok(){ echo "PASS  $*"; }; bad(){ echo "FAIL  $*"; FAIL=$((FAIL+1)); }
st(){ python3 -c "import json;print(json.load(open('$WORK/home/status.json')).get('$1',''))" 2>/dev/null; }
waitfor(){ for _ in $(seq 1 $(( $3 * 2 ))); do [ "$(st "$1")" = "$2" ] && return 0; sleep 0.5; done; return 1; }
dur(){ ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null; }

echo "== crash in the middle of a call"
"$APPBIN" -AppleLanguages "(en)" > "$WORK/crash1.log" 2>&1 & APP=$!
ffmpeg -hide_banner -loglevel error -f avfoundation -i ":0" -t 60 -y "$WORK/call.wav" </dev/null 2>/dev/null & CALL=$!
waitfor state recording 10 && ok "recording" || bad "not recording"
sleep 15
kill -9 $APP; wait $APP 2>/dev/null; ok "Tapetum killed with -9 after ~15 s"
"$APPBIN" -AppleLanguages "(en)" > "$WORK/crash2.log" 2>&1 & APP=$!
sleep 12
grep -q "recovered after an unfinished recording" "$WORK/crash2.log" && ok "restart recovered the cut recording" || bad "no recovery in log"
N1=$(ls "$WORK/notes"/*.md 2>/dev/null | head -1)
[ -n "$N1" ] && ok "note for the cut recording: $(basename "$N1")" || bad "no note for the cut recording"
A1=$(ls "$WORK/notes/audio"/*.m4a 2>/dev/null | head -1); D1=$(dur "$A1")
python3 -c "import sys; d=float('${D1:-0}'); sys.exit(0 if 13 <= d <= 19 else 1)" && ok "cut recording kept ${D1}s (expected ~15 s)" || bad "cut recording length ${D1:-none}"
[ "$(st state)" = "recording" ] && ok "the ongoing call is recorded again after the restart" || bad "not recording after restart: $(st state)"
kill $CALL 2>/dev/null; wait $CALL 2>/dev/null
waitfor state idle 20 && ok "second part finished after the call ended" || bad "second part did not stop"
sleep 3
[ "$(ls "$WORK/notes"/*.md 2>/dev/null | wc -l | tr -d ' ')" = "2" ] && ok "two notes: before and after the crash" || bad "notes: $(ls "$WORK/notes"/*.md | wc -l)"
kill $APP; wait $APP 2>/dev/null

echo "== pause and stop back to back"
home
"$APPBIN" -AppleLanguages "(en)" > "$WORK/race.log" 2>&1 & APP=$!
sleep 2
"$APPBIN" --send start
waitfor state recording 5 || bad "manual start failed"
sleep 10
"$APPBIN" --send pause; "$APPBIN" --send stop
waitfor state idle 5 && ok "stopped right after pause" || bad "state $(st state)"
sleep 6
A2=$(ls "$WORK/notes/audio"/*.m4a 2>/dev/null | head -1); D2=$(dur "$A2")
python3 -c "import sys; d=float('${D2:-0}'); sys.exit(0 if 9 <= d <= 12 else 1)" && ok "note kept the ${D2}s before the pause" || bad "audio length after pause+stop: ${D2:-none}"
kill $APP; wait $APP 2>/dev/null
echo "== frozen remote track: the watchdog must restart it"
home
TAPETUM_TEST_STALL_SYS=8 "$APPBIN" -AppleLanguages "(en)" > "$WORK/stall.log" 2>&1 & APP=$!
sleep 2; "$APPBIN" --send start; waitfor state recording 5 || bad "manual start failed"
sleep 22; "$APPBIN" --send stop; waitfor state idle 5; sleep 6
grep -q "watchdog: sys got no audio" "$WORK/stall.log" && ok "watchdog noticed the frozen remote track" || bad "watchdog silent"
grep -q "capture: restart (watchdog)" "$WORK/stall.log" && ok "capture restarted by the watchdog" || bad "no watchdog restart"
SESSD=$(ls -d "$WORK/home/recordings"/*/ | head -1)
python3 - "$SESSD/sys.m4a" <<'PY' && ok "remote audio is back after the restart" || bad "remote audio did not come back"
import subprocess, struct, math, sys
raw = subprocess.run(["ffmpeg","-v","error","-i",sys.argv[1],"-f","f32le","-ac","1","-ar","16000","-"],capture_output=True).stdout
x = struct.unpack("<%df" % (len(raw)//4), raw)
def rms(a,b): w=x[int(a*16000):int(b*16000)]; return 20*math.log10(max(math.sqrt(sum(v*v for v in w)/max(1,len(w))),1e-9))
gap, late = rms(9.5, 11.5), rms(16, 21)
print(f"      remote level: frozen part {gap:.0f} dB, after restart {late:.0f} dB")
sys.exit(0 if gap < -80 and late > -50 else 1)
PY
kill $APP; wait $APP 2>/dev/null
echo "== muted in the call: mic released but the app still plays the remote side"
home
swiftc -O "$ROOT/tests/tools/mutecall.swift" -o "$WORK/mutecall" 2>/dev/null
TAPETUM_MUTED_MAX=60 "$APPBIN" -AppleLanguages "(en)" > "$WORK/mute.log" 2>&1 & APP=$!
sleep 2
MUTECALL_REOPEN=15 "$WORK/mutecall" "$REMOTE" 8 22 ${MUTECALL_OUTPUT:+"$MUTECALL_OUTPUT"} > "$WORK/mutecall.log" 2>&1 & MC=$!
waitfor state recording 5 && ok "call detected" || bad "call not detected"
sleep 12
[ "$(st state)" = "recording" ] && ok "still recording 4 s after the mic was released (app keeps playing)" || bad "stopped while the app still played: $(st state)"
[ "$(st micReleased)" = "True" ] && ok "Tapetum let go of the mic too while muted" || bad "Tapetum still holds the mic while muted"
sleep 5
[ "$(st micReleased)" = "False" ] && grep -q "the call app uses the mic again" "$WORK/mute.log" && ok "the mic is recorded again after unmuting" || bad "mic not back after unmuting: $(st micReleased)"
wait $MC
T_END=$(date +%s)
waitfor state idle 15 && ok "stopped $(( $(date +%s) - T_END )) s after the app went silent" || bad "did not stop after the app went silent"
grep -q "the call app is silent too" "$WORK/mute.log" && ok "end detected through the app's sound" || bad "no silent-app detection in log"
kill $APP; wait $APP 2>/dev/null
echo "== a call app on voice processing (like FaceTime): Tapetum must follow it into voice processing"
home
swiftc -O "$ROOT/tests/tools/vpcaller.swift" -o "$WORK/vpcaller" 2>/dev/null
"$APPBIN" -AppleLanguages "(en)" > "$WORK/vp.log" 2>&1 & APP=$!
sleep 2
"$WORK/vpcaller" 10 > "$WORK/vpcaller.log" 2>&1 & VC=$!
waitfor state recording 5 && ok "call detected" || bad "call not detected"
waitfor voiceActual True 8 && ok "voice processing turned on to match the call app" || bad "voice processing not turned on: $(st voiceMode)/$(st voiceActual)"
grep -q "the call app records through voice processing" "$WORK/vp.log" && ok "logged why" || bad "no voice processing detection in the log"
wait $VC; kill $APP; wait $APP 2>/dev/null
[ $FAIL -eq 0 ] && echo "CRASH+RACE+STALL+MUTE+VP PASSED" || echo "CRASH+RACE+STALL+MUTE+VP: $FAIL FAILED"
exit $FAIL
