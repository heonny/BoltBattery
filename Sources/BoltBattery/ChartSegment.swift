import BatteryHistory
import Foundation

struct ChartSegment: Identifiable {
    let id: Date
    var points: [ChartPoint]

    @MainActor
    static func split(_ points: [ChartPoint]) -> [ChartSegment] {
        var segments: [ChartSegment] = []
        for point in points {
            if let previous = segments.last?.points.last,
               HistoryChart.connects(previous.time, point.time) {
                segments[segments.count - 1].points.append(point)
            } else {
                segments.append(ChartSegment(id: point.time, points: [point]))
            }
        }
        return segments
    }
}
