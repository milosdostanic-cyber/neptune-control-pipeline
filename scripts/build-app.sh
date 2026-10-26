#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
OUTPUT_DIR="$PROJECT_DIR/build"
mkdir -p "$OUTPUT_DIR"
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
    BINARY_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
    cp "$BINARY_DIR/NeptuneControl" "$OUTPUT_DIR/NeptuneControl-$ARCH"
done
APP_DIR="$OUTPUT_DIR/Neptune Control.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$OUTPUT_DIR/AppIcon.iconset"
lipo -create "$OUTPUT_DIR/NeptuneControl-arm64" "$OUTPUT_DIR/NeptuneControl-x86_64" -output "$APP_DIR/Contents/MacOS/NeptuneControl"
cp Resources/Claude.icns Resources/Cursor.icns Resources/Claude.png Resources/Cursor.png "$APP_DIR/Contents/Resources/"
xcrun swift scripts/make-icon.swift "$OUTPUT_DIR/icon.png"
cp "$OUTPUT_DIR/NeptuneLogo.png" "$APP_DIR/Contents/Resources/"
cp Resources/StatsBridge.js "$APP_DIR/Contents/Resources/"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$OUTPUT_DIR/icon.png" --out "$OUTPUT_DIR/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$(( SIZE * 2 ))
    sips -z "$DOUBLE" "$DOUBLE" "$OUTPUT_DIR/icon.png" --out "$OUTPUT_DIR/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$OUTPUT_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NeptuneControl</string>
<key>CFBundleIdentifier</key><string>local.milos.neptune-control</string>
<key>CFBundleName</key><string>Neptune Control</string>
<key>CFBundleDisplayName</key><string>Neptune Control</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.milos.neptune-control</string>
<key>CFBundleURLSchemes</key><array><string>neptune-control</string></array>
</dict></array>
</dict></plist>
PLIST
WIDGET_DIR="$APP_DIR/Contents/PlugIns/NeptuneWidget.appex"
mkdir -p "$WIDGET_DIR/Contents/MacOS" "$WIDGET_DIR/Contents/Resources"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -application-extension -D WIDGET_EXTENSION \
        -target "$ARCH-apple-macos14.0" -module-name NeptuneWidget -Xlinker -e -Xlinker _NSExtensionMain \
        Sources/NeptuneControlCore/WidgetSnapshot.swift Sources/NeptuneControlCore/NeptuneMonthlyStats.swift Sources/NeptuneWidget/NeptuneWidget.swift \
        -o "$OUTPUT_DIR/NeptuneWidget-$ARCH"
done
lipo -create "$OUTPUT_DIR/NeptuneWidget-arm64" "$OUTPUT_DIR/NeptuneWidget-x86_64" -output "$WIDGET_DIR/Contents/MacOS/NeptuneWidget"
cp Resources/Claude.icns Resources/Cursor.icns Resources/Claude.png Resources/Cursor.png "$WIDGET_DIR/Contents/Resources/"
cp "$OUTPUT_DIR/NeptuneLogo.png" "$WIDGET_DIR/Contents/Resources/"
cat > "$WIDGET_DIR/Contents/Info.plist" <<'WIDGET_PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NeptuneWidget</string>
<key>CFBundleIdentifier</key><string>local.milos.neptune-control.widget</string>
<key>CFBundleName</key><string>Neptune Control</string>
<key>CFBundleDisplayName</key><string>Neptune Control</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key><dict>
<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
</dict>
</dict></plist>
WIDGET_PLIST
codesign --force --sign - --entitlements Resources/Widget.entitlements "$WIDGET_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf 'App: %s\n' "$APP_DIR"
