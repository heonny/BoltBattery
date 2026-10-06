import Foundation
import HIDPPKit

@main
struct BatteryCtl {
    static func main() async {
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

    static func describe(_ battery: BatteryReading?) -> String {
        guard let battery else { return "no battery feature" }
        return "\(battery.isApproximate ? "~" : "")\(battery.percent)%\(battery.isCharging ? " charging" : "")"
    }
}
