# shellcheck shell=bash
# Sourced by the integration tests. An installed Tapetum would take the tests' fake calls for real ones and record
# them into your notes, so its automatic recording is paused for the run and turned back on afterwards (only if it
# was on). The tests refuse to start while it is recording a call.
INSTALLED_BIN=/Applications/Tapetum.app/Contents/MacOS/Tapetum
INSTALLED_STATUS="$HOME/Library/Application Support/Tapetum/status.json"

installed_get() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$INSTALLED_STATUS" "$1" 2>/dev/null; }

pause_installed_tapetum() {
  pgrep -qf "$INSTALLED_BIN" && [ -f "$INSTALLED_STATUS" ] || return 0
  if [ "$(installed_get state)" != "idle" ]; then
    echo "The installed Tapetum is recording a call right now; run the tests later." >&2
    exit 1
  fi
  [ "$(installed_get autoRecord)" = "True" ] || return 0
  env -u TAPETUM_HOME "$INSTALLED_BIN" --send auto-off
  trap 'env -u TAPETUM_HOME "$INSTALLED_BIN" --send auto-on' EXIT
  echo "      installed Tapetum: automatic recording paused for the tests"
}
