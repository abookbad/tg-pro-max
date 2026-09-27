#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product TGProMax
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/TG PRO MAX.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TGProMax" "$APP/Contents/MacOS/TGProMax"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.tgpromax.monitor</string>
<key>CFBundleName</key><string>TG PRO MAX</string>
<key>CFBundleDisplayName</key><string>TG PRO MAX</string>
<key>CFBundleExecutable</key><string>TGProMax</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
