import Foundation
import os

public struct BatterySample: Equatable, Sendable {
    public let time: Date
    public let slot: UInt8
    public let percent: Int
    public let isCharging: Bool

    public init(time: Date, slot: UInt8, percent: Int, isCharging: Bool) {
        self.time = time
        self.slot = slot
        self.percent = percent
        self.isCharging = isCharging
    }
}

public enum HistoryRange: CaseIterable, Sendable, Identifiable {
    /// 최근 24시간, 원본 값
    case day
    /// 최근 7일, 시간 평균
    case week
    /// 최근 12주, 일 평균
    case quarter

    public var id: Self { self }

    public var window: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .quarter: 84 * 86_400
        }
    }

    /// 묶는 단위. 로컬 달력 기준이라 일 단위는 현지 자정에서 끊기고 서머타임도 맞는다.
    var bucket: Calendar.Component? {
        switch self {
        case .day: nil
        case .week: .hour
        case .quarter: .day
        }
    }
}

public struct ChartPoint: Equatable, Sendable, Identifiable {
    public let time: Date
    public let percent: Double
    /// 묶인 구간 안에 충전 중 샘플이 하나라도 있으면 true
    public let isCharging: Bool

    public var id: Date { time }
}

/// 배터리 기록. 한 줄에 숫자 넷(초 단위 시각, 슬롯, 퍼센트, 충전 여부)만 담는 CSV에 덧붙인다.
/// 파일 오류는 로그만 남기고 삼킨다. 기록은 보조 기능이라 앱을 죽일 이유가 없다.
public actor BatteryHistory {
    public static let retention: TimeInterval = 183 * 86_400

    public private(set) var samples: [BatterySample] = []
    private let fileURL: URL
    private let log = Logger(subsystem: "bolt-battery", category: "history")

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BoltBattery/history.csv")
    }

    /// 파일을 읽어 메모리에 올리고 보존 기간을 넘긴 줄을 잘라낸다. 깨진 줄과 하루 이상 미래인 줄(시계 오설정 흔적)은 건너뛴다.
    public func load(now: Date = Date()) {
        samples = []
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let horizon = now.addingTimeInterval(86_400)
        samples = text.split(separator: "\n").compactMap { Self.parse($0) }.filter { $0.time <= horizon }.sorted { $0.time < $1.time }
        prune(now: now, force: true)
    }

    /// 같은 슬롯에 같은 시각의 샘플이 이미 있으면 기록하지 않는다(폴링마다 같은 읽기값이 다시 오는 경우).
    @discardableResult
    public func record(_ sample: BatterySample) -> Bool {
        if let last = samples.last(where: { $0.slot == sample.slot }), last.time == sample.time { return false }
        samples.append(sample)
        appendLine(Self.line(sample))
        prune(now: sample.time, force: false)
        return true
    }

    /// 파일을 비운다. 비우기에 실패하면 디스크 상태를 다시 읽어 UI가 거짓으로 비어 보이지 않게 한다.
    public func clear() {
        samples = []
        if !write("") {
            try? FileManager.default.removeItem(at: fileURL)
            load()
        }
    }

    /// 보존 기간을 넘긴 샘플을 버리고 파일을 다시 쓴다. `force`가 아니면 하루 이상 넘긴 게 있을 때만 다시 써서 10분마다 전체를 다시 쓰지 않게 한다.
    func prune(now: Date, force: Bool) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        guard let oldest = samples.first?.time, oldest < cutoff else { return }
        guard force || oldest < cutoff.addingTimeInterval(-86_400) else { return }
        samples.removeAll { $0.time < cutoff }
        write(samples.map(Self.line).joined(separator: "\n") + (samples.isEmpty ? "" : "\n"))
    }

    // MARK: 차트용 집계

    /// 범위 안의 샘플을 버킷 평균으로 묶는다. `slot`이 nil이면 모든 슬롯을 합친다.
    public static func points(
        _ samples: [BatterySample], slot: UInt8?, range: HistoryRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [ChartPoint] {
        let start = now.addingTimeInterval(-range.window)
        let inRange = samples.filter { $0.time >= start && (slot == nil || $0.slot == slot) }
        guard let unit = range.bucket else {
            return inRange.map { ChartPoint(time: $0.time, percent: Double($0.percent), isCharging: $0.isCharging) }
        }
        var buckets: [Date: (sum: Int, count: Int, charging: Bool)] = [:]
        for s in inRange {
            guard let key = calendar.dateInterval(of: unit, for: s.time)?.start else { continue }
            let b = buckets[key] ?? (0, 0, false)
            buckets[key] = (b.sum + s.percent, b.count + 1, b.charging || s.isCharging)
        }
        return buckets.keys.sorted().map { key in
            let b = buckets[key]!
            return ChartPoint(time: key, percent: Double(b.sum) / Double(b.count), isCharging: b.charging)
        }
    }

    // MARK: 직렬화

    static func line(_ s: BatterySample) -> String {
        "\(Int(s.time.timeIntervalSince1970)),\(s.slot),\(s.percent),\(s.isCharging ? 1 : 0)"
    }

    static func parse(_ line: Substring) -> BatterySample? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count == 4, let t = Int(f[0]), let slot = UInt8(f[1]), let p = Int(f[2]), let c = Int(f[3]),
              (0...100).contains(p), c == 0 || c == 1
        else { return nil }
        return BatterySample(time: Date(timeIntervalSince1970: Double(t)), slot: slot, percent: p, isCharging: c == 1)
    }

    // MARK: 파일

    /// 직전 쓰기가 중간에 끊겨 줄바꿈 없이 끝났으면 먼저 줄을 닫는다. 안 그러면 두 샘플이 한 줄로 붙어 둘 다 잃는다.
    private func appendLine(_ line: String) {
        do {
            try ensureFile()
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            var prefix = ""
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { prefix = "\n" }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data((prefix + line + "\n").utf8))
        } catch {
            log.error("append failed: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    private func write(_ text: String) -> Bool {
        do {
            try ensureFile()
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            return true
        } catch {
            log.error("write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func ensureFile() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }
}
