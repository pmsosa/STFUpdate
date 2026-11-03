#!/bin/zsh
# Build "STFUpdate.app" and a drag-to-Applications DMG into dist/.
#
#   ./build-dmg.sh           universal app, ad-hoc signed (fine for local use; Gatekeeper warns elsewhere)
#   ./build-dmg.sh --sign    Developer ID signed + notarized + stapled. Needs one of:
#                              APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID   (same as the focus project)
#                              NOTARY_PROFILE  a keychain profile from `xcrun notarytool store-credentials`
#                            The signing identity is found in the keychain (override with DEVELOPER_ID).
#   ./build-dmg.sh --release upload dist/*.dmg to a GitHub release for the current VERSION (needs gh)
emulate -L zsh
set -e

cd ${0:A:h}
NAME="STFUpdate"
VERSION=$(tr -d '[:space:]' < VERSION)
DIST=dist
APP="$DIST/$NAME.app"
DMG="$DIST/STFUpdate-$VERSION.dmg"

if [[ ${1:-} == --release ]]; then
  [[ -f $DMG ]] || { print "build the DMG first (./build-dmg.sh --sign)"; exit 1 }
  gh release create "v$VERSION" "$DMG" --title "$NAME $VERSION" --generate-notes
  exit 0
fi

SIGN=0; [[ ${1:-} == --sign ]] && SIGN=1
notary=()
if (( SIGN )); then
  if [[ -z ${DEVELOPER_ID:-} ]]; then
    DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application${APPLE_TEAM_ID:+.*$APPLE_TEAM_ID}" | head -1 | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/')
  fi
  [[ -n $DEVELOPER_ID ]] || { print "no Developer ID Application identity found (set DEVELOPER_ID)"; exit 1 }
  if [[ -n ${NOTARY_PROFILE:-} ]]; then
    notary=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n ${APPLE_ID:-} && -n ${APPLE_APP_SPECIFIC_PASSWORD:-} && -n ${APPLE_TEAM_ID:-} ]]; then
    notary=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    print "set NOTARY_PROFILE, or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID"; exit 1
  fi
  print "signing as: $DEVELOPER_ID"
fi

# the script carries its own version string
grep -q "^VERSION_STR=\"$VERSION\"" stfupdate || { print "VERSION_STR in stfupdate does not match VERSION ($VERSION)"; exit 1 }

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 app/*.swift -o $tmp/uos-$arch
done
lipo -create $tmp/uos-arm64 $tmp/uos-x86_64 -output "$APP/Contents/MacOS/STFUpdate"

cp app/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp stfupdate "$APP/Contents/Resources/stfupdate"

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
  xcrun notarytool submit "$DMG" "${notary[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
print "built $DMG"
