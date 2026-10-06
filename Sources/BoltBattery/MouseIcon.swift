import AppKit
import HIDPPKit

/// 작은 메뉴바에서는 잔량을 숫자에 맡기고 마우스의 실루엣을 일정하게 유지한다.
enum MouseIcon {
    static let size = NSSize(width: 14, height: 16)

    /// 실제 크기와 확대본을 함께 확인해야 메뉴바에서 사라지는 디테일을 잡을 수 있다.
    static func dumpPreviewIfRequested() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["BOLT_DEBUG_ICON"] else { return }
        var states: [DeviceStatus?] = [nil] + [(0, false), (9, false), (10, false), (29, false), (30, false), (85, false), (99, false), (100, false), (60, true)].map {
            DeviceStatus(receiverID: 0, slot: 2, name: "", battery: BatteryReading(percent: $0.0, isCharging: $0.1, isApproximate: false),
                         lastUpdated: nil, isReachable: true)
        }
        states.append(DeviceStatus(receiverID: 0, slot: 2, name: "", battery: BatteryReading(percent: 85, isCharging: false, isApproximate: false),
                                   lastUpdated: nil, isReachable: false))
        let labels = ["None", "0%", "9%", "10%", "29%", "30%", "85%", "99%", "100%", "Charging", "Sleeping"]
        let cellWidth: CGFloat = 88
        let rowHeight: CGFloat = 112
        let sheet = NSImage(size: NSSize(width: cellWidth * CGFloat(states.count), height: rowHeight * 4))
        sheet.lockFocus()
        for row in 0..<4 {
            let dark = row % 2 == 1
            let scale: CGFloat = row >= 2 ? 4 : 1
            let foreground: NSColor = dark ? .white : .black
            NSColor(white: dark ? 0.12 : 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: CGFloat(row) * rowHeight, width: sheet.size.width, height: rowHeight).fill()
            for (index, state) in states.enumerated() {
                let icon = image(for: state)
                let tinted = icon.isTemplate ? icon.tinted(foreground) : icon
                let origin = NSPoint(x: CGFloat(index) * cellWidth, y: CGFloat(row) * rowHeight)
                tinted.draw(in: NSRect(x: origin.x + (cellWidth - size.width * scale) / 2,
                                      y: origin.y + 32, width: size.width * scale, height: size.height * scale))
                (labels[index] as NSString).draw(at: NSPoint(x: origin.x + 12, y: origin.y + 10),
                                               withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: foreground])
            }
        }
        sheet.unlockFocus()
        do {
            guard let tiff = sheet.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
            try png.write(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            exit(1)
        }
        #endif
    }

    /// 기본색은 템플릿으로 남겨 밝은 메뉴바에서도 대비를 유지한다.
    static func image(for device: DeviceStatus?) -> NSImage {
        let battery = device?.battery
        let color: NSColor? = switch battery {
        case let b? where b.isCharging: .systemGreen
        case let b? where b.percent < 10: .systemRed
        case let b? where b.percent < 30: .systemYellow
        default: nil
        }
        let dimmed = device == nil || device?.isReachable == false
        let image = NSImage(size: size, flipped: true) { rect in
            draw(in: rect, color: color ?? .black, dimmed: dimmed)
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "마우스 배터리"
        return image
    }

    private static func outline(in rect: NSRect) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x, y: rect.minY + y)
        }
        let body = NSBezierPath()
        body.move(to: point(5.2, 0.75))
        body.line(to: point(8.8, 0.75))
        body.curve(to: point(12.0, 4.0), controlPoint1: point(11.0, 0.75), controlPoint2: point(12.0, 2.0))
        body.line(to: point(12.4, 9.5))
        body.curve(to: point(7.0, 15.25), controlPoint1: point(12.6, 13.3), controlPoint2: point(10.6, 15.25))
        body.curve(to: point(1.6, 9.5), controlPoint1: point(3.4, 15.25), controlPoint2: point(1.4, 13.3))
        body.line(to: point(2.0, 4.0))
        body.curve(to: point(5.2, 0.75), controlPoint1: point(2.0, 2.0), controlPoint2: point(3.0, 0.75))
        body.close()
        return body
    }

    private static func draw(in rect: NSRect, color: NSColor, dimmed: Bool) {
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setAlpha(dimmed ? 0.5 : 1)
        context?.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context?.endTransparencyLayer()
            context?.restoreGState()
        }
        color.setFill()
        outline(in: rect).fill()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(roundedRect: NSRect(x: rect.midX - 0.75, y: rect.minY + 3.0, width: 1.5, height: 3.5),
                     xRadius: 0.75, yRadius: 0.75).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension NSImage {
    /// 미리보기에서도 휠 홈의 투명 영역을 보존한다.
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}
