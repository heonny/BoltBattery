#!/bin/sh
# BoltBattery.app 번들 조립. 사용법: scripts/make-app.sh [debug|release]
# SMAppService(로그인 시 실행)와 TCC는 .app 번들 기준이라 swift run만으로는 확인할 수 없다.
set -eu
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
APP=.build/BoltBattery.app

swift build -c "$CONFIG" --product BoltBattery
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/BoltBattery" "$APP/Contents/MacOS/BoltBattery"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
# 임시(ad-hoc) 서명. Developer ID 서명·공증은 Phase 6.
codesign --force --sign - "$APP"
echo "$APP"
