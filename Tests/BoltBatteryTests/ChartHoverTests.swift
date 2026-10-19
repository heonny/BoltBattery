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
    ], slot: 1, range: .hourly, now: Date(timeIntervalSince1970: 1200))
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
    ], slot: 1, range: .hourly, now: Date(timeIntervalSince1970: 36_600))
    for time in [601.0, 18_000, 36_599] {
        #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: time), in: points) == nil)
    }
    #expect(ChartHoverSelection.nearest(to: points[0].time, in: points) == points[0])
    #expect(ChartHoverSelection.nearest(to: points[1].time, in: points) == points[1])
}

@Test @MainActor func chartSplitsAtMissingRecordingIntervals() {
    let points = BatteryHistory.points([600.0, 1200, 36_600, 37_200, 39_000].map {
        BatterySample(time: Date(timeIntervalSince1970: $0), slot: 1, percent: 80, isCharging: false)
    }, slot: 1, range: .hourly, now: Date(timeIntervalSince1970: 39_000))
    let segments = ChartSegment.split(points)
    #expect(segments.map { $0.points.map(\.time.timeIntervalSince1970) } == [
        [600, 1200], [36_600, 37_200], [39_000],
    ])
    #expect(ChartSegment.split([]).isEmpty)
    #expect(ChartSegment.split([points[0]]).first?.points == [points[0]])
}

@Test @MainActor func hourlyChartBridgesOneIntervalSkippedByPollingJitter() {
    let longestPoll = (BatteryModel.pollInterval + BatteryModel.pollTolerance).components.seconds
    #expect(Double(longestPoll) < 2 * BatteryHistory.recordingInterval)
    let points = BatteryHistory.points([600.0, 1800, 2400, 4200].map {
        BatterySample(time: Date(timeIntervalSince1970: $0), slot: 1, percent: 85, isCharging: false)
    }, slot: 1, range: .hourly, now: Date(timeIntervalSince1970: 4200))
    #expect(ChartSegment.split(points).map { $0.points.count } == [3, 1])
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 1200), in: points) == points[0])
    #expect(ChartHoverSelection.nearest(to: Date(timeIntervalSince1970: 3300), in: points) == nil)
}

@Test @MainActor func barHoverSelectsTheBucketUnderTheCursor() {
    for range in [HistoryRange.daily, .weekly] {
        let unit = range.bucket!
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: unit, for: Date(timeIntervalSince1970: 1_700_000_000))!.start
        let dates = [0, 1, 3].map { calendar.date(byAdding: unit, value: $0, to: start)! }
        let samples = dates.map { BatterySample(time: $0, slot: 1, percent: 80, isCharging: false) }
        let points = BatteryHistory.points(samples, slot: 1, range: range, now: dates[2])
        #expect(points.map(\.time) == dates)
        let late = { (date: Date) in HistoryChart.intervalEnd(for: date, range: range).addingTimeInterval(-1) }
        #expect(ChartHoverSelection.nearest(to: late(dates[0]), in: points, range: range) == points[0])
        #expect(ChartHoverSelection.nearest(to: late(dates[1]).addingTimeInterval(2), in: points, range: range) == nil)
        #expect(ChartHoverSelection.nearest(to: late(dates[2]), in: points, range: range) == points[2])
        #expect(ChartHoverSelection.nearest(to: late(dates[2]).addingTimeInterval(2), in: points, range: range) == nil)
        #expect(ChartHoverSelection.nearest(to: dates[0].addingTimeInterval(-1), in: points, range: range) == nil)
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
