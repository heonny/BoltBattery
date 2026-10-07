import BatteryHistory
import Foundation
import Combine
import Testing
@testable import BoltBattery

@MainActor
private func hoverPoints() -> [ChartPoint] {
    BatteryHistory.points([
        BatterySample(time: Date(timeIntervalSince1970: 600), slot: 1, percent: 80, isCharging: false),
        BatterySample(time: Date(timeIntervalSince1970: 1200), slot: 1, percent: 85, isCharging: true),
    ], slot: 1, range: .day, now: Date(timeIntervalSince1970: 1200))
}

@Test @MainActor func hoverSelectsNearestRecordedPointOnly() {
    let points = hoverPoints()
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 599), in: points) == nil)
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 1201), in: points) == nil)
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 900), in: points) == points[0])
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 1190), in: points) == points[1])
    #expect(ChartHoverSelection.nearest(to: Date(), in: []) == nil)
}

@Test @MainActor func hoverUpdatesImmediatelyWithoutPublishingDuplicateSelections() {
    let points = hoverPoints()
    let selection = ChartHoverSelection()
    var updates = 0
    let subscription = selection.objectWillChange.sink { updates += 1 }
    defer { withExtendedLifetime(subscription) {} }
    selection.update(points[0])
    #expect(selection.selected == points[0])
    for _ in 0..<10_000 { selection.update(points[0]) }
    #expect(updates == 1)
    selection.update(points[1])
    #expect(selection.selected == points[1])
    #expect(updates == 2)
    selection.update(nil)
    for _ in 0..<10_000 { selection.update(nil) }
    #expect(selection.selected == nil)
    #expect(updates == 3)
}

@Test @MainActor func hoverDoesNotInventReadingsDuringAnOvernightGap() {
    let points = BatteryHistory.points([
        BatterySample(time: Date(timeIntervalSince1970: 600), slot: 1, percent: 80, isCharging: false),
        BatterySample(time: Date(timeIntervalSince1970: 36_600), slot: 1, percent: 76, isCharging: false),
    ], slot: 1, range: .day, now: Date(timeIntervalSince1970: 36_600))
    for time in [601.0, 18_000, 36_599] {
        #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: time), in: points) == nil)
    }
    #expect(ChartHoverSelection.nearest(to: points[0].time, in: points) == points[0])
    #expect(ChartHoverSelection.nearest(to: points[1].time, in: points) == points[1])
}

@Test @MainActor func chartSplitsAtMissingRecordingIntervals() {
    let points = BatteryHistory.points([600.0, 1200, 36_600, 37_200, 39_000].map {
        BatterySample(time: Date(timeIntervalSince1970: $0), slot: 1, percent: 80, isCharging: false)
    }, slot: 1, range: .day, now: Date(timeIntervalSince1970: 39_000))
    let segments = ChartSegment.split(points, range: .day)
    #expect(segments.map { $0.points.map(\.time.timeIntervalSince1970) } == [
        [600, 1200], [36_600, 37_200], [39_000],
    ])
    #expect(ChartSegment.split([], range: .day).isEmpty)
    #expect(ChartSegment.split([points[0]], range: .day).first?.points == [points[0]])
}

@Test @MainActor func aggregatedChartsKeepAdjacentBucketsAndBreakAtMissingBuckets() {
    for range in [HistoryRange.week, .quarter] {
        let unit: Calendar.Component = range == .week ? .hour : .day
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dates = [0, 1, 3].map { calendar.date(byAdding: unit, value: $0, to: start)! }
        let samples = dates.map { BatterySample(time: $0, slot: 1, percent: 80, isCharging: false) }
        let points = BatteryHistory.points(samples, slot: 1, range: range, now: dates[2])
        #expect(ChartSegment.split(points, range: range).map { $0.points.count } == [2, 1])
        let connected = dates[0].addingTimeInterval(dates[1].timeIntervalSince(dates[0]) / 2)
        let missing = dates[1].addingTimeInterval(dates[2].timeIntervalSince(dates[1]) / 2)
        #expect(ChartHoverSelection.nearest(to: connected, in: points, range: range) != nil)
        #expect(ChartHoverSelection.nearest(to: missing, in: points, range: range) == nil)
    }
}

@Test @MainActor func hoverDistinguishesMissingRecordsFromLeavingTheChart() {
    let selection = ChartHoverSelection()
    let point = hoverPoints()[0]
    let missing = Date(timeIntervalSince1970: 18_000)
    selection.update(point)
    selection.update(nil, missingDate: missing)
    #expect(selection.selected == nil)
    #expect(selection.hoverDate == missing)
    selection.update(point)
    #expect(selection.missingDate == nil)
    #expect(selection.hoverDate == point.time)
    selection.update(nil, missingDate: missing)
    selection.update(nil)
    #expect(selection.hoverDate == nil)
}
