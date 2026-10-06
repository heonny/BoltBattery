import Foundation
import IOKit.hid

/// HID 입력/출력 리포트를 주고받는 바이트 채널. HID++ 프레임 형식은 모른다.
/// 실제 장치는 `IOHIDReportChannel`, 테스트는 바이트 픽스처를 돌려주는 가짜 구현을 쓴다.
public protocol HIDReportChannel: AnyObject, Sendable {
    /// 입력 리포트 콜백을 등록하고 수신을 시작한다. 한 번만 호출한다.
    func start(onReport: @escaping @Sendable ([UInt8]) -> Void) throws
    func write(_ report: [UInt8]) throws
}

/// IOKit `IOHIDDevice` 위의 채널. 콜백은 전용 디스패치 큐에서 실행되어 메인 스레드를 쓰지 않는다.
public final class IOHIDReportChannel: HIDReportChannel, @unchecked Sendable {
    public static let logitechVendorID = 0x046D
    public static let boltProductID = 0xC548
    public static let unifyingProductID = 0xC52B
    /// HID++는 리시버의 벤더 usage page 인터페이스로 오간다 (ioreg 실측: report ID 0x10/0x11, 출력 20바이트).
    static let hidppUsagePage = 0xFF00

    public let productID: Int
    public let productName: String
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "bolt-battery.hid")
    private var started = false

    /// 연결된 Bolt/Unifying 리시버의 벤더 인터페이스를 모두 찾는다. 장치를 열지는 않는다.
    public static func discoverReceivers() -> [IOHIDReportChannel] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [boltProductID, unifyingProductID].map { pid -> [String: Any] in
            [kIOHIDVendorIDKey: logitechVendorID, kIOHIDProductIDKey: pid, kIOHIDPrimaryUsagePageKey: hidppUsagePage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        guard let set = IOHIDManagerCopyDevices(manager) else { return [] }
        return (set as NSSet).allObjects.map { IOHIDReportChannel(device: $0 as! IOHIDDevice) }
    }

    init(device: IOHIDDevice) {
        self.device = device
        productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    }

    deinit {
        // 취소 핸들러가 닫기와 sink 해제를 맡는다. 활성화 전에 Cancel을 부르면 안 된다.
        if started { IOHIDDeviceCancel(device) }
    }

    public func start(onReport: @escaping @Sendable ([UInt8]) -> Void) throws {
        precondition(!started, "IOHIDReportChannel.start may only be called once")
        // CLAUDE.md 제약: 항상 kIOHIDOptionsTypeNone. 독점 모드면 Options+가 장치를 잃는다.
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else { throw HIDPPError.ioError(rc) }

        let maxInput = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let sink = ReportSink(device: device, bufferSize: max(maxInput, HIDPP.longReportSize), onReport: onReport)
        IOHIDDeviceRegisterInputReportCallback(device, sink.buffer, sink.bufferSize, ReportSink.callback, sink.retainedContext())
        IOHIDDeviceSetCancelHandler(device) { sink.closeAndRelease() }
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
        started = true
    }

    public func write(_ report: [UInt8]) throws {
        let rc = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        guard rc == kIOReturnSuccess else { throw HIDPPError.ioError(rc) }
    }
}

/// IOKit 콜백 컨텍스트. IOKit은 Cancel 핸들러가 실행될 때까지 콜백을 부를 수 있으므로
/// 채널 객체와 수명을 분리해 Cancel 완료 시점에 해제한다.
private final class ReportSink: @unchecked Sendable {
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let bufferSize: Int
    let onReport: @Sendable ([UInt8]) -> Void

    init(device: IOHIDDevice, bufferSize: Int, onReport: @escaping @Sendable ([UInt8]) -> Void) {
        self.device = device
        self.bufferSize = bufferSize
        self.onReport = onReport
        buffer = .allocate(capacity: bufferSize)
    }

    deinit { buffer.deallocate() }

    func retainedContext() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }

    func closeAndRelease() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        Unmanaged.passUnretained(self).release()
    }

    static let callback: IOHIDReportCallback = { context, result, _, _, _, report, length in
        guard result == kIOReturnSuccess, let context else { return }
        let sink = Unmanaged<ReportSink>.fromOpaque(context).takeUnretainedValue()
        sink.onReport(Array(UnsafeBufferPointer(start: report, count: length)))
    }
}
