<p align="center">
  <img src="Packaging/AppIcon.png" width="128" height="128" alt="Bolt Battery 앱 아이콘">
</p>

<h1 align="center">Bolt Battery</h1>

<p align="center">
  <a href="https://github.com/heonny/BoltBattery/actions/workflows/ci.yml"><img src="https://github.com/heonny/BoltBattery/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13 이상">
  <img src="https://img.shields.io/badge/Swift-6-orange?logo=swift" alt="Swift 6">
</p>

Logi Bolt 리시버로 연결된 Logitech 마우스의 배터리를 macOS 메뉴바에서 확인합니다.
마우스 설정을 변경하지 않으며, Options+와 함께 사용할 수 있습니다.

<p align="center">
  <img src="docs/demo.png" width="360" alt="Bolt Battery의 배터리 잔량과 사용 기록 화면">
</p>

## 주요 기능

- 메뉴바에서 마우스 배터리 잔량과 충전 상태를 확인합니다.
- 배터리 변화와 충전 기록을 차트로 살펴봅니다.
- 배터리가 부족해지면 알림을 받습니다.

## 설치 및 실행

**macOS 13 이상**, Intel·Apple Silicon Mac에서 사용할 수 있습니다. **Logi Bolt 리시버가 필요하며 Bluetooth 직접 연결은 지원하지 않습니다.** Options+는 필수가 아닙니다.

1. [최신 릴리즈](https://github.com/heonny/BoltBattery/releases/latest)에서 DMG를 받아 `BoltBattery.app`을 `Applications` 폴더로 옮깁니다.
2. Logi Bolt 리시버를 연결하고, 해당 리시버에 페어링된 마우스를 켭니다.
3. 응용 프로그램 폴더에서 Bolt Battery를 실행하고, **화면 위쪽 메뉴바의 마우스 아이콘·잔량**을 클릭합니다. 오른쪽 위 톱니바퀴에서 설정을 변경할 수 있습니다.

현재 배포본은 Apple 공증을 받지 않았습니다. 개발자 확인 문제로 첫 실행이 차단되면 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다. 자세한 권한 설정과 소스 빌드는 [설치 가이드](docs/INSTALLATION.md)를 참고해 주세요.

실제 장치 동작은 MX Master 3S와 Bolt 리시버에서 확인했습니다. 다른 모델은 별도 확인이 필요합니다.

## 버그 제보

문제가 생기면 **설정 → 진단 → 진단 정보 복사**를 선택하고, [이슈](https://github.com/heonny/BoltBattery/issues/new)에 **마우스 모델·재현 방법·기대한 동작·실제 동작**과 함께 붙여 넣어 주세요. 공유 전 내용을 확인해 주세요.

- [문제 해결과 버그 제보](docs/SUPPORT.md): 증상별 확인 방법, 진단 로그와 CSV 첨부 안내
- [권한과 저장 데이터](docs/DATA-AND-PERMISSIONS.md): 사용하는 권한, 저장 위치·파일·보관 기간, 데이터 삭제 방법

## 개발 및 기여

Swift 6을 지원하는 Xcode가 필요하며 외부 패키지 의존성은 없습니다.

```sh
swift build
swift test
scripts/make-app.sh debug
```

CI에서 단위 테스트와 유니버설 앱 빌드·서명을 검증합니다. 개선 제안과 Pull Request를 환영합니다.

[개발 가이드](CLAUDE.md) · [디자인 철학](docs/PHILOSOPHY.md)

## 라이선스

[MIT License](LICENSE)를 따릅니다. 배포 앱의 `Contents/Resources/LICENSE`에도 라이선스 원문과 저작권 고지를 포함합니다.

HID++ 통신 구현에는 [Solaar](https://github.com/pwr-Solaar/Solaar)를 참고했습니다.
