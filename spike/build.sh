#!/bin/zsh
# Builds and signs WingbarSpike.app. Signing with a stable identity keeps
# the Accessibility / Screen Recording grants valid across rebuilds (SIGN_ID=<identity>).
set -e
cd "$(dirname "$0")"
APP=build/WingbarSpike.app
mkdir -p $APP/Contents/MacOS
swiftc -O Spike.swift -o $APP/Contents/MacOS/WingbarSpike
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.naman.wingbar.spike</string>
<key>CFBundleName</key><string>WingbarSpike</string>
<key>CFBundleExecutable</key><string>WingbarSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PL
codesign --force --sign "${SIGN_ID:--}" $APP
echo "built $APP"
