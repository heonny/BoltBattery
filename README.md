# Bolt Battery

Logi Bolt 리시버로 연결된 Logitech 마우스의 배터리를 macOS 메뉴바에 표시하는 앱.
Options+ 설치 여부와 무관하게 동작하고, 설치돼 있어도 공존한다. 마우스 설정은 읽기만 한다.

개인용이라 서명·공증 없이 로컬에서 빌드해서 쓴다. macOS 13 이상, Xcode(Swift 6) 필요.

## 빌드와 설치

```sh
scripts/release.sh
cp -R .build/BoltBattery.app /Applications/
open /Applications/BoltBattery.app
```

ad-hoc 서명이라 이 Mac에서만 열린다. 다른 Mac에서 쓰려면 그 Mac에서 다시 빌드한다.
메뉴의 "로그인 시 실행"은 `/Applications`에 복사한 뒤에 켠다.

배터리 추이는 10분마다 `~/Library/Application Support/BoltBattery/history.csv`에 숫자만 적재되고 6개월 뒤 잘린다.
팝오버의 "기록 지우기"로 비울 수 있다.

## 개발

```sh
swift test                      # 단위 테스트
swift run batteryctl            # 연결된 장치와 배터리 한 번 출력
swift run batteryctl watch 5    # 상태 변화 추적
swift run batteryctl sniff      # 앱이 받는 HID++ 알림 출력
scripts/make-app.sh debug && open .build/BoltBattery.app
```

제품·디자인 원칙은 [PHILOSOPHY.md](docs/PHILOSOPHY.md), 구현 계획은 [PLAN.md](docs/PLAN.md), 개발 제약은 [CLAUDE.md](CLAUDE.md)에서 관리한다.
