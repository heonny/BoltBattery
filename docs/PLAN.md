# Bolt Battery — 개발 계획

## 프로젝트 개요

Logi Bolt 리시버로 연결된 Logitech 마우스의 배터리를 macOS 메뉴바에 표시하는 Swift 전용 앱.
Options+와 공존하며, 마우스 상태를 절대 바꾸지 않는 읽기 전용 앱이고, CPU·전력 사용을 최소화하는 것이 핵심 목표.

### 기술 결정 사항

- 언어/UI: Swift + SwiftUI `MenuBarExtra`. HID 통신은 IOKit(`IOHIDManager`) 직접 사용. 서드파티 의존성 없음.
- 대상: Bolt 리시버(VID `0x046D`, PID `0xC548`)의 벤더 인터페이스(usage page `0xFF00`). Unifying(`0xC52B`)은 같은 코드로 추가 지원 가능하도록 PID를 목록으로 관리.
- 장치는 반드시 일반 모드(`kIOHIDOptionsTypeNone`)로 열고, 독점 모드(`kIOHIDOptionsTypeSeizeDevice`)는 절대 사용하지 않음.
- 최소 지원 macOS: 13 이상 (`MenuBarExtra`, `SMAppService` 사용).

### 참고 자료

- Solaar: HID++ 프로토콜 레퍼런스. 함수 번호·바이트 위치는 반드시 여기서 교차 확인.
- MXLightkeeper: Swift + Bolt 리시버 통신 구현 참고.
- mx-battery: 잠자기/깨우기 후 IOKit 핸들 재구성 처리 참고.

---

## Phase 0. 공존 검증 스파이크 (반나절)

프로젝트 전체의 리스크를 먼저 제거하는 단계. Options+를 실행한 상태에서 동작하는 CLI 테스트 프로그램을 만든다.

- 리시버의 벤더 인터페이스를 일반 모드로 열고, 슬롯 1~6에 대해 Root 기능(`0x0000`)으로 배터리 기능 인덱스를 조회한 뒤 배터리 값을 한 번 읽어 출력한다.
- 입력 모니터링 권한이 실제로 필요한지도 함께 확인한다.

**완료 기준**
- Options+ 실행 중에도 장치 열기에 성공하고 배터리 %가 정상 출력될 것.
- Options+ 앱에서도 배터리·설정이 계속 정상 동작할 것.
- 실패 시 원인(열기 실패 / 응답 누락)을 기록하고 계획을 재검토한다.

**결과 (2026-10-06, 단일 파일 스파이크로 확인 후 Phase 1 `batteryctl`로 대체)**
- Options+ 에이전트 실행 중에 `kIOHIDOptionsTypeNone`으로 열어 슬롯 2의 MX Master 3S(HID++ 4.5)에서 `0x1004`로 90% 읽기 성공. Options+ 에이전트는 계속 실행됨.
- 입력 모니터링 권한은 `denied` 상태였지만 벤더 인터페이스(`0xFF00`) 열기와 입력 리포트 수신 모두 정상. 즉 이 앱에는 입력 모니터링 권한이 필요 없다 → Phase 5 범위 축소 가능.
- 빈 슬롯은 핑에 HID++ 1.0 에러 `0x09`(RESOURCE_ERROR)로 응답. Solaar가 빈 슬롯으로 보는 `0x08`과 다르므로 빈 슬롯과 절전 장치는 핑만으로 구분 불가.

## Phase 1. HID++ 코어 모듈 (1~2일)

UI와 분리된 Swift Package(`HIDPPKit`)로 만든다. CLI와 앱이 같은 코드를 사용.

- **전송 계층**: 롱 리포트(report ID `0x11`, 20바이트) 형식 `[reportID, deviceIndex, featureIndex, (function << 4) | swID, params...]`으로 요청을 보내고, 입력 리포트 콜백으로 응답을 받는다. 콜백 기반 응답을 `async/await`로 감싸고, 요청마다 타임아웃(예: 1초)을 둔다.
- **응답 구분**: 고유한 소프트웨어 ID를 하나 정해 사용(0은 장치 발신 알림용이므로 제외, Options+와 겹치지 않을 값). deviceIndex·featureIndex·function·swID가 모두 일치하는 응답만 처리하고 나머지는 무시.
- **에러 처리**: featureIndex `0xFF` 에러 응답을 파싱. BUSY나 타임아웃은 짧은 백오프 후 최대 2~3회 재시도.
- **기능 조회**: Root 기능으로 기능 ID → 인덱스를 찾고, 결과를 장치별로 캐시.
- **배터리**: `0x1004`(Unified Battery) 우선, 없으면 `0x1000`(Battery Status)로 폴백. 결과는 `{ percent, isCharging, isApproximate }` 구조체로 반환. `0x1000`은 단계형 값만 주므로 근사치 플래그 사용.
- **장치 열거**: 슬롯 1~6을 조회해 응답하는 장치만 목록화. 가능하면 장치 이름도 조회.
- **테스트**: 전송 계층을 프로토콜로 추상화해서, 실제 장치 없이 바이트 픽스처로 파싱·응답 매칭·에러 처리를 단위 테스트.

**완료 기준**
- CLI(`batteryctl`)에서 연결된 모든 Bolt 기기의 이름과 배터리가 출력될 것.
- 단위 테스트 통과.

**결과 (2026-10-06)**
- `Package.swift`: `HIDPPKit` 라이브러리 + `batteryctl` 실행 타겟 + `HIDPPKitTests`. Swift 6 언어 모드, macOS 13+.
- 계층: `HIDReportChannel`(바이트 채널 프로토콜, IOKit 구현 `IOHIDReportChannel`) → `HIDPPClient`(프레임·응답 매칭·에러·1초 타임아웃·BUSY/타임아웃 3회 재시도, 전용 직렬 큐) → `Receiver` 액터(핑·이름·배터리·기능 인덱스 캐시) → `BatteryReading`.
- 소프트웨어 ID `0x09` 고정. 핑은 재시도하지 않음(생존 확인).
- `swift test` 10개 통과(가짜 채널로 프레임 레이아웃·매칭·에러·타임아웃·재시도 정책·배터리 디코딩·리시버 열거). `swift run batteryctl` → `slot 2: MX Master 3S  HID++ 4.5  90%`.
- 미결: 빈 슬롯과 절전 장치를 핑만으로 구분 못 함(Phase 2에서 리시버 페어링 레지스터로 보완 검토). 슬롯에 다른 장치가 페어링되면 `Receiver.forgetFeatures(slot:)` 호출 필요(Phase 2 핫플러그에서 연결).

## Phase 2. 생명주기와 예외 처리 (1일)

- **핫플러그**: `IOHIDManager`의 장치 연결/해제 콜백으로 리시버 탈착을 감지하고 자동 재연결.
- **잠자기/깨우기**: `NSWorkspace.didWakeNotification` 수신 시 HID 핸들을 버리고 새로 열어 재조회. (mx-battery에서 실제 발생했던 버그이므로 필수)
- **마우스 절전 상태**: 응답이 없으면 에러로 표시하지 말고 마지막 값을 "마지막 확인 시각"과 함께 유지.

**완료 기준**
- 리시버 뽑았다 꽂기, 맥 잠자기 후 깨우기, 마우스 전원 껐다 켜기 세 시나리오에서 수동 개입 없이 복구.

**결과 (2026-10-06, 완료)**
- `ReceiverMonitor`: `IOHIDManager` 매칭/제거 콜백(전용 큐)으로 리시버 탈착 감지, `NSWorkspace.didWakeNotification`에 전부 다시 열기. 열린 `Receiver` 목록을 `AsyncStream`으로 내보냄.
- `BatteryMonitor` 액터: 슬롯 1~6 핑 기반 상태(`DeviceStatus`: 이름·배터리·`lastUpdated`·`isReachable`). 핑 실패 시 마지막 값 유지, 복귀 시 기능 인덱스 캐시 비우고 이름 재조회. 변경 알림은 `lastUpdated`를 제외한 값이 바뀔 때만.
- 함정 기록: 활성화된 `IOHIDManager`가 넘겨주는 `IOHIDDevice`에 입력 리포트 콜백을 등록하면 IOKit이 `SIGTRAP`. `IOHIDDeviceCreate(io_service)`로 독립 객체를 만들어 해결.
- 검증: 단위 테스트 14개(절전→마지막 값 유지→복귀 시 재조회, 복귀 직후 재절전 시 이름 보존, 동시 refresh 중복 방지, 리시버 제거 시 장치 삭제·알림 포함). `batteryctl watch 5`로 실기기 초기 감지·주기 갱신 확인.
- 실기기 확인(2026-10-06, `batteryctl watch 5`): 마우스 전원 끄기 → `90% asleep, last seen 9:18:15` 유지. 리시버 뽑기 → `(no devices)`. 다시 꽂기 → 새 registryID로 재감지, `reachable`.
- 맥 잠자기 후 깨우기도 사용자 확인(2026-10-06).

## Phase 3. 메뉴바 UI (반나절)

- `Info.plist`에 `LSUIElement = YES`로 Dock 아이콘 숨김.
- 메뉴바: 배터리 아이콘 + %. 충전 중이면 아이콘 변경.
- 메뉴: 기기별 이름·%·마지막 갱신 시각, "로그인 시 실행" 토글(`SMAppService.mainApp`), 종료 버튼.
- 선택 사항: 임계치(예: 20%) 이하에서 한 번만 알림(`UserNotifications`).

**완료 기준**
- 메뉴바 표시와 메뉴 동작 확인, 로그인 시 자동 실행 동작.

**결과 (2026-10-06)**
- SwiftPM 실행 타겟 `BoltBattery`(SwiftUI `MenuBarExtra`) + `scripts/make-app.sh`가 `.build/BoltBattery.app`을 조립(`Packaging/Info.plist`, ad-hoc 서명). `.xcodeproj` 없음. Xcode에서는 `Package.swift`를 열면 된다.
- `BatteryModel`(@MainActor): `BatteryMonitor` 변경 스트림을 받아 `devices` 갱신, 10분 폴링(`Task.sleep` tolerance 3분), `SMAppService.mainApp` 토글.
- 메뉴바: 레벨별 `battery.*` 심볼, 충전 중 `battery.100.bolt`, 텍스트 `NN%`. 메뉴: 장치별 이름·%·마지막 확인 시각(절전 표시), 지금 갱신, 로그인 시 실행, 종료(⌘Q).
- `NSApplication.setActivationPolicy(.accessory)`를 코드에서도 호출해 `swift run`으로 띄워도 Dock 아이콘이 없다.
- 확인: 번들 실행 후 메뉴바에 아이콘과 `90%` 표시(스크린샷). 메뉴 내용과 로그인 시 실행 토글은 사용자가 직접 확인.
- 저전력 알림(20% 이하 1회)은 선택 사항이라 미구현. 번들 ID는 `com.heonny.BoltBattery`(2026-10-06 확정).

## Phase 4. 저전력 최적화 (반나절~1일)

- **이벤트 우선**: 장치가 swID 0으로 보내는 배터리 변화 알림을 받아 즉시 갱신. 폴링은 보조 수단.
- **폴링**: 10분 간격, 타이머 `tolerance`를 넉넉히(간격의 20~50%) 설정해 macOS가 다른 작업과 묶어 깨울 수 있게.
- HID 호출은 메인 스레드 밖에서 처리하고, 값이 바뀌었을 때만 UI 상태 갱신.

**완료 기준**
- 활동 모니터 "에너지 영향"이 유휴 시 거의 0으로 유지될 것.
- Instruments로 확인했을 때 불필요한 주기적 깨어남이 없을 것.

**결과 (2026-10-06)**
- 실측(`batteryctl sniff`, Bolt + MX Master 3S, Options+ 실행 중): 리시버 알림 플래그 레지스터 0x00은 `0x000900`(WIRELESS|SOFTWARE_PRESENT, Options+가 켠 값). 전원 끔/켬에 HID++1.0 `0x41` 알림(`42 34 b0` / `02 34 b0`), 0x1D4B "powered on" 이벤트, Unified Battery 이벤트(`5a 08 00`→`55 08 00`, 90→85%)가 들어옴. 휠(0x2121/0x2150)과 Options+가 돌린 버튼(0x1B04) 이벤트는 스크롤 시 초당 수십 개.
- `HIDPPClient`: 응답이 아닌 리포트를 알림으로 분류. HID++1.0 리시버 알림(sub id ≥ 0x40)은 항상, 2.0 기능 이벤트는 `watchNotifications`로 등록된 (슬롯, 기능 인덱스)만 통과. 판정은 할당 없이 HID 큐에서 끝낸다.
- `Receiver`: 배터리 기능 인덱스를 알게 되면 즉시 필터 등록, `forgetFeatures`에서 해제. `notifications` 스트림 제공.
- `BatteryMonitor`: 배터리 이벤트는 요청 없이 값 반영, `0x41` 링크 끊김은 즉시 절전 표시, 링크 복구는 슬롯 재조회. 같은 값 반복 이벤트는 UI를 깨우지 않음. 폴링(10분, tolerance 3분)은 보조.
- 실기기: `batteryctl watch 600`에서 전원 끔 즉시 `asleep`, 켬 즉시 `reachable`. 앱 유휴 60초 CPU 시간 0.25초(디버그 빌드, 기동 직후 포함).
- 미결: Options+ 없이 리시버 알림 플래그가 꺼져 있으면 `0x41`이 오지 않는다. 그 경우 레지스터 0x00 쓰기(리시버 설정 변경)가 필요한데 읽기 전용 원칙과 충돌하므로 사용자 결정 필요. 배터리 이벤트(2.0)는 플래그와 무관하게 온다고 추정하나 미검증.

## Phase 5. 권한 처리 (반나절)

- 실행 시 `IOHIDCheckAccess`로 입력 모니터링 권한 확인, 없으면 `IOHIDRequestAccess`로 요청.
- 권한 거부 상태에서는 메뉴에 안내 문구와 "시스템 설정 열기" 버튼 표시.

**완료 기준**
- 새 사용자 계정에서 처음 실행해도 안내를 따라 정상 동작에 도달.

**결과 (2026-10-06, 계획 축소)**
- Phase 0 실측대로 벤더 인터페이스는 입력 모니터링 권한 없이 열리므로 시작 시 `IOHIDRequestAccess`를 부르지 않는다. 불필요한 권한을 요구하지 않는 쪽이 사용자에게도 낫다.
- `ReceiverMonitor.state` 스트림(`ReceiverState`): `noReceiver` / `openFailed(reason, needsInputMonitoring)` / `ready(count)`. 열기 실패한 리시버는 `failed`에 보관하고 `retry()`로 다시 연다. `kIOReturnNotPermitted`일 때만 입력 모니터링 안내.
- 메뉴: 리시버 없음 → "Bolt 리시버가 연결되지 않았습니다", 열기 실패 → 사유 + (권한이면) "입력 모니터링 권한 허용…"(`IOHIDRequestAccess` + 시스템 설정 열기) + "다시 시도", 정상인데 장치 없음 → "응답하는 장치가 없습니다".
- 확인: 정상 경로는 실기기로 확인(메뉴바 85%). 열기 실패 경로는 이 환경에서 재현 불가(권한이 필요 없음). 리시버 없음 문구는 리시버를 뽑아 확인 가능.

## Phase 6. 배포 (반나절~1일)

- Hardened Runtime 활성화, Developer ID로 서명, `notarytool`로 공증, 스테이플링 후 DMG 생성.
- GitHub Releases 업로드, 선택적으로 Homebrew Cask 추가.
- 빌드~공증 과정을 스크립트 또는 GitHub Actions로 자동화.

**완료 기준**
- 다른 맥에서 다운로드 후 Gatekeeper 경고 없이 실행.

**결과 (2026-10-06, ad-hoc 경로까지 확인 · Developer ID 경로는 인증서 대기)**
- `scripts/make-app.sh`: release는 arm64+x86_64 유니버설(경로는 `--show-bin-path`로 질의). `SIGN_IDENTITY`가 있으면 Hardened Runtime + timestamp로 서명, 없으면 ad-hoc.
- `scripts/release.sh`: `NOTARY_PROFILE`만 있고 identity가 없으면 즉시 실패. release 빌드 → 번들 검증 → (프로필 있으면 앱을 zip으로 먼저 공증·스테이플링, 오프라인 첫 실행 대비) → `hdiutil`로 `.build/BoltBattery-<버전>.dmg`(Applications 심볼릭 링크 포함) → identity가 있으면 DMG 서명 → `NOTARY_PROFILE`이 있으면 `notarytool submit --wait` + `stapler staple` + `spctl` 검증.
- 확인: ad-hoc으로 DMG 생성, 마운트 후 실행, 번들 ID `com.heonny.BoltBattery`. `spctl`은 ad-hoc이라 예상대로 거부.
- 배포 방식 결정(2026-10-06): 개인용이라 Developer ID 계정을 쓰지 않는다. 로컬에서 `scripts/release.sh`(ad-hoc)로 만들어 쓴다. 절차는 `README.md`. Developer ID·공증 경로는 스크립트에 남겨 두었고 인증서와 `notarytool` 프로필만 있으면 그대로 쓸 수 있다. GitHub Releases·Homebrew Cask·Actions는 하지 않는다.

---

## 추가 기능. 배터리 추이 (2026-10-06)

사용자 요청: 10분 간격으로 로컬 파일에 적재하고, RunCat Neo처럼 팝오버 안에 시간별·일간·주간 세 탭의 차트를 보여준다. 보존 6개월, 지우기 기능, 숫자만 저장, 파일 문제로 앱이 죽지 않을 것. 압축은 "별로면 안 해도 됨".

**결정**
- 저장: `~/Library/Application Support/BoltBattery/history.csv`, 한 줄에 `초 단위 시각,슬롯,퍼센트,충전(0/1)`. 장치 이름은 저장하지 않는다. 압축은 하지 않는다. 6개월치가 1MB 미만이고, 압축 파일은 덧붙일 수 없어 매번 다시 써야 해 깨질 위험만 는다.
- 적재: 폴링(10분)·이벤트로 `lastUpdated`가 바뀐 읽기값만 기록. 절전 중엔 새 값이 없으니 기록하지 않는다(선이 끊긴다).
- 보존: 시작 시 6개월 초과분을 잘라 다시 쓴다. 기록 중에는 하루 이상 초과한 게 있을 때만 다시 써서 10분마다 전체를 다시 쓰지 않는다.
- 탭: 시간별 = 최근 24시간 원본, 일간 = 최근 7일 시간 평균, 주간 = 최근 12주 일 평균. 충전 중 샘플이 있는 구간은 초록 점.
- UI(여러 번 실물 확인 끝에 확정): `NSStatusItem` + 시스템 `NSMenu`, 메뉴 항목 하나에 SwiftUI 뷰(`NSHostingView`)를 통째로 넣는다. macOS 26부터 시스템 메뉴가 Liquid Glass라 배터리 메뉴와 같은 유리·그림자·모서리를 OS가 그린다. 거쳐 간 실패: `MenuBarExtra .window`와 `NSPopover`는 불투명 재질을 밑에 깔아 글래스가 가려지고, 직접 만든 투명 `NSPanel`은 창 그림자가 둥근 유리가 아닌 창 사각형을 따라 네모로 비쳤다. 차트만 불투명 카드에 올린다. 버튼은 텍스트 없는 정사각 아이콘(갱신·지우개·로그인 시 실행 토글 `autostartstop`·종료), 평소엔 배경 없고 호버 시 같은 색 불투명도만 올린다(스타일을 갈아끼우면 번쩍임). 호버 설명은 툴팁 상자 대신 버튼 줄 가운데에 뜬다. "기록 지우기"는 같은 자리의 체크/X 두 단계.
- 스크린샷 확인용 실행 인자 `--debug-panel`: 시작 직후 메뉴를 연다. `BOLT_DEBUG_HOVER=<symbol>`: 그 버튼을 호버 상태로 그린다.
- 깊은 절전 중인 마우스는 시작 시 핑에 답하지 않아 목록에 없다. 장치가 하나도 없는 동안은 30초마다 다시 찾는다.
- 파일 오류는 모두 로그만 남기고 삼킨다. 깨진 줄은 건너뛴다.

**구조**: `BatteryHistory` 라이브러리 타겟(순수 로직, 테스트 6개) + 앱의 `BatteryModel`이 기록·차트 데이터·지우기를 담당.

## 추가 기능. 메뉴바 마우스 아이콘 (2026-10-06)

`MouseIcon`이 메뉴바 아이콘을 렌더링한다. 디자인·색상·성능·검증 원칙은 [PHILOSOPHY.md](PHILOSOPHY.md)에서 관리한다.
