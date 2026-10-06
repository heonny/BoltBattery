# CLAUDE.md

## 프로젝트
Bolt 리시버 연결 Logitech 마우스 배터리를 메뉴바에 표시하는 macOS 앱. 전체 계획은 `docs/PLAN.md` 참고. Phase 단위로 진행.

제품·디자인 작업 전에는 `docs/PHILOSOPHY.md`를 읽는다. 합의된 원칙이나 상태 규칙을 바꾸면 같은 작업에서 해당 문서를 갱신하며, 별도 컨셉 문서에 중복 관리하지 않는다.

## 반드시 지킬 제약
- HID 장치는 항상 `kIOHIDOptionsTypeNone`(일반 모드)으로 연다. 독점 모드 금지. Options+와 공존해야 함.
- 읽기 전용. 마우스 설정을 바꾸는 HID++ 요청(쓰기, 버튼 diversion 등)은 절대 보내지 않는다.
- 서드파티 의존성 없음. Swift + SwiftUI + IOKit만 사용.
- HID++ 함수 번호·바이트 오프셋은 추측하지 말고 Solaar 소스로 확인한 뒤 주석에 근거를 남긴다.
- HID 호출은 메인 스레드에서 하지 않는다.
- 저전력 우선: 불필요한 타이머·폴링·UI 갱신을 만들지 않는다.
