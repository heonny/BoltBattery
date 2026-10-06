#!/bin/sh
# BoltBattery.app 번들 조립. 사용법: scripts/make-app.sh [debug|release]
# SMAppService(로그인 시 실행)와 TCC는 .app 번들 기준이라 swift run만으로는 확인할 수 없다.
#
# SIGN_IDENTITY: "Developer ID Application: …" 같은 서명 identity. 비우면 ad-hoc("-").
#   Developer ID일 때만 Hardened Runtime을 켠다. 공증에 필요하고, ad-hoc 서명에는 의미가 없다.
set -eu
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
APP=.build/BoltBattery.app
SIGN_IDENTITY=${SIGN_IDENTITY:--}

# release는 Intel Mac도 열 수 있게 유니버설로 만든다. 산출물 경로는 구성마다 다르니 SwiftPM에 묻는다.
if [ "$CONFIG" = "release" ]; then
    set -- -c release --product BoltBattery --arch arm64 --arch x86_64
else
    set -- -c "$CONFIG" --product BoltBattery
fi
swift build "$@"
BIN=$(swift build "$@" --show-bin-path)/BoltBattery
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BoltBattery"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
sh scripts/make-icon.sh
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi
echo "$APP"
