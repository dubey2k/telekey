#!/bin/sh
# Builds build/Telekey.app (Apple silicon + Intel, macOS 14+) with adb and scrcpy's server inside,
# and dist/Telekey.zip to attach to a GitHub release tagged v<version>. Needs Xcode's command line tools; nothing else.
set -eu
cd "$(dirname "$0")"

VERSION=1.0.0
# Pinned dependencies, checked by SHA-256. To upgrade: change the version, run once, paste the new hash.
# The scrcpy server's control protocol must match Sources/Link.swift, so test before bumping it.
SCRCPY=5.0.1  SCRCPY_SHA=764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536
ADB=37.0.1    ADB_SHA=1811e253b21b12cbfda7201ebaf86c10e7ddcb5c606a7a81f7c82b4c429c2d3b

ok() { echo "$1  $2" | shasum -a 256 -c -s 2>/dev/null; }
mkdir -p vendor
ok "$SCRCPY_SHA" vendor/scrcpy-server ||
  curl -fL -o vendor/scrcpy-server "https://github.com/Genymobile/scrcpy/releases/download/v$SCRCPY/scrcpy-server-v$SCRCPY"
ok "$ADB_SHA" vendor/adb || {
  curl -fL -o vendor/platform-tools.zip "https://dl.google.com/android/repository/platform-tools_r$ADB-darwin.zip"
  unzip -o -j vendor/platform-tools.zip platform-tools/adb platform-tools/NOTICE.txt -d vendor
  rm vendor/platform-tools.zip
}
ok "$SCRCPY_SHA" vendor/scrcpy-server || { echo "vendor/scrcpy-server doesn't match the pinned hash" >&2; exit 1; }
ok "$ADB_SHA" vendor/adb || { echo "vendor/adb doesn't match the pinned hash" >&2; exit 1; }

APP=build/Telekey.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"  # explicit SDK: stray headers in /usr/local/include otherwise break the build

# checks first (Tests/checks.swift): a broken command runner would break everything else
swiftc -sdk "$SDK" -parse-as-library -swift-version 6 Sources/Shell.swift Tests/checks.swift -o build/checks
build/checks
for arch in arm64 x86_64; do
  swiftc -sdk "$SDK" -target "$arch-apple-macos14" -parse-as-library -swift-version 6 -O \
    Sources/*.swift Sources/UI/*.swift -o "build/Telekey-$arch"
done
lipo -create build/Telekey-arm64 build/Telekey-x86_64 -output "$APP/Contents/MacOS/Telekey"
rm build/Telekey-arm64 build/Telekey-x86_64
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SCRCPY@/$SCRCPY/" Info.plist > "$APP/Contents/Info.plist"
cp vendor/adb vendor/scrcpy-server Resources/AppIcon.icns Resources/THIRD_PARTY.md "$APP/Contents/Resources/"
[ -f vendor/NOTICE.txt ] && cp vendor/NOTICE.txt "$APP/Contents/Resources/adb-NOTICE.txt"
chmod +x "$APP/Contents/Resources/adb"
codesign --force --deep --sign - "$APP"  # ad-hoc: runs here; downloads need "Open Anyway" (see README)

mkdir -p dist
ditto -c -k --keepParent "$APP" dist/Telekey.zip  # fixed name: README links to releases/latest/download/Telekey.zip
echo "Built $APP and dist/Telekey.zip ($VERSION)"
