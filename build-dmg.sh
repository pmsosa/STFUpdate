#!/bin/zsh
# Build "Update or STFU.app" and a drag-to-Applications DMG into dist/.
#
#   ./build-dmg.sh           universal app, ad-hoc signed (fine for local use; Gatekeeper warns elsewhere)
#   ./build-dmg.sh --sign    Developer ID signed + notarized + stapled. Needs:
#                              DEVELOPER_ID    e.g. "Developer ID Application: Your Name (TEAMID)"
#                              NOTARY_PROFILE  a keychain profile from `xcrun notarytool store-credentials`
#   ./build-dmg.sh --release upload dist/*.dmg to a GitHub release for the current VERSION (needs gh)
emulate -L zsh
set -e

cd ${0:A:h}
NAME="Update or STFU"
VERSION=$(tr -d '[:space:]' < VERSION)
DIST=dist
APP="$DIST/$NAME.app"
DMG="$DIST/UpdateOrSTFU-$VERSION.dmg"

if [[ ${1:-} == --release ]]; then
  [[ -f $DMG ]] || { print "build the DMG first (./build-dmg.sh --sign)"; exit 1 }
  gh release create "v$VERSION" "$DMG" --title "$NAME $VERSION" --generate-notes
  exit 0
fi

SIGN=0; [[ ${1:-} == --sign ]] && SIGN=1
if (( SIGN )); then
  : ${DEVELOPER_ID:?set DEVELOPER_ID} ${NOTARY_PROFILE:?set NOTARY_PROFILE}
fi

# the script carries its own version string
grep -q "^VERSION_STR=\"$VERSION\"" update-or-stfu || { print "VERSION_STR in update-or-stfu does not match VERSION ($VERSION)"; exit 1 }

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 app/*.swift -o $tmp/uos-$arch
done
lipo -create $tmp/uos-arm64 $tmp/uos-x86_64 -output "$APP/Contents/MacOS/UpdateOrSTFU"

cp app/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp update-or-stfu "$APP/Contents/Resources/update-or-stfu"

swiftc -O tools/make-icon.swift -o $tmp/make-icon
$tmp/make-icon $tmp/AppIcon.iconset
iconutil -c icns $tmp/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

if (( SIGN )); then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

stage=$tmp/stage; mkdir $stage
cp -R "$APP" $stage/
ln -s /Applications $stage/Applications
hdiutil create -volname "$NAME" -srcfolder $stage -ov -format UDZO "$DMG" >/dev/null

if (( SIGN )); then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
print "built $DMG"
