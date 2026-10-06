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

- 메뉴바에 배터리 잔량과 충전 상태를 표시합니다.
- 아이콘과 퍼센트, 퍼센트만, 아이콘만 표시하도록 선택할 수 있습니다.
- 시간별·일간·주간 배터리 기록을 확인할 수 있습니다.
- 장치 재연결과 Mac 잠자기 해제 시 상태를 갱신합니다.
- 로그인 시 자동 실행과 진단 로그 저장을 지원합니다.
- 문제 확인용 진단 정보를 복사하고 배터리 기록을 CSV로 내보낼 수 있습니다.
- 배터리 부족 알림을 10%·20%·30% 이하로 설정할 수 있습니다. 기본은 꺼짐입니다.
- 시스템·라이트·다크 테마를 선택할 수 있습니다.

## 요구 사항

- macOS 13 이상
- Logi Bolt 리시버로 연결된 Logitech 마우스
- 소스 빌드 시 Swift 6을 지원하는 Xcode

Apple Silicon과 Intel Mac을 지원합니다. 실제 장치 동작은 MX Master 3S와 Bolt 리시버에서 확인했습니다. 다른 모델은 별도 확인이 필요합니다. Options+는 필수가 아닙니다.

## 설치

### DMG로 설치

릴리즈에 DMG가 제공되는 경우 다음 순서로 설치합니다. 실행에는 Xcode나 별도 라이브러리가 필요하지 않습니다.

1. 이 저장소의 [Releases](https://github.com/heonny/BoltBattery/releases)에서 DMG를 받습니다.
2. DMG를 열고 `BoltBattery.app`을 `Applications` 폴더로 옮깁니다.
3. 기존 앱이 실행 중이면 종료한 뒤, 응용 프로그램 폴더의 앱을 실행합니다.

기본 릴리즈 스크립트는 ad-hoc 서명을 사용하며 Apple 공증을 포함하지 않습니다. 다운로드한 앱이 개발자 확인 또는 공증 문제로 차단되면, 출처를 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**에서 해당 앱의 실행을 허용할 수 있습니다. 이는 아래의 장치 접근·알림 권한과 별개입니다. [Apple의 앱 실행 안내](https://support.apple.com/ko-kr/102445)를 참고해 주세요.

Gatekeeper 전체 비활성화나 격리 속성 일괄 제거는 설치 절차에 포함하지 않습니다. 악성 소프트웨어·앱 손상 경고가 나타나면 강제로 실행하지 말고 다운로드 출처와 파일을 확인해 주세요. 관리되는 Mac에서는 조직 정책에 따라 실행 허용이 제한될 수 있습니다.

### 소스에서 빌드

Swift 6을 지원하는 Xcode가 필요합니다. 외부 패키지 설치는 필요하지 않습니다.

```sh
git clone https://github.com/heonny/BoltBattery.git
cd BoltBattery
scripts/release.sh
cp -R .build/BoltBattery.app /Applications/
open /Applications/BoltBattery.app
```

기존 앱이 실행 중이라면 종료한 뒤 설치합니다. 빌드 결과로 유니버설 앱과 DMG가 생성됩니다. 기본 빌드는 ad-hoc 서명을 사용하며 Apple 공증은 포함하지 않습니다.

배포자는 `SIGN_IDENTITY`에 Developer ID Application 인증서를, `NOTARY_PROFILE`에 미리 등록한 `notarytool` 키체인 프로필을 지정해 `scripts/release.sh`에서 서명·공증·티켓 첨부를 수행할 수 있습니다. CI의 서명 검증 통과가 Apple 공증 완료를 뜻하지는 않습니다.

## 권한과 시스템 접근

| 항목 | 사용 목적과 허용 시점 |
|---|---|
| USB / HID 장치 접근 | IOKit으로 Logi Bolt 리시버의 장치·배터리 상태를 조회합니다. 독점 모드로 열지 않으며 마우스 설정을 변경하지 않습니다. |
| 입력 모니터링 | 리시버 열기가 권한 문제로 거부된 경우에만 앱에 허용 버튼을 표시합니다. 버튼을 누르면 시스템 권한을 요청하고 설정을 엽니다. 시작 시 일괄 요청하지 않습니다. 테스트 환경에서는 이 권한 없이 동작했으나 다른 Mac에서는 필요할 수 있습니다. |
| 알림 | 기본은 꺼짐입니다. ‘배터리 부족 알림’에서 기준을 선택할 때 알림·소리 권한을 요청합니다. 거부해도 잔량 표시와 기록은 사용할 수 있습니다. |
| 로그인 시 실행 | 사용자가 켰을 때 `SMAppService`로 앱을 등록합니다. macOS가 추가 승인을 요구하면 시스템 설정의 로그인 항목에서 허용합니다. 앱이 별도 데몬이나 LaunchAgent 파일을 설치하지는 않습니다. |
| 파일 저장 | 사용자 Library 아래에 기록·설정을 저장합니다. CSV 내보내기는 시스템 저장 창에서 사용자가 선택한 파일에 씁니다. 저장 위치에 따라 macOS가 폴더 접근 승인을 요청할 수 있습니다. |
| 클립보드 | ‘진단 → 진단 정보 복사’를 선택했을 때만 진단 내용을 씁니다. 기존 클립보드 내용은 대체하며, 클립보드를 읽거나 감시하지 않습니다. |

일부 Apple Silicon Mac 노트북에서는 리시버를 연결할 때 macOS의 USB 액세서리 연결 허용이 먼저 필요할 수 있습니다. 이는 Bolt Battery 전용 권한이 아닌 시스템의 액세서리 보안 설정입니다. [Apple의 USB 액세서리 안내](https://support.apple.com/ko-kr/102282)를 참고해 주세요.

현재 앱은 손쉬운 사용, 전체 디스크 접근, 화면 기록, 카메라, 마이크, 위치 또는 Bluetooth 권한을 요청하지 않습니다. 키보드 입력이나 일반 마우스 클릭·이동을 기록하지 않습니다. 관리자 권한으로 실행하거나 별도 드라이버를 설치할 필요도 없습니다. 입력 모니터링 권한 자체는 넓은 권한이므로, 실제 장치 접근 오류가 발생한 경우에만 허용해 주세요.

## 저장 위치와 데이터

`~`는 현재 사용자의 홈 폴더를 뜻합니다. 아래는 설치된 앱이 직접 관리하는 데이터와 주요 시스템 저장 항목입니다. 일반 사용을 위해 앱 설치 폴더에 데이터를 쓰지는 않습니다.

| 위치 / 파일 | 내용과 생성 시점 | 보관 방식 |
|---|---|---|
| `/Applications/BoltBattery.app` | 사용자가 설치하는 실행 파일·아이콘·앱 메타데이터입니다. | 앱을 업데이트하거나 삭제할 때 교체·제거합니다. |
| `~/Library/Application Support/BoltBattery/history.csv` | 배터리를 읽으면 측정 구간 시각, 장치 슬롯, 잔량, 충전 여부를 저장합니다. 장치 이름은 포함하지 않습니다. | 슬롯별 10분 구간에 하나씩 저장하며 최근 183일을 유지합니다. 앱 실행 중 로드·기록 처리에서 오래된 항목을 정리합니다. |
| `~/Library/Logs/BoltBattery/bolt-battery.log` | ‘진단 로그 쓰기’를 켠 경우 실행·연결·통신·배터리 상태와 오류를 저장합니다. 기본은 꺼짐입니다. | 파일당 최대 1 MiB입니다. 한도를 넘기기 전에 기존 파일을 `.log.1`로 회전합니다. |
| `~/Library/Logs/BoltBattery/bolt-battery.log.1` | 직전 진단 로그 파일입니다. | 이전 파일 한 개만 유지하여 두 로그의 합계는 최대 2 MiB입니다. 기간 기준 자동 삭제는 하지 않습니다. |
| `UserDefaults` 도메인 `com.heonny.BoltBattery` | 표시 방식, 테마, 진단 로그 설정, 알림 기준, 슬롯별 장치 이름, 알림 중복 방지 이력을 저장합니다. | macOS가 관리합니다. 일반적인 파일 위치는 `~/Library/Preferences/com.heonny.BoltBattery.plist`이며 별도 만료 기간은 없습니다. |
| 사용자가 선택한 `BoltBattery-history.csv` | ‘진단 → 배터리 기록 내보내기…’에서 전체 보관 기록의 스냅샷을 저장합니다. 파일 이름과 위치는 변경할 수 있습니다. | 자동 삭제하지 않으며 원본 기록과 별개입니다. |
| macOS 통합 로그 (`bolt-battery` subsystem) | 앱과 리시버의 상태·오류 메시지를 OSLog에 남깁니다. **진단 파일 로그가 꺼져 있어도 사용합니다.** | 보관 위치·기간은 macOS가 관리하며 앱에서 제한하거나 초기화하지 않습니다. |

로그 파일은 생성 시 소유자만 읽고 쓸 수 있도록 `0600`, 로그 기록기가 새로 만드는 폴더는 `0700` 권한을 지정합니다. 기존 폴더의 권한을 일괄 변경하지는 않습니다. 배터리 기록·내보낸 CSV에는 별도의 암호화를 적용하지 않으며 파일 접근 권한은 macOS의 일반 파일 생성 설정을 따릅니다.

내부 `history.csv`는 헤더 없이 `Unix 시각(초),슬롯,잔량,충전 여부(0/1)`를 저장합니다. 내보낸 CSV는 `timestamp_utc,slot,percent,is_charging` 헤더와 ISO 8601 UTC 시각을 사용합니다. 충전 값 `1`은 해당 10분 구간에 충전 기록이 있었다는 뜻이며 구간 내내 충전했다는 뜻은 아닙니다. 기록이 없으면 헤더만 내보냅니다.

알림 허용 상태·전달된 알림과 로그인 항목 등록은 macOS가 별도로 관리합니다. 소스 빌드 시에는 저장소의 `.build/` 아래에 빌드 중간 파일, 앱과 DMG가 생성됩니다. 개발용 debug 빌드에서 `BOLT_DEBUG_ICON`을 지정한 경우에만 해당 경로에 아이콘 미리보기 PNG를 씁니다.

### 진단 정보 공유

‘진단 정보 복사’에는 앱·macOS 버전, 복사 시각, 리시버 상태, 감지 장치 수, 슬롯, 응답 여부, 배터리 잔량·충전·추정 여부, 마지막 확인 시각, 기록 수와 앱 설정이 포함됩니다. 장치 이름·리시버 식별자, 사용자 경로와 원본 로그는 포함하지 않습니다.

원본 로그에는 장치 이름, 제품 ID, 리시버의 시스템 식별 정보, 통신 오류와 파일 경로가 포함될 수 있습니다. CSV와 진단 정보의 시각도 사용 패턴을 드러낼 수 있으므로, 공개 이슈에 첨부하기 전 내용을 확인하고 필요하지 않은 정보를 지워 주세요. 파일 로그를 끄면 새 기록만 중단되며 기존 로그는 삭제되지 않습니다. ‘로그 폴더 열기…’는 파일 로그가 꺼져 있어도 폴더가 없으면 생성합니다.

현재 앱에는 분석·텔레메트리, 자동 업데이트 확인 또는 외부 서버로 데이터를 전송하는 기능이 없습니다. 진단 복사와 CSV 내보내기 역시 업로드하지 않습니다. 단, 사용자가 선택한 클라우드 동기화 폴더나 macOS의 클립보드 공유·백업 기능에 따른 처리는 해당 서비스 설정을 따릅니다.

### 기록 초기화와 제거

- ‘배터리 기록 초기화…’는 시스템 확인 창에서 승인한 뒤 저장된 배터리 기록을 비웁니다. 설정과 진단 로그는 유지하며, 앱이 계속 실행되면 새 배터리 기록이 다시 쌓입니다.
- 앱을 제거하려면 먼저 ‘로그인 시 실행’을 끄고 앱을 종료한 뒤 `BoltBattery.app`을 삭제합니다. 앱만 삭제해도 사용자 Library의 기록·설정은 자동 삭제되지 않습니다.
- 데이터도 제거하려면 앱을 종료한 상태에서 위의 `Application Support/BoltBattery`와 `Logs/BoltBattery` 폴더를 Finder로 확인한 뒤 삭제합니다. 직접 내보낸 CSV는 선택했던 위치에서 따로 삭제합니다.
- 환경설정까지 초기화하려면 앱 종료 후 `defaults delete com.heonny.BoltBattery`를 실행합니다. 이 명령은 해당 앱의 설정·장치 이름·알림 중복 방지 이력을 삭제하며, macOS의 권한·로그인 항목·통합 로그는 제거하지 않습니다. 권한은 시스템 설정에서 별도로 관리합니다.

## 개발 및 기여

```sh
swift build
swift test
scripts/make-app.sh debug
```

CI에서 단위 테스트와 유니버설 앱 빌드·서명을 검증합니다. 실제 리시버와 메뉴 UI는 로컬에서 확인합니다.

버그 제보와 개선 제안은 [Issues](https://github.com/heonny/BoltBattery/issues)에 남겨 주세요. 장치 모델, macOS 버전, 재현 방법을 함께 알려주시면 도움이 됩니다. Pull Request도 환영합니다.

개발 구조와 제약은 [개발 가이드](CLAUDE.md), UI 원칙은 [디자인 철학](docs/PHILOSOPHY.md)을 참고해 주세요.

## 라이선스

[MIT License](LICENSE)를 따릅니다.

HID++ 통신 구현에는 [Solaar](https://github.com/pwr-Solaar/Solaar)를 참고했습니다.
