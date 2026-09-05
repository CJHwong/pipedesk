#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="${PIPEDESK_APP_PATH:-$PWD/.build/PipeDesk.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -warnings-as-errors -o "$APP/Contents/MacOS/PipeDesk" src/*.swift
cp assets/PipeDesk.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PipeDesk</string>
  <key>CFBundleIdentifier</key><string>app.pipedesk.desktop</string>
  <key>CFBundleExecutable</key><string>PipeDesk</string>
  <key>CFBundleIconFile</key><string>PipeDesk.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSAppleEventsUsageDescription</key><string>PipeDesk opens Terminal when you choose to install Dumbpipe with Homebrew.</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
