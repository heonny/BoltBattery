import Foundation
import Testing
@testable import BatteryHistory

func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("bolt-battery-test-\(UUID().uuidString)/history.csv")
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func recordsAppendAndReloadInOrder() async throws {
    let url = tempFile()
    let history = BatteryHistory(fileURL: url)
    #expect(await history.record(BatterySample(time: t0, slot: 2, percent: 90, isCharging: false)))
    #expect(await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: true)))
    // 같은 슬롯의 같은 시각은 다시 기록하지 않는다(폴링마다 같은 읽기값이 반복됨).
    #expect(await history.record(BatterySample(time: t0 + 600, slot: 2, percent: 85, isCharging: true)) == false)
    #expect(await history.record(BatterySample(time: t0 + 300, slot: 1, percent: 50, isCharging: false)))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "1700000000,2,90,0\n1700000600,2,85,1\n1700000300,1,50,0\n")

    let reloaded = BatteryHistory(fileURL: url)
    await reloaded.load(now: t0 + 1_000)
    #expect(await reloaded.samples.map(\.percent) == [90, 50, 85])
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
    #expect(try String(contentsOf: url, encoding: .utf8) == "1700000000,2,90,0\n")

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

@Test func pointsBucketAverageAndFlagCharging() {
    let samples = [
        BatterySample(time: t0, slot: 2, percent: 90, isCharging: false),
        BatterySample(time: t0 + 600, slot: 2, percent: 80, isCharging: true),
        BatterySample(time: t0 + 3_600, slot: 2, percent: 70, isCharging: false),
        BatterySample(time: t0 + 3_600, slot: 1, percent: 10, isCharging: false),
        BatterySample(time: t0 - 8 * 86_400, slot: 2, percent: 5, isCharging: false),
    ]
    let now = t0 + 7_200
    let raw = BatteryHistory.points(samples, slot: 2, range: .day, now: now)
    #expect(raw.map(\.percent) == [90, 80, 70])

    let hourly = BatteryHistory.points(samples, slot: 2, range: .week, now: now)
    #expect(hourly.map(\.percent) == [85, 70])
    #expect(hourly.map(\.isCharging) == [true, false])
    #expect(hourly[0].time == Date(timeIntervalSince1970: floor(t0.timeIntervalSince1970 / 3_600) * 3_600))

    // 8일 전 샘플도 12주 범위에 들어와 일 단위 버킷이 둘이다. 슬롯을 지정하지 않으면 두 슬롯이 합쳐진다.
    let quarter = BatteryHistory.points(samples, slot: nil, range: .quarter, now: now)
    #expect(quarter.map(\.percent) == [5, 62.5])
}

@Test func dailyBucketsCutAtLocalMidnight() {
    var seoul = Calendar(identifier: .gregorian)
    seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
    // 2023-11-15 07:13 KST (= 14일 22:13 UTC)와 같은 날 10:13 KST. UTC 기준이면 다른 날, 서울 기준이면 같은 날.
    let morning = Date(timeIntervalSince1970: 1_700_000_000)
    let later = morning.addingTimeInterval(3 * 3_600)
    let samples = [
        BatterySample(time: morning, slot: 2, percent: 80, isCharging: false),
        BatterySample(time: later, slot: 2, percent: 60, isCharging: false),
    ]
    let points = BatteryHistory.points(samples, slot: 2, range: .quarter, now: later, calendar: seoul)
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
