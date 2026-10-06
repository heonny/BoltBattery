import AppKit
import IOKit.hid
import os

/// 리시버 탈착과 잠자기 복귀를 감지해, 현재 열려 있는 `Receiver` 목록을 바뀔 때마다 스트림으로 내보낸다.
/// IOKit 콜백은 전용 큐에서 실행되며 모든 상태 변경은 그 큐에서만 일어난다.
public final class ReceiverMonitor: @unchecked Sendable {
    public let receivers: AsyncStream<[Receiver]>

    private let continuation: AsyncStream<[Receiver]>.Continuation
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "bolt-battery.hotplug")
    private let context: CallbackContext
    private var open: [UInt64: (device: IOHIDDevice, receiver: Receiver)] = [:]
    private var wakeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "bolt-battery", category: "hotplug")

    public init() {
        (receivers, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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
        IOHIDManagerCancel(manager)
    }

    private func add(_ device: IOHIDDevice) {
        guard let receiver = openReceiver(for: device) else { return }
        open[receiver.id] = (device, receiver)
        log.info("receiver attached: \(receiver.productName, privacy: .public) \(String(receiver.productID, radix: 16), privacy: .public)")
        publish()
    }

    private func openReceiver(for device: IOHIDDevice) -> Receiver? {
        // 매니저가 넘겨주는 장치는 이미 매니저 큐에 활성화돼 있어 콜백을 다시 등록하면 IOKit이 트랩을 건다.
        // 같은 io_service로 독립된 IOHIDDevice를 만들어 채널이 자기 큐에서 열게 한다.
        guard let own = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(device)) else {
            log.error("IOHIDDeviceCreate failed for matched receiver")
            return nil
        }
        do {
            return try Receiver(channel: IOHIDReportChannel(device: own))
        } catch {
            log.error("receiver open failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func remove(_ device: IOHIDDevice) {
        // 제거 콜백 시점엔 io_service가 이미 죽어 registryID를 못 구할 수 있어 매니저 객체 동일성으로 찾는다.
        guard let key = open.first(where: { CFEqual($0.value.device, device) })?.key else { return }
        open[key] = nil
        log.info("receiver detached")
        publish()
    }

    /// 다시 열지 못한 리시버는 기존 핸들을 그대로 둔다. 핸들이 죽었더라도 다음 깨어남이나 재연결에서 다시 시도된다.
    private func reopenAll() {
        queue.async {
            self.log.info("system woke, reopening \(self.open.count) receiver(s)")
            for (key, entry) in self.open {
                if let receiver = self.openReceiver(for: entry.device) {
                    self.open[key] = (entry.device, receiver)
                } else {
                    self.log.error("keeping previous handle for receiver \(key)")
                }
            }
            self.publish()
        }
    }

    private func publish() {
        continuation.yield(open.sorted { $0.key < $1.key }.map(\.value.receiver))
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
