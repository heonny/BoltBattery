# Bolt Battery

Logi Bolt 리시버로 연결된 Logitech 마우스의 배터리를 macOS 메뉴바에 표시하는 앱. 마우스 설정을 변경하지 않으며 Options+와 함께 사용할 수 있다.

1차 목표인 배터리 표시, 상태 갱신, 로컬 추이 기록, 개인용 빌드와 설치를 구현했다. macOS 13 이상과 Swift 6을 지원하는 Xcode가 필요하다. 외부 패키지 의존성은 없다.

## 기능

- 메뉴바의 마우스 아이콘과 잔량 숫자, 충전·잔량에 따른 시스템 색상 표시
- 장치 이벤트, 메뉴 열기, 10분 간격 보조 폴링을 통한 갱신
- 리시버 재연결과 Mac 잠자기 해제 시 재조회, 마우스 절전 중 마지막 값 유지
- 시간별·일간·주간 배터리 추이, 수동 갱신, 기록 지우기, 로그인 시 실행
- 상단 오른쪽 설정 메뉴: 아이콘과 퍼센트 / 퍼센트만 / 아이콘만, 파일 로그 켜기·끄기, 앱 정보와 종료

디자인과 정확한 색상·상태 규칙은 [PHILOSOPHY.md](docs/PHILOSOPHY.md)에서 관리한다.

## 빌드와 설치

기존 앱이 실행 중이면 메뉴의 종료 버튼으로 종료한 뒤 설치한다.

```sh
scripts/release.sh
cp -R .build/BoltBattery.app /Applications/
open /Applications/BoltBattery.app
```

릴리스 스크립트는 Apple Silicon과 Intel용 유니버설 앱 및 `.build/BoltBattery-<버전>.dmg`를 만든다. 기본은 개인용 로컬 빌드로, ad-hoc 서명을 사용하고 공증은 하지 않는다. 다른 Mac에서도 사용하려면 해당 Mac에서 로컬 빌드하는 방식을 권장한다. 메뉴의 로그인 시 실행은 `/Applications`에 설치한 뒤 켠다.

Developer ID 서명·공증이 필요할 때는 `SIGN_IDENTITY`와 `NOTARY_PROFILE`을 설정하는 경로가 스크립트에 마련돼 있다. 이 경로는 별도 인증서와 `notarytool` 키체인 프로필이 필요하며, 현재 개인용 배포 절차의 검증 범위에는 포함하지 않는다.

## 기록과 장치 상태

기록은 `~/Library/Application Support/BoltBattery/history.csv`에 시각·슬롯·잔량·충전 여부를 숫자로 저장하며, 장치 이름은 저장하지 않는다. 폴링이나 이벤트로 얻은 새 읽기값을 기록하고 약 6개월간 보관한다. 설정 메뉴의 ‘배터리 기록 초기화…’를 선택하고 시스템 확인 창에서 승인하면 비워진다. 진단 로그 파일과 설정은 유지된다. ‘지금 갱신’도 같은 메뉴에 있다.

앱 시작 시 마우스가 깊은 절전 중이면 발견되지 않을 수 있다. 장치가 없는 동안은 30초 간격으로 다시 찾으므로 마우스를 움직여 깨우거나 수동 갱신한다. Options+ 없이 리시버 알림이 비활성화된 환경에서는 연결 상태 변화가 즉시 반영되지 않을 수 있으며 보조 폴링으로 갱신한다.

시작할 때 입력 모니터링 권한을 일괄 요청하지 않는다. 장치 열기가 권한 문제로 실패하면 메뉴에 표시되는 권한 안내를 따른다. 실제 장치 확인은 Bolt 리시버와 MX Master 3S 기준이며 다른 모델에서의 동작은 별도 확인이 필요하다.

## 개발과 확인

파일 로그는 기본으로 켜져 있으며 `~/Library/Logs/BoltBattery/bolt-battery.log`에 저장한다. 파일당 1MB, 현재 파일과 이전 파일(`.log.1`) 두 개까지만 보관한다. 리시버 연결, 배터리 조회, 통신 재시도·오류, 기록 파일 오류를 남기며 마우스 이동·버튼 입력은 기록하지 않는다. 설정 메뉴에서 파일 로그를 끄면 이후 파일 쓰기를 중단하고 기존 파일은 유지한다. macOS 통합 로그는 계속 사용한다. ‘로그 폴더 열기’로 파일을 확인할 수 있다. 표시 방식과 로그 설정은 재실행 후에도 유지된다.

```sh
swift build
swift test
swift run batteryctl           # 장치와 배터리 한 번 조회
swift run batteryctl watch 5    # 5초 간격으로 상태 확인
swift run batteryctl sniff      # HID++ 알림 확인
scripts/make-app.sh debug
```

시각 변경은 기존 앱을 종료한 뒤 `.build/BoltBattery.app`을 새로 실행해 실제 메뉴바에서 확인한다. `--debug-panel` 실행 인자는 시작 직후 메뉴를 연다. 아이콘 상태별 미리보기 방법은 [PHILOSOPHY.md](docs/PHILOSOPHY.md)에 있다.

개발 제약과 코드 구조는 [CLAUDE.md](CLAUDE.md)를 따른다. 완료한 개발 계획은 Git 이력에 남기고 현재 문서에는 유지하지 않는다.

## 라이선스와 참고 자료

Bolt Battery의 라이선스는 [MIT](LICENSE)다.

HID++ 프레임·기능 조회·배터리 해석은 [Solaar의 고정 리비전](https://github.com/pwr-Solaar/Solaar/tree/e7304c4c451cc9bb4f206a914844525e67856a28/lib/logitech_receiver)을 참고했다. 잔량 레벨을 숫자로 표시하는 근삿값 `90/50/20/5`도 Solaar의 `BatteryLevelApproximation`을 따른다. 참고한 Solaar 소스는 GPL-2.0-or-later이며 해당 저작물의 라이선스를 MIT로 변경하는 것은 아니다. Solaar 파일이나 패키지는 이 저장소와 앱에 포함하지 않는다.
