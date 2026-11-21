#!/bin/bash
# Builds LobsterOne.saver with swiftc, no Xcode project needed.
#   ./build.sh            build into ./build
#   ./build.sh install    also copy into ~/Library/Screen Savers
#
# Optional environment, used by the release workflow:
#   SIGN_IDENTITY   codesign identity; default "-" (ad-hoc, this Mac only). A real identity
#                   also gets the hardened runtime and a timestamp, as notarization requires.
#   SAVER_VERSION   CFBundleShortVersionString, normally the app's marketing version
#   SAVER_BUILD     CFBundleVersion, normally the app's build number. The app replaces an
#                   installed copy whose CFBundleVersion differs from the one it carries.
set -euo pipefail

cd "$(dirname "$0")"

NAME="LobsterOne"
BUNDLE="build/$NAME.saver"
APP_SOURCES="../Sources/LobsterOne"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Shared with the app so both sides agree on the snapshot format. Foundation-only files.
SOURCES=(
    LobsterOneSaverView.swift
    DenView.swift
    StyleViews.swift
    "$APP_SOURCES/Models/ScreensaverSnapshot.swift"
    "$APP_SOURCES/Models/SevenDayBurn.swift"
)

rm -rf build
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
PLIST="$BUNDLE/Contents/Info.plist"
[[ -n "${SAVER_VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SAVER_VERSION" "$PLIST"
[[ -n "${SAVER_BUILD:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SAVER_BUILD" "$PLIST"
cp "$APP_SOURCES"/Resources/Fonts/*.ttf "$APP_SOURCES"/Resources/Fonts/*-OFL.txt "$BUNDLE/Contents/Resources/"
# Sprites: see Sprites/README.md.
cp Sprites/*.png "$BUNDLE/Contents/Resources/"
# The tile System Settings shows in its screensaver picker, by its conventional names.
cp thumbnail.png thumbnail@2x.png "$BUNDLE/Contents/Resources/"

for ARCH in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -parse-as-library \
        -module-name LobsterOneSaver \
        -target "$ARCH-apple-macos14.0" -sdk "$SDK" \
        -emit-library -Xlinker -bundle \
        -framework ScreenSaver \
        -o "build/LobsterOneSaver-$ARCH" \
        "${SOURCES[@]}"
done
lipo -create build/LobsterOneSaver-arm64 build/LobsterOneSaver-x86_64 \
    -output "$BUNDLE/Contents/MacOS/LobsterOneSaver"
rm build/LobsterOneSaver-arm64 build/LobsterOneSaver-x86_64

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - "$BUNDLE"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$BUNDLE"
fi
codesign --verify --strict "$BUNDLE"

echo "Built $BUNDLE"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/$NAME.saver"
    cp -R "$BUNDLE" "$DEST/"
    echo "Installed to $DEST/$NAME.saver"
fi
