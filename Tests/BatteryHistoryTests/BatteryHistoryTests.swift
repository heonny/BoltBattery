import Foundation
import Testing
@testable import BatteryHistory

func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("bolt-battery-test-\(UUID().uuidString)/history.csv")
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func chartPointsSortAndKeepLatestReadingAtDuplicateTimes() {
    let samples = [
        BatterySample(time: t0 + 10, slot: 2, percent: 85, isCharging: false),
        BatterySample(time: t0, slot: 2, percent: 86, isCharging: false),
        BatterySample(time: t0 + 10, slot: 2, percent: 87, isCharging: true),
    ]
    let points = BatteryHistory.points(samples, slot: 2, range: .hourly, now: t0 + 20)
    #expect(points.map(\.time) == [BatteryHistory.intervalStart(t0)])
    #expect(points.map(\.percent) == [87])
    #expect(points.last?.isCharging == true)
}

@Test func recordsAppendAndReloadInOrder() async throws {
    let url = tempFile()
    let history = BatteryHistory(fileURL: url)
    #expect(await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false)))
    #expect(await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: true)))
    // 같은 슬롯의 같은 시각은 다시 기록하지 않는다(폴링마다 같은 읽기값이 반복됨).
    #expect(await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: true)) == false)
    #expect(await history.record(BatterySample(time: t0 + 300, slot: 1, percent: 50, isCharging: false)))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "1699999800,2,90,0\n1700000400,2,85,1\n1699999800,1,50,0\n")

    let reloaded = BatteryHistory(fileURL: url)
    await reloaded.load(now: t0 + 1_000)
    #expect(await reloaded.samples.map(\.percent) == [50, 90, 85])
}

@Test func corruptLinesAreSkipped() async throws {
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "1700000000,2,90,0\ngarbage\n1700000600,2,150,0\n1700000700,2,80,2\n,,,\n1700000900,2,70,1".write(to: url, atomically: true, encoding: .utf8)
    let history = BatteryHistory(fileURL: url)
    await history.load(now: t0 + 1_000)
    #expect(await history.samples.map(\.percent) == [90, 70])
}

@Test func pruneDropsSamplesOlderThanRetentionAndRewritesFile() async throws {
    let url = tempFile()
    let history = BatteryHistory(fileURL: url)
    let old = t0.addingTimeInterval(-BatteryHistory.retention - 2 * 86_400)
    await history.record(BatterySample(time: old, slot: 2, percent: 10, isCharging: false))
    await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false))
    // 하루 넘게 지난 샘플이 있으므로 record 시점에 다시 쓴다.
    #expect(await history.samples.map(\.percent) == [90])
    #expect(try String(contentsOf: url, encoding: .utf8) == "1699999800,2,90,0\n")

    // 아직 하루가 안 지난 초과분은 10분마다 다시 쓰지 않고 둔다.
    let barely = t0.addingTimeInterval(-BatteryHistory.retention - 3_600)
    let lazy = BatteryHistory(fileURL: tempFile())
    await lazy.record(BatterySample(time: barely, slot: 2, percent: 10, isCharging: false))
    await lazy.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false))
    #expect(await lazy.samples.count == 2)
    // load는 항상 잘라낸다.
    await lazy.load(now: t0)
    #expect(await lazy.samples.map(\.percent) == [90])
}

@Test func clearEmptiesMemoryAndFile() async throws {
    let url = tempFile()
    let history = BatteryHistory(fileURL: url)
    await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false))
    await history.clear()
    #expect(await history.samples.isEmpty)
    #expect(try String(contentsOf: url, encoding: .utf8) == "")
    #expect(await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false)))
}

@Test func unwritableFileDoesNotCrash() async throws {
    let history = BatteryHistory(fileURL: URL(fileURLWithPath: "/dev/null/impossible/history.csv"))
    await history.load()
    #expect(await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false)))
    #expect(await history.samples.count == 1)
    await history.clear()
}

private var seoul: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    calendar.firstWeekday = 1
    return calendar
}

@Test func pointsBucketAverageAndFlagCharging() {
    let samples = [
        BatterySample(time: t0, slot: 2, percent: 90, isCharging: false),
        BatterySample(time: t0 + 600, slot: 2, percent: 80, isCharging: true),
        BatterySample(time: t0 + 3_600, slot: 2, percent: 70, isCharging: false),
        BatterySample(time: t0 + 3_600, slot: 1, percent: 10, isCharging: false),
        BatterySample(time: t0 - 8 * 86_400, slot: 2, percent: 5, isCharging: false),
    ]
    let now = t0 + 7_200
    let raw = BatteryHistory.points(samples, slot: 2, range: .hourly, now: now, calendar: seoul)
    #expect(raw.map(\.percent) == [90, 80, 70])

    let daily = BatteryHistory.points(samples, slot: 2, range: .daily, now: now, calendar: seoul)
    #expect(daily.map(\.percent) == [5, 80])
    #expect(daily.map(\.isCharging) == [false, true])
    #expect(daily[1].time == seoul.startOfDay(for: t0))

    // 슬롯을 지정하지 않으면 두 슬롯이 합쳐진다.
    let weekly = BatteryHistory.points(samples, slot: nil, range: .weekly, now: now, calendar: seoul)
    #expect(weekly.map(\.percent) == [5, 62.5])
    #expect(weekly[1].time == seoul.dateInterval(of: .weekOfYear, for: t0)?.start)
}

@Test func barRangesCoverWholeBucketsWithinRetention() {
    for day in 0..<14 {
        let now = t0 + Double(day) * 86_400
        let daily = HistoryRange.daily.domain(now: now, calendar: seoul)
        #expect(daily.lowerBound == seoul.date(byAdding: .day, value: -29, to: seoul.startOfDay(for: now)))
        #expect(daily.upperBound == seoul.date(byAdding: .day, value: 1, to: seoul.startOfDay(for: now)))
        let weekly = HistoryRange.weekly.domain(now: now, calendar: seoul)
        #expect(seoul.dateComponents([.weekOfYear], from: weekly.lowerBound, to: weekly.upperBound).weekOfYear == 26)
        #expect(weekly.lowerBound >= now.addingTimeInterval(-BatteryHistory.retention))
    }
}

@Test func barAxisTicksAreSparseAndEndAtCurrentBucket() {
    #expect(HistoryRange.hourly.axisTicks(now: t0, calendar: seoul) == nil)
    for range in [HistoryRange.daily, .weekly] {
        let domain = range.domain(now: t0, calendar: seoul)
        let ticks = range.axisTicks(now: t0, calendar: seoul) ?? []
        #expect(ticks.count == 3)
        #expect(ticks.allSatisfy(domain.contains))
        #expect(ticks.last == seoul.dateInterval(of: range.bucket!, for: t0)?.start)
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        #expect(zip(ticks, ticks.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= span / 4 })
    }
}

@Test func dailyBucketsCutAtLocalMidnight() {
    // 2023-11-15 07:13 KST (= 14일 22:13 UTC)와 같은 날 10:13 KST. UTC 기준이면 다른 날, 서울 기준이면 같은 날.
    let morning = Date(timeIntervalSince1970: 1_700_000_000)
    let later = morning.addingTimeInterval(3 * 3_600)
    let samples = [
        BatterySample(time: morning, slot: 2, percent: 80, isCharging: false),
        BatterySample(time: later, slot: 2, percent: 60, isCharging: false),
    ]
    let points = BatteryHistory.points(samples, slot: 2, range: .daily, now: later, calendar: seoul)
    #expect(points.map(\.percent) == [70])
    #expect(points[0].time == seoul.startOfDay(for: morning))
}

@Test func appendAfterUnterminatedLastLineKeepsBothSamples() async throws {
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "1700000000,2,90,0".write(to: url, atomically: true, encoding: .utf8)
    let history = BatteryHistory(fileURL: url)
    await history.load(now: t0 + 1_000)
    await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: false))
    let reloaded = BatteryHistory(fileURL: url)
    await reloaded.load(now: t0 + 1_000)
    #expect(await reloaded.samples.map(\.percent) == [90, 85])
}

@Test func loadDropsSamplesMoreThanADayInTheFuture() async throws {
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "1700000000,2,90,0\n1800000000,2,50,0\n".write(to: url, atomically: true, encoding: .utf8)
    let history = BatteryHistory(fileURL: url)
    await history.load(now: t0 + 1_000)
    #expect(await history.samples.map(\.percent) == [90])
    #expect(await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: false)))
}

@Test func tenMinuteRecordsReplaceAndPreserveChargingAcrossReload() async throws {
    let url = tempFile()
    let history = BatteryHistory(fileURL: url)
    let start = BatteryHistory.intervalStart(t0)
    await history.record(BatterySample(time: start + 1, slot: 2, percent: 80, isCharging: true))
    await history.record(BatterySample(time: start + 599, slot: 2, percent: 85, isCharging: false))
    #expect(await history.samples.count == 1)
    #expect(await history.samples.first?.percent == 85)
    #expect(await history.samples.first?.isCharging == true)
    #expect(await history.record(BatterySample(time: start + 2, slot: 2, percent: 70, isCharging: false)) == false)
    await history.record(BatterySample(time: start + 600, slot: 2, percent: 84, isCharging: false))
    let loaded = BatteryHistory(fileURL: url)
    await loaded.load(now: start + 700)
    #expect(await loaded.samples.map(\.time) == [start, start + 600])
    #expect(await loaded.samples.map(\.percent) == [85, 84])
    #expect(await loaded.samples.map(\.isCharging) == [true, false])
    #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
}

@Test func legacyRecordsCoalesceBeforeAveragingAndOnLoad() async throws {
    let start = BatteryHistory.intervalStart(t0)
    let samples = [
        BatterySample(time: start + 1, slot: 2, percent: 70, isCharging: true),
        BatterySample(time: start + 20, slot: 2, percent: 80, isCharging: false),
        BatterySample(time: start + 600, slot: 2, percent: 90, isCharging: false),
    ]
    let url = tempFile()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try samples.map(BatteryHistory.line).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    let history = BatteryHistory(fileURL: url)
    await history.load(now: start + 700)
    #expect(await history.samples.map(\.percent) == [80, 90])
    #expect(await history.samples.first?.isCharging == true)
    let points = BatteryHistory.points(samples, slot: 2, range: .daily, now: start + 700, calendar: seoul)
    #expect(points.first?.percent == 85)
    #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2)
}

@Test func hourlyChartOnlyIncludesLastTwelveHours() {
    let now = BatteryHistory.intervalStart(t0)
    let samples = [
        BatterySample(time: now - 13 * 3_600, slot: 2, percent: 90, isCharging: false),
        BatterySample(time: now - 12 * 3_600, slot: 2, percent: 85, isCharging: false),
        BatterySample(time: now, slot: 2, percent: 80, isCharging: false),
    ]
    #expect(HistoryRange.hourly.domain(now: now) == now.addingTimeInterval(-12 * 3_600)...now)
    #expect(BatteryHistory.points(samples, slot: 2, range: .hourly, now: now).map(\.percent) == [85, 80])
}
