import BatteryHistory
import Foundation

struct ChartSegment: Identifiable {
    let id: Date
    var points: [ChartPoint]

    @MainActor
    static func split(_ points: [ChartPoint], range: HistoryRange) -> [ChartSegment] {
        var segments: [ChartSegment] = []
        for point in points {
            if let previous = segments.last?.points.last,
               point.time <= HistoryChart.intervalEnd(for: previous.time, range: range) {
                segments[segments.count - 1].points.append(point)
            } else {
                segments.append(ChartSegment(id: point.time, points: [point]))
            }
        }
        return segments
    }
}
