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

    /// Keep prediction inputs intact for 25 hours. Older history keeps the last
    /// reading in each fixed five-minute bucket, plus change and segment edges.
    /// Selecting original points makes repeated compaction idempotent.
    static func retainedSamples(_ samples: [UsageTrendSample], at date: Date) -> [UsageTrendSample] {
        let retained = samples.filter { $0.date > date.addingTimeInterval(-8 * 86400) }
        let detailedSince = date.addingTimeInterval(-25 * 3600)
        return retained.indices.compactMap { index in
            let sample = retained[index]
            guard sample.date < detailedSince, index > 0, index < retained.count - 1 else { return sample }
            let previous = retained[index - 1], next = retained[index + 1]
            if previous.segment != sample.segment || sample.segment != next.segment
                || previous.reset != sample.reset || sample.reset != next.reset
                || previous.remaining != sample.remaining || sample.remaining != next.remaining
                || sample.date.timeIntervalSince(previous.date) > UsageTrend.maximumGap
                || next.date.timeIntervalSince(sample.date) > UsageTrend.maximumGap {
                return sample
            }
            return floor(sample.date.timeIntervalSince1970 / 300) != floor(next.date.timeIntervalSince1970 / 300)
                ? sample : nil
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
            history[key] = Self.retainedSamples(history[key, default: []], at: date)
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
            history[window.id] = samples
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
    /// Both bounds are straight lines clipped at zero. Include their exact
    /// exhaustion times so the full-range polygon preserves each corner.
    var scenarioDates: [Date] {
        guard rate > 0, fastRate > slowRate, anchor.reset > anchor.date,
              (fastRate - slowRate) * anchor.reset.timeIntervalSince(anchor.date) > 0.000001 else { return [] }
        var dates = [anchor.date, anchor.reset]
        for speed in [slowRate, fastRate] where speed > 0 {
            let exhaustion = anchor.date.addingTimeInterval(anchor.remaining / speed)
            if exhaustion > anchor.date, exhaustion < anchor.reset { dates.append(exhaustion) }
        }
        return Array(Set(dates)).sorted()
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
    var minimumObservedDuration: TimeInterval {
        self == .hour ? lookback - bucketDuration : lookback * 2 / 3
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

    /// Display-only reduction: retain first/last and extrema in each one-point
    /// horizontal bin. Flush at segment boundaries so disconnected lines stay so.
    static func chartSamples(_ samples: [UsageTrendSample], domain: ClosedRange<Date>, width: Double) -> [UsageTrendSample] {
        let points = chartSamples(samples)
        let duration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard points.count > 2, duration.isFinite, duration > 0, width.isFinite else { return points }
        let bins = max(1, Int(min(2048, max(0, width))))
        var selected: [UsageTrendSample] = []
        var first = 0, lowest = 0, highest = 0
        func bucket(_ sample: UsageTrendSample) -> Int {
            let fraction = sample.date.timeIntervalSince(domain.lowerBound) / duration
            guard fraction.isFinite else { return 0 }
            return Int(min(Double(bins - 1), max(0, floor(fraction * Double(bins)))))
        }
        func appendGroup(through last: Int) {
            for index in Set([first, lowest, highest, last]).sorted() { selected.append(points[index]) }
        }
        var currentBucket = bucket(points[0])
        for index in 1..<points.count {
            let nextBucket = bucket(points[index])
            if nextBucket != currentBucket || points[index].segment != points[index - 1].segment {
                appendGroup(through: index - 1)
                first = index
                lowest = index
                highest = index
                currentBucket = nextBucket
            } else {
                if points[index].remaining < points[lowest].remaining { lowest = index }
                if points[index].remaining > points[highest].remaining { highest = index }
            }
        }
        appendGroup(through: points.count - 1)
        return selected
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
        // A read gap is not a quota reset. Walk the current quota history back
        // without crossing a deadline change, recovery, or unexplained segment edge.
        var firstIndex = samples.count - 1
        while firstIndex > 0 {
            let a = samples[firstIndex - 1], b = samples[firstIndex]
            guard a.date < b.date, a.remaining.isFinite, (0...100).contains(a.remaining),
                  a.remaining >= b.remaining, sameReset(a.reset, last.reset), a.reset > date else { break }
            let gap = b.date.timeIntervalSince(a.date)
            guard a.segment == b.segment || gap > maximumGap || a.reset != b.reset else { break }
            firstIndex -= 1
            if a.date <= cutoff { break }
        }
        let recent = Array(samples[firstIndex...])
        guard recent.count >= 3, let first = recent.first else { return .insufficientCoverage }
        // Measure actual observed intervals, clipped to the selected window.
        // Offline time never supplies coverage or consumption evidence.
        var observedDuration: TimeInterval = 0
        var steps: [Double] = []
        for (a, b) in zip(recent, recent.dropFirst()) {
            guard b.date.timeIntervalSince(a.date) <= maximumGap else { continue }
            observedDuration += max(0, b.date.timeIntervalSince(max(a.date, cutoff)))
            let drop = a.remaining - b.remaining
            if a.date >= cutoff, drop > 0.000001 { steps.append(drop) }
        }
        guard observedDuration + 0.000001 >= window.minimumObservedDuration else { return .insufficientCoverage }
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
                guard index + 1 < recent.count else { continue }
                let b = recent[index + 1]
                guard b.date.timeIntervalSince(a.date) <= maximumGap else { continue }
                let fraction = target.timeIntervalSince(a.date) / b.date.timeIntervalSince(a.date)
                remaining = a.remaining + (b.remaining - a.remaining) * fraction
            }
            points.append((target.timeIntervalSince(cutoff), remaining))
        }
        let requiredPoints = window == .hour ? count : Int(ceil(Double(count + 1) * 2 / 3))
        guard points.count >= requiredPoints else { return .insufficientCoverage }
        let observed = recent.drop(while: { $0.date < cutoff })
        // A decline straddling the cutoff has uncertain timing, even when a
        // long read gap prevents interpolation at the boundary.
        let boundaryDrop = first.date < cutoff && recent[1].date > cutoff
            && first.remaining > recent[1].remaining
        if !boundaryDrop, observed.first?.remaining == last.remaining, points.first?.remaining == last.remaining {
            return .ready(UsageTrendForecast(anchor: last, rate: 0, slowRate: 0, fastRate: 0))
        }
        // Boundary interpolation and unobserved gaps cannot manufacture signal.
        let observedDrop = steps.reduce(0, +)
        guard let step = steps.min() else { return .insufficientSignal }
        let strongSignal = steps.count >= 3 && observedDrop + 0.000001 >= max(1, 3 * step)
        if !strongSignal {
            // Integer quota readings often change only once per hour. Use the
            // observed average, not a step's position in a regression, for a
            // coarse hourly estimate. The +/-1pp scenarios reflect rounding.
            guard window == .hour, observedDrop + 0.000001 >= 1 else { return .insufficientSignal }
            return .ready(UsageTrendForecast(anchor: last, rate: observedDrop / observedDuration,
                slowRate: max(0, observedDrop - 1) / observedDuration,
                fastRate: (observedDrop + 1) / observedDuration))
        }
        let meanX = points.map(\.time).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.remaining).reduce(0, +) / Double(points.count)
        let denominator = points.reduce(0) { $0 + pow($1.time - meanX, 2) }
        let rate = max(0, -points.reduce(0) { $0 + ($1.time - meanX) * ($1.remaining - meanY) } / denominator)
        guard rate > 0 else { return .insufficientSignal }
        // Half-window average speeds reduce quantization spikes. Use the central
        // 80% of observed scenarios, not raw extrema or a confidence interval.
        let rates = points.indices.compactMap { i -> Double? in
            guard let j = points.indices.dropFirst(i + 1).first(where: {
                points[$0].time - points[i].time >= window.lookback / 2
            }) else { return nil }
            return max(0, (points[i].remaining - points[j].remaining) / (points[j].time - points[i].time))
        }.sorted()
        guard !rates.isEmpty else { return .insufficientCoverage }
        func quantile(_ probability: Double) -> Double {
            let position = probability * Double(rates.count - 1)
            let lower = Int(position), upper = min(lower + 1, rates.count - 1)
            return rates[lower] + (rates[upper] - rates[lower]) * (position - Double(lower))
        }
        return .ready(UsageTrendForecast(anchor: last, rate: rate,
                                        slowRate: min(rate, quantile(0.1)), fastRate: max(rate, quantile(0.9))))
    }
}
