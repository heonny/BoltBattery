import Foundation
import os

public struct DeviceStatus: Equatable, Sendable, Identifiable {
    public let receiverID: UInt64
    public let slot: UInt8
    public var name: String
    /// 마지막으로 읽은 값. `isReachable`이 false면 절전 전 마지막 값이다.
    public var battery: BatteryReading?
    /// `battery`를 마지막으로 성공적으로 읽은 시각.
    public var lastUpdated: Date?
    /// 마지막 조회에서 핑에 응답했는지.
    public var isReachable: Bool

    public var id: String { Self.id(receiverID: receiverID, slot: slot) }

    public init(receiverID: UInt64, slot: UInt8, name: String, battery: BatteryReading?, lastUpdated: Date?, isReachable: Bool) {
        self.receiverID = receiverID
        self.slot = slot
        self.name = name
        self.battery = battery
        self.lastUpdated = lastUpdated
        self.isReachable = isReachable
    }

    static func id(receiverID: UInt64, slot: UInt8) -> String { "\(receiverID):\(slot)" }
}

/// 리시버 목록을 받아 슬롯별 장치 상태를 유지한다.
/// 절전 중인 장치는 에러가 아니라 "마지막 값 + 마지막 확인 시각"으로 남긴다.
///
/// 액터는 await 지점마다 재진입하므로(`run`의 목록 교체와 폴링의 `refresh`가 겹칠 수 있다)
/// `devices` 인덱스를 await 너머로 들고 있지 않고 매번 id로 다시 찾는다.
public actor BatteryMonitor {
    public private(set) var devices: [DeviceStatus] = []
    private var receivers: [Receiver] = []
    private var notificationTasks: [UInt64: Task<Void, Never>] = [:]
    private let onChange: @Sendable ([DeviceStatus]) -> Void
    private let log = Logger(subsystem: "bolt-battery", category: "battery")

    public init(onChange: @escaping @Sendable ([DeviceStatus]) -> Void) {
        self.onChange = onChange
    }

    /// 리시버 목록이 바뀔 때마다 사라진 리시버의 장치를 지우고 전체를 다시 읽는다. 스트림이 끝나면 반환.
    public func run(receivers source: AsyncStream<[Receiver]>) async {
        for await list in source {
            receivers = list
            let ids = Set(list.map(\.id))
            let countBefore = devices.count
            devices.removeAll { !ids.contains($0.receiverID) }
            for (id, task) in notificationTasks where !ids.contains(id) {
                task.cancel()
                notificationTasks[id] = nil
            }
            for receiver in list where notificationTasks[receiver.id] == nil {
                notificationTasks[receiver.id] = Task { [weak self] in
                    for await notification in receiver.notifications {
                        await self?.handle(notification, from: receiver)
                    }
                }
            }
            await refresh(forceNotify: devices.count != countBefore)
        }
    }

    /// 이벤트 우선: 배터리 이벤트는 요청 없이 값만 반영하고, 연결 알림은 폴링을 기다리지 않고 절전/복귀를 바로 반영한다.
    /// 변경 비교 스냅샷은 await 뒤, 변경 직전에 떠야 폴링과 겹쳐도 같은 상태를 두 번 알리지 않는다.
    private func handle(_ notification: HIDPPNotification, from receiver: Receiver) async {
        let slot = notification.deviceIndex
        let key = DeviceStatus.id(receiverID: receiver.id, slot: slot)

        if let linked = notification.linkEstablished {
            if linked {
                // refresh(_:slot:)는 내부에서 알리지 않으므로 여기서 전후를 비교한다.
                let before = Self.withoutTimestamps(devices)
                await refresh(receiver, slot: slot)
                if Self.withoutTimestamps(devices) != before { onChange(devices) }
            } else if let i = index(of: key), devices[i].isReachable {
                devices[i].isReachable = false
                onChange(devices)
            }
            return
        }

        guard !notification.isReceiverNotification, notification.function == 0,
              let feature = await receiver.cachedFeature(slot: slot, index: notification.subID)
        else { return }
        // notifications.py: 배터리 이벤트 페이로드는 get_status 응답과 같은 배열이다.
        let battery: BatteryReading? = switch feature {
        case .unifiedBattery: BatteryReading(unifiedBatteryReply: notification.data)
        case .batteryStatus: BatteryReading(batteryStatusReply: notification.data)
        default: nil
        }
        guard let battery else { return }

        guard let i = index(of: key) else {
            let before = Self.withoutTimestamps(devices)
            await refresh(receiver, slot: slot)
            if Self.withoutTimestamps(devices) != before { onChange(devices) }
            return
        }
        let changed = devices[i].battery != battery || !devices[i].isReachable
        devices[i].battery = battery
        devices[i].lastUpdated = Date()
        devices[i].isReachable = true
        if changed { onChange(devices) }
    }

    /// 모든 리시버의 슬롯 1~6을 핑한다. 빈 슬롯과 절전 슬롯은 리시버가 즉시 에러로 답하므로 비용이 작다.
    public func refresh() async {
        await refresh(forceNotify: false)
    }

    /// `onChange`는 이름·배터리·도달 여부·장치 집합이 바뀐 경우에만 부른다. `lastUpdated`만 바뀐 건 UI를 깨울 일이 아니다.
    private func refresh(forceNotify: Bool) async {
        let before = Self.withoutTimestamps(devices)
        for receiver in receivers {
            for slot in Receiver.slots { await refresh(receiver, slot: slot) }
        }
        if forceNotify || Self.withoutTimestamps(devices) != before { onChange(devices) }
    }

    private static func withoutTimestamps(_ devices: [DeviceStatus]) -> [DeviceStatus] {
        devices.map { var d = $0; d.lastUpdated = nil; return d }
    }

    private func refresh(_ receiver: Receiver, slot: UInt8) async {
        let key = DeviceStatus.id(receiverID: receiver.id, slot: slot)
        let wasReachable = devices.first { $0.id == key }?.isReachable ?? false

        guard await isAwake(receiver, slot: slot) else {
            if let i = index(of: key), devices[i].isReachable {
                devices[i].isReachable = false
                log.info("\(self.devices[i].name, privacy: .public) stopped responding, keeping last value")
            }
            return
        }

        if !wasReachable {
            // 핑이 돌아왔다는 것은 같은 슬롯에 다른 장치가 페어링됐을 수도 있다는 뜻이라 기능 인덱스와 이름을 다시 읽는다.
            await receiver.forgetFeatures(slot: slot)
            let name = await read("name", slot: slot) { try await receiver.deviceName(slot: slot) }
            if let i = index(of: key) {
                // 이름 조회가 실패해도(바로 다시 잠듦) 알고 있던 이름을 지우지 않는다.
                devices[i].name = name ?? devices[i].name
                devices[i].isReachable = true
            } else {
                devices.append(DeviceStatus(receiverID: receiver.id, slot: slot, name: name ?? "slot \(slot)", isReachable: true))
            }
        }

        if let battery = await read("battery", slot: slot, { try await receiver.battery(slot: slot) }), let i = index(of: key) {
            devices[i].battery = battery
            devices[i].lastUpdated = Date()
        }
    }

    private func index(of key: String) -> Int? {
        devices.firstIndex { $0.id == key }
    }

    private func isAwake(_ receiver: Receiver, slot: UInt8) async -> Bool {
        await read("ping", slot: slot) { try await receiver.ping(slot: slot) } != nil
    }

    /// 읽기 실패는 "이번엔 못 읽음"이다. 타임아웃은 절전이라 조용히, 그 외는 로그만 남기고 마지막 값을 유지한다.
    private func read<T>(_ what: String, slot: UInt8, _ body: () async throws -> T?) async -> T? {
        do {
            return try await body()
        } catch HIDPPError.timeout {
            return nil
        } catch {
            log.error("slot \(slot) \(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension DeviceStatus {
    init(receiverID: UInt64, slot: UInt8, name: String, isReachable: Bool) {
        self.init(receiverID: receiverID, slot: slot, name: name, battery: nil, lastUpdated: nil, isReachable: isReachable)
    }
}
