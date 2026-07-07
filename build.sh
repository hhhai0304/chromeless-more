#!/bin/zsh
# Builds Chromeless.app from main.swift. No Xcode project, no dependencies.
set -euo pipefail
cd "${0:a:h}"

APP="Chromeless.app"
ARCH="$(uname -m)"

if [[ ! -f Chromeless.icns ]]; then
  echo "▸ rendering icon"
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Chromeless.icns
fi

echo "▸ compiling ($ARCH)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  main.swift \
  -o "$APP/Contents/MacOS/Chromeless" \
  -framework Cocoa -framework WebKit

cp Chromeless.icns "$APP/Contents/Resources/Chromeless.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Chromeless</string>
  <key>CFBundleDisplayName</key><string>Chromeless</string>
  <key>CFBundleExecutable</key><string>Chromeless</string>
  <key>CFBundleIdentifier</key><string>com.chromeless.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>Chromeless</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHumanReadableCopyright</key><string>chromeless — the browser that isn’t there</string>
</dict>
</plist>
PLIST

# Passkeys require Apple's restricted web-browser.public-key-credential
# entitlement backed by a provisioning profile; macOS SIGKILLs ad-hoc builds
# that claim it. Default: ad-hoc, no entitlement (app hides WebAuthn so sites
# offer fallback sign-in). Once Apple grants the capability to your App ID:
#   PROVISIONING_PROFILE=chromeless.provisionprofile \
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
  fi
  codesign --force --sign "$CODESIGN_IDENTITY" --entitlements chromeless.entitlements "$APP"
  echo "▸ signed as $CODESIGN_IDENTITY with passkey entitlement"
else
  codesign --force --sign - "$APP" 2>/dev/null
fi
SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ built $APP ($SIZE)"
echo "  try:  open $APP"
echo "  or:   ./$APP/Contents/MacOS/Chromeless --help"
