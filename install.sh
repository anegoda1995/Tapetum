#!/bin/bash
# Builds Tapetum, installs it to /Applications and starts it at login through a LaunchAgent,
# which also restarts it if it ever crashes. ./install.sh --uninstall removes the app and the agent
# (recordings, settings and notes stay).
set -euo pipefail
cd "$(dirname "$0")"
LABEL=io.github.anegoda1995.tapetum
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP=/Applications/Tapetum.app

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "uninstalled; data is still in ~/Library/Application Support/Tapetum"
  exit 0
fi

./build.sh
rm -rf "$APP"
cp -R build/Tapetum.app "$APP"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>AssociatedBundleIdentifiers</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/Tapetum</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/Tapetum.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/Tapetum.log</string>
</dict>
</plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state =|pid =|last exit" || true
echo "installed; log: ~/Library/Logs/Tapetum.log"
