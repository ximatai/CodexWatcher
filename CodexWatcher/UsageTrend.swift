import Foundation
import CryptoKit
import Darwin

struct UsageTrendSample: Codable, Equatable {
    let date: Date
    let remaining: Double
    let reset: Date
    let segment: UUID
}

/// A local, bounded history. Only successful foreground reads are recorded.
final class UsageTrendStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    private func file(account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("usage-trend-\(key).json")
    }

    func record(account: String, windows: [UsageWindow], at date: Date) throws -> [String: [UsageTrendSample]] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = file(account: account)
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        var history: [String: [UsageTrendSample]] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            history = try JSONDecoder().decode([String: [UsageTrendSample]].self, from: Data(contentsOf: file))
        }
        for key in Array(history.keys) {
            history[key] = Array(history[key, default: []].filter {
                $0.date > date.addingTimeInterval(-8 * 86400)
            }.suffix(4096))
            if history[key]?.isEmpty == true { history.removeValue(forKey: key) }
        }
        for window in windows {
            guard window.quota.usedPercent.isFinite, (0...100).contains(window.quota.usedPercent),
                  let reset = window.quota.resetDate, reset.timeIntervalSince1970.isFinite,
                  reset > date else { continue }
            var samples = history[window.id, default: []]
            let remaining = 100 - window.quota.usedPercent
            let last = samples.last
            if let last, date < last.date { continue }
            let continuous = last.map {
                $0.reset == reset && remaining <= $0.remaining && date.timeIntervalSince($0.date) <= 900
            } ?? false
            // Fixed buckets bound sample density without discarding the latest reading.
            // Replacing a point must not slide the bucket and starve future samples.
            if continuous, let last,
               floor(date.timeIntervalSince1970 / 30) == floor(last.date.timeIntervalSince1970 / 30) {
                if remaining != last.remaining {
                    samples[samples.count - 1] = UsageTrendSample(date: date, remaining: remaining,
                                                                reset: reset, segment: last.segment)
                    history[window.id] = samples
                }
                continue
            }
            samples.append(UsageTrendSample(date: date, remaining: remaining, reset: reset,
                                           segment: continuous ? last!.segment : UUID()))
            history[window.id] = Array(samples.suffix(4096))
        }
        try JSONEncoder().encode(history).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return history
    }
}

struct UsageTrendForecast {
    let anchor: UsageTrendSample
    let rate: Double // percentage points per second
    let slowRate: Double
    let fastRate: Double
    var exhaustion: Date? { rate > 0 ? anchor.date.addingTimeInterval(anchor.remaining / rate) : nil }
    func remaining(at date: Date, rate: Double? = nil) -> Double {
        max(0, min(100, anchor.remaining - (rate ?? self.rate) * max(0, date.timeIntervalSince(anchor.date))))
    }
}

enum UsageTrend {
    static let lookback: TimeInterval = 3600

    static func forecast(samples: [UsageTrendSample], at date: Date) -> UsageTrendForecast? {
        guard let last = samples.last, last.date <= date, date.timeIntervalSince(last.date) <= 600,
              last.reset > date, last.remaining > 0 else { return nil }
        let recent = samples.filter {
            $0.segment == last.segment && $0.reset == last.reset && $0.date >= last.date.addingTimeInterval(-lookback)
                && $0.date <= last.date && $0.remaining.isFinite && (0...100).contains($0.remaining)
        }
        guard recent.count >= 3, let first = recent.first,
              last.date.timeIntervalSince(first.date) >= 600 else { return nil }
        // Least squares over elapsed wall time includes pauses, rather than assuming continuous work.
        let xs = recent.map { $0.date.timeIntervalSince(first.date) }
        let ys = recent.map(\.remaining)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let denominator = xs.reduce(0) { $0 + pow($1 - meanX, 2) }
        guard denominator > 0 else { return nil }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / denominator
        let rate = max(0, -slope)
        // Observed >=5-minute interval speeds provide scenarios, not a statistical confidence interval.
        var rates: [Double] = [rate]
        var baseline = first
        for sample in recent.dropFirst() {
            let elapsed = sample.date.timeIntervalSince(baseline.date)
            if elapsed >= 300 {
                rates.append(max(0, (baseline.remaining - sample.remaining) / elapsed))
                baseline = sample
            }
        }
        return UsageTrendForecast(anchor: last, rate: rate,
                                  slowRate: rates.min() ?? rate, fastRate: rates.max() ?? rate)
    }
}
