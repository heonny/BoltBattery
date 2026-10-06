import AppKit
import IOKit.hid
import os

/// UI에 보여줄 리시버 쪽 상태. 장치가 없는 것과 열지 못한 것을 구분한다.
public enum ReceiverState: Sendable, Equatable {
    case noReceiver
    /// Phase 0 실측으로는 벤더 인터페이스에 입력 모니터링 권한이 필요 없었지만, 거부(kIOReturnNotPermitted)로 실패하면 그 안내를 띄운다.
    case openFailed(reason: String, needsInputMonitoring: Bool)
    case ready(count: Int)
}

/// 리시버 탈착과 잠자기 복귀를 감지해, 현재 열려 있는 `Receiver` 목록을 바뀔 때마다 스트림으로 내보낸다.
/// IOKit 콜백은 전용 큐에서 실행되며 모든 상태 변경은 그 큐에서만 일어난다.
public final class ReceiverMonitor: @unchecked Sendable {
    public let receivers: AsyncStream<[Receiver]>
    public let state: AsyncStream<ReceiverState>

    private let continuation: AsyncStream<[Receiver]>.Continuation
    private let stateContinuation: AsyncStream<ReceiverState>.Continuation
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "bolt-battery.hotplug")
    private let context: CallbackContext
    private var open: [UInt64: (device: IOHIDDevice, receiver: Receiver)] = [:]
    /// 매칭됐지만 열지 못한 리시버. `retry()`가 다시 시도한다.
    private var failed: [UInt64: (device: IOHIDDevice, state: ReceiverState)] = [:]
    private var wakeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "bolt-battery", category: "hotplug")

    public init() {
        (receivers, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (state, stateContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        context = CallbackContext()
        context.monitor = self

        IOHIDManagerSetDeviceMatchingMultiple(manager, IOHIDReportChannel.receiverMatching as CFArray)
        let rawContext = context.retainedPointer()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            CallbackContext.monitor(from: ctx)?.add(device)
        }, rawContext)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            CallbackContext.monitor(from: ctx)?.remove(device)
        }, rawContext)
        let context = context
        IOHIDManagerSetCancelHandler(manager) { context.release() }
        IOHIDManagerSetDispatchQueue(manager, queue)
        // IOHIDManagerOpen은 부르지 않는다. 매칭/제거 콜백에는 필요 없고, 장치는 채널이 개별로 연다.
        IOHIDManagerActivate(manager)

        // mx-battery가 실제로 겪은 버그: 잠자기 후 기존 IOHID 핸들이 응답하지 않을 수 있어 깨어나면 전부 다시 연다.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.reopenAll() }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        continuation.finish()
        stateContinuation.finish()
        IOHIDManagerCancel(manager)
    }

    /// 열지 못했던 리시버를 다시 연다. 권한을 허용한 뒤 사용자가 누르는 용도.
    public func retry() {
        queue.async {
            let pending = self.failed
            self.failed.removeAll()
            pending.values.forEach { self.add($0.device) }
            if pending.isEmpty { self.publish() }
        }
    }

    private func add(_ device: IOHIDDevice) {
        let key = IOHIDReportChannel.registryID(of: device)
        do {
            let receiver = try openReceiver(for: device)
            open[key] = (device, receiver)
            failed[key] = nil
            log.info("receiver attached: \(receiver.productName, privacy: .public) \(String(receiver.productID, radix: 16), privacy: .public)")
        } catch {
            failed[key] = (device, Self.openFailedState(for: error))
            log.error("receiver open failed: \(String(describing: error), privacy: .public)")
        }
        publish()
    }

    static func openFailedState(for error: Error) -> ReceiverState {
        if case HIDPPError.ioError(let rc) = error {
            return .openFailed(reason: "IOKit 0x\(String(UInt32(bitPattern: rc), radix: 16))", needsInputMonitoring: rc == kIOReturnNotPermitted)
        }
        return .openFailed(reason: String(describing: error), needsInputMonitoring: false)
    }

    private func openReceiver(for device: IOHIDDevice) throws -> Receiver {
        // 매니저가 넘겨주는 장치는 이미 매니저 큐에 활성화돼 있어 콜백을 다시 등록하면 IOKit이 트랩을 건다.
        // 같은 io_service로 독립된 IOHIDDevice를 만들어 채널이 자기 큐에서 열게 한다.
        guard let own = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(device)) else {
            throw HIDPPError.ioError(kIOReturnNoDevice)
        }
        return try Receiver(channel: IOHIDReportChannel(device: own))
    }

    private func remove(_ device: IOHIDDevice) {
        // 제거 콜백 시점엔 io_service가 이미 죽어 registryID를 못 구할 수 있어 매니저 객체 동일성으로 찾는다.
        if let key = open.first(where: { CFEqual($0.value.device, device) })?.key {
            open[key] = nil
            log.info("receiver detached")
        } else if let key = failed.first(where: { CFEqual($0.value.device, device) })?.key {
            failed[key] = nil
        } else {
            return
        }
        publish()
    }

    /// 다시 열지 못한 리시버는 기존 핸들을 그대로 둔다. 핸들이 죽었더라도 다음 깨어남이나 재연결에서 다시 시도된다.
    /// 열기에 실패했던 리시버도 이때 다시 시도한다.
    private func reopenAll() {
        queue.async {
            self.log.info("system woke, reopening \(self.open.count) receiver(s)")
            for (key, entry) in self.open {
                do {
                    self.open[key] = (entry.device, try self.openReceiver(for: entry.device))
                } catch {
                    self.log.error("keeping previous handle for receiver \(key): \(String(describing: error), privacy: .public)")
                }
            }
            let pending = self.failed
            self.failed.removeAll()
            pending.values.forEach { self.add($0.device) }
            self.publish()
        }
    }

    private func publish() {
        continuation.yield(open.sorted { $0.key < $1.key }.map(\.value.receiver))
        if let failure = failed.values.first?.state {
            stateContinuation.yield(failure)
        } else {
            stateContinuation.yield(open.isEmpty ? .noReceiver : .ready(count: open.count))
        }
    }

    /// IOKit 콜백 컨텍스트. 모니터를 약하게 참조하고, 매니저 Cancel 핸들러가 실행될 때 해제된다.
    private final class CallbackContext: @unchecked Sendable {
        weak var monitor: ReceiverMonitor?

        func retainedPointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        func release() { Unmanaged.passUnretained(self).release() }

        static func monitor(from pointer: UnsafeMutableRawPointer?) -> ReceiverMonitor? {
            pointer.flatMap { Unmanaged<CallbackContext>.fromOpaque($0).takeUnretainedValue().monitor }
        }
    }
}
