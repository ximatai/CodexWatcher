import Foundation
import CryptoKit
import Darwin

struct UsageTrendSample: Codable, Equatable, Sendable {
    let date: Date
    let remaining: Double
    let reset: Date
    let segment: UUID
}

struct UsageTrendWriteResult: Sendable {
    let history: [String: [UsageTrendSample]]
    let recoveredFromCorruption: Bool
}

/// A local, bounded history. Only successful foreground reads are recorded.
final class UsageTrendStore: @unchecked Sendable {
    private let directory: URL
    private let queue: DispatchQueue
    init(directory: URL, queue: DispatchQueue = DispatchQueue(label: "CodexWatcher.usage-trend", qos: .utility)) {
        self.directory = directory
        self.queue = queue
    }

    func recordInBackground(account: String, windows: [UsageWindow], at date: Date) async throws -> UsageTrendWriteResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.recordResult(account: account, windows: windows, at: date)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func file(account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("usage-trend-\(key).json")
    }

    func record(account: String, windows: [UsageWindow], at date: Date) throws -> [String: [UsageTrendSample]] {
        try recordResult(account: account, windows: windows, at: date).history
    }

    func recordResult(account: String, windows: [UsageWindow], at date: Date) throws -> UsageTrendWriteResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let file = file(account: account)
        let descriptor = open(file.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        var history: [String: [UsageTrendSample]] = [:]
        var recovered = false
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            do {
                history = try JSONDecoder().decode([String: [UsageTrendSample]].self, from: data)
            } catch is DecodingError {
                // Disposable history differs from irreversible reset records. Preserve
                // one quarantined copy per account and rebuild under the same lock.
                let quarantine = file.appendingPathExtension("corrupt")
                if FileManager.default.fileExists(atPath: quarantine.path) {
                    try FileManager.default.removeItem(at: quarantine)
                }
                try FileManager.default.moveItem(at: file, to: quarantine)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quarantine.path)
                recovered = true
            }
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
                UsageTrend.sameReset($0.reset, reset) && $0.reset > date
                    && remaining <= $0.remaining && date.timeIntervalSince($0.date) <= UsageTrend.maximumGap
            } ?? false
            // Fixed buckets bound sample density without discarding the latest reading.
            // Replacing a point must not slide the bucket and starve future samples.
            if continuous, let last,
               floor(date.timeIntervalSince1970 / 30) == floor(last.date.timeIntervalSince1970 / 30) {
                if remaining != last.remaining {
                    samples[samples.count - 1] = UsageTrendSample(date: date, remaining: remaining,
                                                                reset: last.reset, segment: last.segment)
                    history[window.id] = samples
                }
                continue
            }
            samples.append(UsageTrendSample(date: date, remaining: remaining, reset: continuous ? last!.reset : reset,
                                           segment: continuous ? last!.segment : UUID()))
            history[window.id] = Array(samples.suffix(4096))
        }
        try JSONEncoder().encode(history).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return UsageTrendWriteResult(history: history, recoveredFromCorruption: recovered)
    }
}

struct UsageTrendForecast {
    let anchor: UsageTrendSample
    let rate: Double // percentage points per second
    let slowRate: Double
    let fastRate: Double
    /// Bound scenarios to the observed time scale, never beyond the quota reset.
    /// A stationary upper bound spanning half the remaining quota is too broad
    /// to add useful visual information. Keep the central forecast in that case.
    func scenarioEnd(window: UsageTrendWindow) -> Date? {
        let end = min(anchor.reset, anchor.date.addingTimeInterval(window.lookback))
        guard rate > 0, fastRate > slowRate, end > anchor.date else { return nil }
        let spread = remaining(at: end, rate: slowRate) - remaining(at: end, rate: fastRate)
        guard slowRate > 0 || spread < anchor.remaining / 2 else { return nil }
        return end
    }
    var exhaustion: Date? { rate > 0 ? anchor.date.addingTimeInterval(anchor.remaining / rate) : nil }
    func remaining(at date: Date, rate: Double? = nil) -> Double {
        max(0, min(100, anchor.remaining - (rate ?? self.rate) * max(0, date.timeIntervalSince(anchor.date))))
    }
}

enum UsageTrendWindow: Int, CaseIterable {
    case hour = 1, eightHours = 8, day = 24

    var lookback: TimeInterval { Double(rawValue) * 3600 }
    var bucketDuration: TimeInterval {
        switch self {
        case .hour: return 300
        case .eightHours: return 900
        case .day: return 3600
        }
    }
    var title: String.LocalizationValue {
        switch self {
        case .hour: return "1 小时"
        case .eightHours: return "8 小时"
        case .day: return "24 小时"
        }
    }
}

enum UsageTrendAssessment {
    case unavailable, insufficientCoverage, insufficientSignal
    case ready(UsageTrendForecast)

    var forecast: UsageTrendForecast? {
        if case .ready(let value) = self { return value }
        return nil
    }
}

enum UsageTrend {
    /// Remove only interior points of horizontal runs. Keep both ends of each
    /// run and every segment boundary; prediction always uses the original data.
    static func chartSamples(_ samples: [UsageTrendSample]) -> [UsageTrendSample] {
        guard samples.count > 2 else { return samples }
        return samples.indices.compactMap { index in
            let sample = samples[index]
            if index > 0, index < samples.count - 1 {
                let previous = samples[index - 1], next = samples[index + 1]
                if previous.segment == sample.segment, sample.segment == next.segment,
                   previous.remaining == sample.remaining, sample.remaining == next.remaining {
                    return nil
                }
            }
            return sample
        }
    }

    static let maximumGap: TimeInterval = 900
    // Some service responses move an otherwise unchanged deadline by a second or two.
    // Compare to a stable stored deadline so small changes cannot drift indefinitely.
    static func sameReset(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= 60
    }

    static func forecast(samples: [UsageTrendSample], at date: Date, window: UsageTrendWindow = .hour) -> UsageTrendForecast? {
        assess(samples: samples, at: date, window: window).forecast
    }

    static func assess(samples: [UsageTrendSample], at date: Date, window: UsageTrendWindow = .hour) -> UsageTrendAssessment {
        guard let last = samples.last, last.date <= date, date.timeIntervalSince(last.date) <= 600,
              last.reset > date, last.remaining.isFinite, last.remaining > 0, last.remaining <= 100 else { return .unavailable }
        let cutoff = last.date.addingTimeInterval(-window.lookback)
        // Keep one earlier observation for interpolation at the left boundary.
        let segment = samples.filter { $0.segment == last.segment && sameReset($0.reset, last.reset) && $0.date <= last.date }
        let startIndex = segment.lastIndex(where: { $0.date <= cutoff }) ?? segment.startIndex
        let recent = Array(segment[startIndex...])
        guard recent.count >= 3, let first = recent.first,
              first.date <= cutoff.addingTimeInterval(window.bucketDuration) else { return .insufficientCoverage }
        for (a, b) in zip(recent, recent.dropFirst()) {
            guard a.remaining.isFinite, (0...100).contains(a.remaining),
                  b.remaining.isFinite, (0...100).contains(b.remaining),
                  b.date > a.date, b.date.timeIntervalSince(a.date) <= maximumGap,
                  b.remaining <= a.remaining else { return .insufficientCoverage }
        }
        // Equally spaced endpoints give wall time equal weight regardless of poll frequency.
        // Interpolation is allowed only inside observed intervals of at most 15 minutes.
        var points: [(time: TimeInterval, remaining: Double)] = []
        var index = 0
        let count = Int(window.lookback / window.bucketDuration)
        for bucket in 0...count {
            let target = cutoff.addingTimeInterval(Double(bucket) * window.bucketDuration)
            guard target >= first.date else { continue }
            while index + 1 < recent.count && recent[index + 1].date <= target { index += 1 }
            let a = recent[index]
            let remaining: Double
            if a.date == target {
                remaining = a.remaining
            } else {
                guard index + 1 < recent.count else { return .insufficientCoverage }
                let b = recent[index + 1]
                let fraction = target.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
                remaining = a.remaining + (b.remaining - a.remaining) * fraction
            }
            points.append((target.timeIntervalSince(cutoff), remaining))
        }
        // At most one boundary bucket may be absent: 55 min / 7h45m / 23h coverage.
        guard points.count >= count else { return .insufficientCoverage }
        let drop = points.first!.remaining - points.last!.remaining
        if drop == 0 {
            return .ready(UsageTrendForecast(anchor: last, rate: 0, slowRate: 0, fastRate: 0))
        }
        // The boundary predecessor supports interpolation, not evidence of consumption
        // inside the window. Gate on actual in-window readings, including their net drop.
        let observed = recent.drop(while: { $0.date < cutoff })
        let steps = zip(observed, observed.dropFirst()).map { $0.remaining - $1.remaining }.filter { $0 > 0.000001 }
        let observedDrop = observed.first!.remaining - last.remaining
        // Three observed increments and at least 1pp avoid extrapolating rounding noise.
        guard let step = steps.min(), steps.count >= 3, observedDrop + 0.000001 >= max(1, 3 * step) else { return .insufficientSignal }
        let meanX = points.map(\.time).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.remaining).reduce(0, +) / Double(points.count)
        let denominator = points.reduce(0) { $0 + pow($1.time - meanX, 2) }
        let rate = max(0, -points.reduce(0) { $0 + ($1.time - meanX) * ($1.remaining - meanY) } / denominator)
        guard rate > 0 else { return .insufficientSignal }
        // Half-window average speeds reduce quantization spikes. Use the central
        // 80% of observed scenarios, not raw extrema or a confidence interval.
        let span = points.count / 2
        let rates = (0..<(points.count - span)).map { i in
            max(0, (points[i].remaining - points[i + span].remaining) / (points[i + span].time - points[i].time))
        }.sorted()
        func quantile(_ probability: Double) -> Double {
            let position = probability * Double(rates.count - 1)
            let lower = Int(position), upper = min(lower + 1, rates.count - 1)
            return rates[lower] + (rates[upper] - rates[lower]) * (position - Double(lower))
        }
        return .ready(UsageTrendForecast(anchor: last, rate: rate,
                                        slowRate: min(rate, quantile(0.1)), fastRate: max(rate, quantile(0.9))))
    }
}
