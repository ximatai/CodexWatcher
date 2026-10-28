import XCTest
@testable import WatcherCore

final class UsageTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func window(_ used: Double, reset: Date? = nil, id: String = "codex.primary") -> UsageWindow {
        UsageWindow(id: id, bucketID: "codex", name: "Codex",
                    quota: QuotaWindow(usedPercent: used, windowDurationMins: 300,
                                       resetsAt: (reset ?? now.addingTimeInterval(9000)).timeIntervalSince1970))
    }
    private func withStore(_ body: (UsageTrendStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrendTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(UsageTrendStore(directory: directory), directory)
    }

    func testPersistsAndIsolatesAccountsAndWindows() throws {
        try withStore { store, directory in
            _ = try store.record(account: "a", windows: [window(10), window(30, id: "codex.secondary")], at: now)
            let restored = try UsageTrendStore(directory: directory).record(account: "a", windows: [window(20)], at: now.addingTimeInterval(300))
            XCTAssertEqual(restored["codex.primary"]?.map(\.remaining), [90, 80])
            XCTAssertEqual(restored["codex.secondary"]?.map(\.remaining), [70])
            let other = try store.record(account: "b", windows: [window(5)], at: now)
            XCTAssertEqual(other["codex.primary"]?.map(\.remaining), [95])
        }
    }

    func testResetRecoveryAndOfflineGapStartNewSegments() throws {
        try withStore { store, _ in
            var history: [String: [UsageTrendSample]] = [:]
            for (offset, used) in [(0.0, 20.0), (300, 30), (600, 10), (1800, 20)] {
                history = try store.record(account: "a", windows: [window(used)], at: now.addingTimeInterval(offset))
            }
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples[0].segment, samples[1].segment)
            XCTAssertNotEqual(samples[1].segment, samples[2].segment)
            XCTAssertNotEqual(samples[2].segment, samples[3].segment)
            XCTAssertNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(1800)))
            let reset = try store.record(account: "a", windows: [window(20, reset: now.addingTimeInterval(10000))], at: now.addingTimeInterval(2100))
            XCTAssertNotEqual(reset["codex.primary"]?.last?.segment, samples.last?.segment)
        }
    }

    func testPredictsExhaustionAndSpeedRangeFromRealElapsedTime() throws {
        let segment = UUID()
        let samples = [(0.0, 70.0), (300, 65), (600, 60), (900, 55)].map {
            UsageTrendSample(date: now.addingTimeInterval($0.0), remaining: $0.1,
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(900)))
        XCTAssertEqual(forecast.rate, 1.0 / 60, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(forecast.exhaustion).timeIntervalSince(now), 4200, accuracy: 0.001)
        XCTAssertEqual(forecast.remaining(at: now.addingTimeInterval(10000)), 0)
        XCTAssertLessThanOrEqual(forecast.slowRate, forecast.rate)
        XCTAssertGreaterThanOrEqual(forecast.fastRate, forecast.rate)
        XCTAssertNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(1501)))
    }

    func testInsufficientFlatAndExhaustedSamples() throws {
        let segment = UUID()
        func samples(_ remaining: Double) -> [UsageTrendSample] {
            [0.0, 300, 600].map { UsageTrendSample(date: now.addingTimeInterval($0), remaining: remaining,
                                                 reset: now.addingTimeInterval(9000), segment: segment) }
        }
        XCTAssertNil(UsageTrend.forecast(samples: Array(samples(70).prefix(2)), at: now.addingTimeInterval(600)))
        XCTAssertNil(try XCTUnwrap(UsageTrend.forecast(samples: samples(70), at: now.addingTimeInterval(600))).exhaustion)
        XCTAssertNil(UsageTrend.forecast(samples: samples(0), at: now.addingTimeInterval(600)))
        XCTAssertNil(UsageTrend.forecast(samples: samples(70), at: now.addingTimeInterval(10000)))
    }

    func testInvalidReadingsAndFrequentRefreshesDoNotCreateSamples() throws {
        try withStore { store, _ in
            _ = try store.record(account: "a", windows: [window(20)], at: now)
            let repeated = try store.record(account: "a", windows: [window(20)], at: now.addingTimeInterval(1))
            XCTAssertEqual(repeated["codex.primary"]?.count, 1)
            let invalid = try store.record(account: "a", windows: [window(.nan), window(101, id: "bad"), window(10, reset: now)], at: now)
            XCTAssertNil(invalid["bad"])
            XCTAssertEqual(invalid["codex.primary"]?.count, 1)
        }
    }

    func testChangedReadingWithinBucketKeepsForecastAndLatestAnchor() throws {
        try withStore { store, directory in
            for (seconds, used) in [(0.0, 10.0), (300, 20), (600, 30)] {
                _ = try store.record(account: "a", windows: [window(used)], at: now.addingTimeInterval(seconds))
            }
            let date = now.addingTimeInterval(605)
            let history = try store.record(account: "a", windows: [window(31)], at: date)
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples.count, 3)
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: date))
            XCTAssertEqual(forecast.anchor.remaining, 69)
            XCTAssertEqual(forecast.anchor.date, date)
            let restored = try UsageTrendStore(directory: directory).record(account: "a", windows: [], at: date)
            XCTAssertEqual(restored["codex.primary"], samples)
        }
    }

    func testFrequentChangedReadingsDoNotStarveSampling() throws {
        try withStore { store, _ in
            var history: [String: [UsageTrendSample]] = [:]
            for seconds in stride(from: 0, through: 900, by: 5) {
                history = try store.record(account: "a", windows: [window(10 + Double(seconds) / 30)],
                                           at: now.addingTimeInterval(Double(seconds)))
            }
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples.count, 31)
            XCTAssertEqual(Set(samples.map { floor($0.date.timeIntervalSince1970 / 30) }).count, samples.count)
            XCTAssertEqual(samples.last?.remaining, 60)
            XCTAssertNotNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(900)))
        }
    }

    func testRecoveryWithinBucketStillStartsNewSegment() throws {
        try withStore { store, _ in
            let first = try store.record(account: "a", windows: [window(40)], at: now)
            let recovered = try store.record(account: "a", windows: [window(0)], at: now.addingTimeInterval(5))
            let samples = try XCTUnwrap(recovered["codex.primary"])
            XCTAssertEqual(samples.count, 2)
            XCTAssertNotEqual(samples.last?.segment, first["codex.primary"]?.last?.segment)
            XCTAssertNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(5)))
        }
    }

    func testClockRollbackDoesNotEraseOrAppendToNewerHistory() throws {
        try withStore { store, _ in
            _ = try store.record(account: "a", windows: [window(20)], at: now)
            let history = try store.record(account: "a", windows: [window(10)], at: now.addingTimeInterval(-60))
            XCTAssertEqual(history["codex.primary"]?.map(\.remaining), [80])
        }
    }

    func testConcurrentInstancesMergeDistinctWindows() throws {
        try withStore { store, directory in
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                _ = try? UsageTrendStore(directory: directory).record(account: "a",
                    windows: [window(20, id: "codex.\(index)")], at: now)
            }
            let history = try store.record(account: "a", windows: [], at: now)
            XCTAssertEqual(history.count, 16)
        }
    }

    func testHistoryReadFailureDoesNotQuarantineSource() throws {
        try withStore { store, directory in
            _ = try store.record(account: "a", windows: [window(20)], at: now)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            XCTAssertThrowsError(try store.record(account: "a", windows: [window(30)], at: now))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
        }
    }

    func testRetentionAndCorruptStorage() throws {
        try withStore { store, directory in
            _ = try store.record(account: "a", windows: [window(20)], at: now)
            let pruned = try store.record(account: "a", windows: [window(30, reset: now.addingTimeInterval(10 * 86400))], at: now.addingTimeInterval(9 * 86400))
            XCTAssertEqual(pruned["codex.primary"]?.count, 1)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
            try Data("broken".utf8).write(to: file)
            let recovered = try store.recordResult(account: "a", windows: [window(20)], at: now)
            XCTAssertTrue(recovered.recoveredFromCorruption)
            XCTAssertEqual(recovered.history["codex.primary"]?.map(\.remaining), [80])
            XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("corrupt")), Data("broken".utf8))
            let next = try store.recordResult(account: "a", windows: [window(30)], at: now.addingTimeInterval(300))
            XCTAssertFalse(next.recoveredFromCorruption)
            XCTAssertEqual(next.history["codex.primary"]?.map(\.remaining), [80, 70])
            try Data("broken-again".utf8).write(to: file)
            _ = try store.record(account: "a", windows: [window(20)], at: now.addingTimeInterval(600))
            XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("corrupt")), Data("broken-again".utf8))
        }
    }
}
