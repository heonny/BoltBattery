import BatteryHistory
import Charts
import SwiftUI

@MainActor
final class ChartHoverSelection: ObservableObject {
    @Published private(set) var selected: ChartPoint?
    @Published private(set) var missingDate: Date?
    var hoverDate: Date? { selected?.time ?? missingDate }

    func update(_ point: ChartPoint?, missingDate: Date? = nil) {
        if self.missingDate != missingDate { self.missingDate = missingDate }
        guard point != selected else { return }
        selected = point
    }

    static func nearest(to date: Date, in points: [ChartPoint], range: HistoryRange = .day) -> ChartPoint? {
        guard let first = points.first, let last = points.last,
              (first.time...last.time).contains(date) else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].time < date { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return first }
        let before = points[lower - 1]
        let after = points[lower]
        if date == after.time { return after }
        guard after.time <= HistoryChart.intervalEnd(for: before.time, range: range) else { return nil }
        return date.timeIntervalSince(before.time) <= after.time.timeIntervalSince(date) ? before : after
    }
}

struct ChartHoverOverlay: View {
    let proxy: ChartProxy
    let points: [ChartPoint]
    let range: HistoryRange
    @StateObject private var selection = ChartHoverSelection()

    var body: some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                HoverTrackingView(plotFrame: plot) { location in
                    guard let location, plot.contains(location),
                          let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else {
                        selection.update(nil)
                        return
                    }
                    let point = ChartHoverSelection.nearest(to: date, in: points, range: range)
                    selection.update(point, missingDate: point == nil ? date : nil)
                }
                if let date = selection.hoverDate, let x = proxy.position(forX: date) {
                    Path { path in
                        path.move(to: CGPoint(x: plot.minX + x, y: plot.minY))
                        path.addLine(to: CGPoint(x: plot.minX + x, y: plot.maxY))
                    }
                    .stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .allowsHitTesting(false)
                    if let point = selection.selected, let y = proxy.position(forY: point.percent) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                            .position(x: plot.minX + x, y: plot.minY + y)
                            .allowsHitTesting(false)
                    }
                    let pointX = plot.minX + x
                    let preferredX = pointX > plot.midX ? pointX - 144 : pointX + 12
                    ChartTooltip(point: selection.selected, date: date, range: range)
                        .offset(x: min(max(preferredX, plot.minX + 6), max(plot.minX + 6, plot.maxX - 138)),
                                y: plot.minY + 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: points) { _ in selection.update(nil) }
        .onChange(of: range) { _ in selection.update(nil) }
        .onDisappear { selection.update(nil) }
    }
}

private struct ChartTooltip: View {
    let point: ChartPoint?
    let date: Date
    let range: HistoryRange

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                Text(HistoryChart.axisLabel(for: date, range: .day) +
                     (point != nil && range == .day ? "–" + HistoryChart.axisLabel(for: date.addingTimeInterval(540), range: .day) : ""))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)

            if let point {
                reading(point)
            } else {
                Text("기록 없음")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }

    @ViewBuilder
    private func reading(_ point: ChartPoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(point.percent.formatted(.number.precision(.fractionLength(0...1))))
                .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
            Text("%")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if range != .day {
                Text("평균").font(.caption2).foregroundStyle(.secondary)
            }
        }
        if point.isCharging {
            Label("충전 기록 있음", systemImage: "bolt.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.green)
        }
    }
}

private struct HoverTrackingView: NSViewRepresentable {
    let plotFrame: CGRect
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) {
        view.plotFrame = plotFrame
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: (CGPoint?) -> Void = { _ in }
        var plotFrame: CGRect = .zero
        private var lastX: CGFloat?
        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            guard plotFrame.contains(location) else {
                mouseExited(with: event)
                return
            }
            guard location.x != lastX else { return }
            lastX = location.x
            onMove(location)
        }
        override func mouseExited(with event: NSEvent) {
            guard lastX != nil else { return }
            lastX = nil
            onMove(nil)
        }
    }
}
