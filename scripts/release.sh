#!/bin/sh
# 릴리스 DMG 생성. 사용법: scripts/release.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh
#
# SIGN_IDENTITY가 없으면 ad-hoc 서명 DMG만 만든다. 다른 Mac에서는 Gatekeeper 경고를 우회해야 열린다.
# NOTARY_PROFILE이 있으면 공증 후 스테이플링까지 한다. 프로필은 한 번만 만들어 두면 된다:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific>
set -eu
cd "$(dirname "$0")/.."

SIGNED=0
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then SIGNED=1; fi
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGNED" = 0 ]; then
    echo "NOTARY_PROFILE requires SIGN_IDENTITY (Apple rejects ad-hoc signatures)" >&2
    exit 1
fi

APP=.build/BoltBattery.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)
DMG=.build/BoltBattery-$VERSION.dmg
STAGE=.build/dmg-stage
ZIP=.build/BoltBattery-notarize.zip
trap 'rm -rf "$STAGE" "$ZIP"' EXIT

scripts/make-app.sh release
codesign --verify --deep --strict "$APP"

# 앱을 먼저 공증·스테이플링해야 DMG에서 꺼낸 앱이 오프라인 첫 실행에서도 티켓을 들고 있다.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Bolt Battery" -srcfolder "$STAGE" -format UDZO "$DMG"

if [ "$SIGNED" = 1 ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "notarization skipped (NOTARY_PROFILE not set)"
fi

echo "$DMG"
