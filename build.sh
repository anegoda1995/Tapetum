#!/bin/bash
# Builds Tapetum.app into ./build. Command Line Tools are enough, Xcode is not needed.
# UNIVERSAL=1 ./build.sh builds for Apple silicon and Intel and joins both into one binary.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Tapetum.app
ID=io.github.anegoda1995.tapetum

if [ "${UNIVERSAL:-0}" = 1 ]; then
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.2"
  done
  mkdir -p build
  BIN=build/Tapetum-universal
  lipo -create -output "$BIN" .build/arm64-apple-macosx/release/Tapetum .build/x86_64-apple-macosx/release/Tapetum
else
  swift build -c release
  BIN=.build/release/Tapetum
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tapetum"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/uk.lproj Resources/MenuBar "$APP/Contents/Resources/"
# Ad-hoc signature: macOS ties the microphone and system audio permissions to it,
# so after every rebuild the permissions have to be granted again.
codesign --force --sign - --identifier "$ID" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Tapetum"))"
