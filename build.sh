#!/bin/zsh
# Builds Claude Pet.app into ~/Applications (re-run after editing Sources/ or assets/).
set -e
cd "${0:A:h}"
APP="${APP:-$HOME/Applications/Claude Pet.app}"
BUNDLE_ID="${BUNDLE_ID:-io.github.claudepet}"   # override: BUNDLE_ID=com.you.claudepet ./build.sh
mkdir -p build
rm -f build/ClaudePet
swiftc -O -o build/ClaudePet Sources/*.swift 2>&1 | grep -v '^$' || true
[[ -x build/ClaudePet ]] || exit 1
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/ClaudePet "$APP/Contents/MacOS/"
cp assets/pet.png "$APP/Contents/Resources/"
[[ -f assets/pet_lens.png ]] && cp assets/pet_lens.png "$APP/Contents/Resources/"   # optional glint mask
cp -R assets/web "$APP/Contents/Resources/web"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Opens your Claude conversation in iTerm.</string>
</dict></plist>
PLIST
# Pin the requirement to the bundle ID: the default ad-hoc one is the build's hash, so macOS
# would drop the Screen Recording grant on every rebuild.
codesign --force -s - -r="designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1
echo "built $APP"
