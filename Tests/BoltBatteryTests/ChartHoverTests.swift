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
