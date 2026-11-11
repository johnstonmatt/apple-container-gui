#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
zsh scripts/build-icon.zsh
APP="dist/Container Desk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ContainerDesk "$APP/Contents/MacOS/ContainerDesk"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for resource_bundle in .build/release/*.bundle(N); do
  cp -R "$resource_bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ContainerDesk</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.containerdesk.app</string>
<key>CFBundleName</key><string>Container Desk</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/ContainerDesk" --check-catalog
echo "Built $APP"
