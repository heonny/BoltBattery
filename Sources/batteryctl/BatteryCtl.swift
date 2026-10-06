import Foundation
import HIDPPKit

@main
struct BatteryCtl {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "watch" {
            watch(interval: Double(arguments.dropFirst().first ?? "") ?? 30)
        } else {
            await readOnce()
        }
    }

    static func readOnce() async {
        let receivers: [Receiver]
        do {
            receivers = try Receiver.discover()
        } catch {
            print("receiver open failed: \(error)")
            exit(1)
        }
        guard !receivers.isEmpty else {
            print("No Bolt/Unifying receiver found")
            exit(1)
        }
        for receiver in receivers {
            print("Receiver: \(receiver.productName) PID 0x\(String(receiver.productID, radix: 16))")
            do {
                for device in try await receiver.pairedDevices() {
                    let status: String
                    do { status = describe(try await receiver.battery(slot: device.slot)) } catch { status = "error \(error)" }
                    print("  slot \(device.slot): \(device.name)  HID++ \(device.protocolMajor).\(device.protocolMinor)  \(status)")
                }
            } catch {
                print("  error: \(error)")
            }
        }
    }

    /// Phase 2 검증용: 리시버 탈착·잠자기·마우스 전원 시나리오에서 상태 변화를 시각과 함께 출력한다.
    static func watch(interval: TimeInterval) {
        setlinebuf(stdout)
        let monitor = BatteryMonitor { devices in
            let stamp = Date.now.formatted(date: .omitted, time: .standard)
            if devices.isEmpty { print("\(stamp)  (no devices)") }
            for d in devices {
                let seen = d.lastUpdated?.formatted(date: .omitted, time: .standard) ?? "never"
                print("\(stamp)  \(d.id) \(d.name)  \(describe(d.battery))  \(d.isReachable ? "reachable" : "asleep, last seen \(seen)")")
            }
        }
        let hotplug = ReceiverMonitor()
        Task { await monitor.run(receivers: hotplug.receivers) }
        Task {
            while true {
                try? await Task.sleep(for: .seconds(interval))
                await monitor.refresh()
            }
        }
        print("watching every \(Int(interval))s, ^C to stop")
        // NSWorkspace 깨어남 알림은 메인 런루프가 돌아야 전달된다. 소스가 없으면 run()이 즉시 반환하므로 포트를 하나 붙인다.
        RunLoop.main.add(NSMachPort(), forMode: .default)
        RunLoop.main.run()
    }

    static func describe(_ battery: BatteryReading?) -> String {
        guard let battery else { return "no battery feature" }
        return "\(battery.isApproximate ? "~" : "")\(battery.percent)%\(battery.isCharging ? " charging" : "")"
    }
}
