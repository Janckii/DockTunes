#!/bin/bash
# Baut DockTunes.app nach ~/Applications
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/DockTunes.app"

echo "→ Alte Version beenden (falls sie läuft)"
pkill -x DockTunes 2>/dev/null || true

echo "→ Bundle anlegen: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>DockTunes</string>
    <key>CFBundleDisplayName</key>       <string>DockTunes</string>
    <key>CFBundleIdentifier</key>        <string>de.jancko.docktunes</string>
    <key>CFBundleExecutable</key>        <string>DockTunes</string>
    <key>CFBundleIconFile</key>          <string>DockTunes</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.2</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>DockTunes analysiert Spotifys Ausgabesignal, um die Anzeige zum Takt der Musik zu bewegen.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>DockTunes liest den laufenden Titel aus Spotify und steuert die Wiedergabe.</string>
</dict>
</plist>
PLIST

echo "→ Symbol einlegen"
cp "$SRC_DIR/icon/DockTunes.icns" "$APP/Contents/Resources/DockTunes.icns"

echo "→ Kompilieren"
swiftc -O -parse-as-library -target arm64-apple-macos14.2 \
    -o "$APP/Contents/MacOS/DockTunes" \
    "$SRC_DIR/DockTunes.swift"

echo "→ Signieren mit dem festen Zertifikat"
# Wichtig: immer dasselbe Zertifikat. Eine Ad-hoc-Signatur wechselt bei jedem
# Bauen die Kennung, dann verlangt macOS jedes Mal neue Freigaben.
if security find-certificate -c "Jancko DockTunes Signing" >/dev/null 2>&1; then
    codesign --force --sign "Jancko DockTunes Signing" "$APP"
else
    echo "   Kein eigenes Zertifikat gefunden, signiere ad-hoc (siehe README, Abschnitt Signatur)."
    codesign --force --sign - "$APP"
fi

echo "✓ Fertig: $APP"
