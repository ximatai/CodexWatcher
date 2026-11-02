import XCTest
@testable import WatcherCore

final class UsageTrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    func testChartCompactionPreservesPlateauEdgesAndSegmentBoundaries() {
        let first = UUID(), second = UUID()
        let values: [(Double, UUID)] = [(80, first), (80, first), (80, first),
            (79, first), (79, first), (79, first), (79, second), (79, second), (78, second)]
        let samples = values.enumerated().map { index, value in
            UsageTrendSample(date: now.addingTimeInterval(Double(index) * 30),
                             remaining: value.0, reset: now.addingTimeInterval(9000), segment: value.1)
        }
        XCTAssertEqual(UsageTrend.chartSamples(samples), [0, 2, 3, 5, 6, 7, 8].map { samples[$0] })
        XCTAssertEqual(UsageTrend.chartSamples([]), [])
        XCTAssertEqual(UsageTrend.chartSamples(Array(samples.prefix(2))), Array(samples.prefix(2)))
        let changing = samples.enumerated().map { index, sample in
            UsageTrendSample(date: sample.date, remaining: 90 - Double(index), reset: sample.reset, segment: first)
        }
        XCTAssertEqual(UsageTrend.chartSamples(changing), changing)
    }

    func testChartReductionBoundsDenseHistoryAndPreservesExtrema() {
        let segment = UUID()
        let samples = (0..<23040).map { index in
            UsageTrendSample(date: now.addingTimeInterval(Double(index) * 30), remaining: 95 - Double(index) / 400,
                             reset: now.addingTimeInterval(9 * 86400), segment: segment)
        }
        let domain = samples.first!.date...samples.last!.date
        let reduced = UsageTrend.chartSamples(samples, domain: domain, width: 334)
        XCTAssertLessThanOrEqual(reduced.count, 4 * 334)
        XCTAssertEqual(reduced.first, samples.first)
        XCTAssertEqual(reduced.last, samples.last)
        XCTAssertEqual(reduced.map(\.date), reduced.map(\.date).sorted())
        XCTAssertGreaterThan(UsageTrend.chartSamples(samples, domain: domain, width: 668).count, reduced.count)
        let values: [Double] = [50, 80, 20, 60, 40, 55]
        let spikes = values.enumerated().map { index, value in
            UsageTrendSample(date: now.addingTimeInterval(Double(index)), remaining: value,
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        XCTAssertEqual(UsageTrend.chartSamples(spikes, domain: now...now.addingTimeInterval(10), width: 1),
                       [0, 1, 2, 5].map { spikes[$0] })
        XCTAssertEqual(UsageTrend.chartSamples(spikes, domain: now...now.addingTimeInterval(10), width: 0),
                       [0, 1, 2, 5].map { spikes[$0] })
        XCTAssertEqual(UsageTrend.chartSamples([], domain: domain, width: 334), [])
    }

    func testChartReductionPreservesBothSidesOfEverySegmentBoundary() {
        let first = UUID(), second = UUID(), third = UUID()
        let segments = [first, first, first, second, second, second, third, third]
        let samples = segments.enumerated().map { index, segment in
            UsageTrendSample(date: now.addingTimeInterval(Double(index)), remaining: 80 - Double(index),
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        XCTAssertEqual(UsageTrend.chartSamples(samples, domain: now...now.addingTimeInterval(10), width: 1),
                       [0, 2, 3, 5, 6, 7].map { samples[$0] })
    }

    func testScenarioReachesResetAndPreservesExactExhaustionCorners() {
        let reset = now.addingTimeInterval(7 * 86400)
        let anchor = UsageTrendSample(date: now, remaining: 60, reset: reset, segment: UUID())
        func forecast(_ slow: Double, _ fast: Double, rate: Double = 2) -> UsageTrendForecast {
            UsageTrendForecast(anchor: anchor, rate: rate / 3600,
                               slowRate: slow / 3600, fastRate: fast / 3600)
        }
        XCTAssertEqual(forecast(1, 3).scenarioDates,
                       [now, now.addingTimeInterval(20 * 3600), now.addingTimeInterval(60 * 3600), reset])
        XCTAssertEqual(forecast(0, 30).scenarioDates, [now, now.addingTimeInterval(2 * 3600), reset])
        XCTAssertEqual(forecast(0, 3).scenarioDates.last, reset)
        XCTAssertEqual(forecast(0, 0, rate: 0).scenarioDates, [])
        XCTAssertEqual(forecast(2, 2).scenarioDates, [])
        XCTAssertEqual(forecast(2, 2 + 1e-14).scenarioDates, [])
        let nearReset = UsageTrendSample(date: now, remaining: 60,
                                        reset: now.addingTimeInterval(600), segment: UUID())
        let bounded = UsageTrendForecast(anchor: nearReset, rate: 2 / 3600, slowRate: 1 / 3600, fastRate: 3 / 3600)
        XCTAssertEqual(bounded.scenarioDates, [now, nearReset.reset])
        XCTAssertEqual(forecast(0, 30).exhaustion, now.addingTimeInterval(30 * 3600))
    }

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
        let samples = stride(from: 0.0, through: 3600, by: 300).map {
            UsageTrendSample(date: now.addingTimeInterval($0), remaining: 70 - $0 / 180,
                             reset: now.addingTimeInterval(20000), segment: segment)
        }
        let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(3600)))
        XCTAssertEqual(forecast.rate, 1.0 / 180, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(forecast.exhaustion).timeIntervalSince(now), 12600, accuracy: 0.001)
        XCTAssertEqual(forecast.remaining(at: now.addingTimeInterval(20000)), 0)
        XCTAssertLessThanOrEqual(forecast.slowRate, forecast.rate)
        XCTAssertGreaterThanOrEqual(forecast.fastRate, forecast.rate)
        XCTAssertNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(4201)))
    }

    func testInsufficientFlatAndExhaustedSamples() throws {
        let segment = UUID()
        func samples(_ remaining: Double) -> [UsageTrendSample] {
            stride(from: 0.0, through: 3600, by: 300).map {
                UsageTrendSample(date: now.addingTimeInterval($0), remaining: remaining,
                                 reset: now.addingTimeInterval(9000), segment: segment)
            }
        }
        XCTAssertNil(UsageTrend.forecast(samples: Array(samples(70).prefix(2)), at: now.addingTimeInterval(300)))
        XCTAssertNil(try XCTUnwrap(UsageTrend.forecast(samples: samples(70), at: now.addingTimeInterval(3600))).exhaustion)
        XCTAssertNil(UsageTrend.forecast(samples: samples(0), at: now.addingTimeInterval(3600)))
        XCTAssertNil(UsageTrend.forecast(samples: samples(70), at: now.addingTimeInterval(10000)))
    }

    func testForecastWindowsUseDifferentLookbackRanges() throws {
        let segment = UUID()
        let reset = now.addingTimeInterval(7 * 86400)
        let samples = stride(from: -26 * 60, through: 0, by: 5).map { minute -> UsageTrendSample in
            let age = -Double(minute) / 60
            let remaining: Double
            if age <= 1 { remaining = 60 + age * 10 }
            else if age <= 8 { remaining = 70 + (age - 1) * 2 }
            else { remaining = 84 + (age - 8) * 0.5 }
            return UsageTrendSample(date: now.addingTimeInterval(Double(minute * 60)),
                                    remaining: remaining, reset: reset, segment: segment)
        }
        let hour = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now, window: .hour))
        let eight = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now, window: .eightHours))
        let day = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now, window: .day))
        XCTAssertEqual(hour.rate * 3600, 10, accuracy: 0.00001)
        XCTAssertGreaterThan(hour.rate, eight.rate)
        XCTAssertGreaterThan(eight.rate, day.rate)
        let withinDay = samples.filter { $0.date >= now.addingTimeInterval(-86400) }
        XCTAssertEqual(day.rate, try XCTUnwrap(UsageTrend.forecast(samples: withinDay, at: now, window: .day)).rate)
        XCTAssertEqual(hour.rate, try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now)).rate)
    }

    func testAllForecastWindowsRespectSegmentsResetAndFreshness() throws {
        let segment = UUID()
        let reset = now.addingTimeInterval(7 * 86400)
        for window in UsageTrendWindow.allCases {
            let current = stride(from: -window.lookback, through: 0, by: 300).map {
                UsageTrendSample(date: now.addingTimeInterval($0), remaining: 60 - $0 / 3600,
                                 reset: reset, segment: segment)
            }
            let unrelated = [
                UsageTrendSample(date: now.addingTimeInterval(-window.lookback - 1800), remaining: 100, reset: reset, segment: UUID()),
                UsageTrendSample(date: now.addingTimeInterval(-window.lookback - 900), remaining: 99, reset: reset.addingTimeInterval(3600), segment: segment)
            ]
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: unrelated + current, at: now, window: window))
            XCTAssertEqual(forecast.rate * 3600, 1, accuracy: 0.00001)
            XCTAssertNil(UsageTrend.forecast(samples: Array(current.suffix(2)), at: now, window: window))
            XCTAssertNil(UsageTrend.forecast(samples: current, at: now.addingTimeInterval(601), window: window))
        }
    }

    func testDensePollingDoesNotChangeEqualTimeForecast() throws {
        let reset = now.addingTimeInterval(7 * 86400)
        for window in UsageTrendWindow.allCases {
            let segment = UUID()
            func sample(_ seconds: Double) -> UsageTrendSample {
                let progress = (seconds + window.lookback) / window.lookback
                return UsageTrendSample(date: now.addingTimeInterval(seconds), remaining: 80 - 30 * progress * progress,
                                        reset: reset, segment: segment)
            }
            let uniform = stride(from: -window.lookback, through: 0, by: 300).map(sample)
            let extra = stride(from: -window.lookback / 4, through: 0, by: 30)
                .filter { $0.truncatingRemainder(dividingBy: 300) != 0 }.map(sample)
            let dense = (uniform + extra).sorted { $0.date < $1.date }
            let a = try XCTUnwrap(UsageTrend.forecast(samples: uniform, at: now, window: window))
            let b = try XCTUnwrap(UsageTrend.forecast(samples: dense, at: now, window: window))
            XCTAssertEqual(a.rate, b.rate, accuracy: 0.000000001)
            XCTAssertEqual(a.slowRate, b.slowRate, accuracy: 0.000000001)
            XCTAssertEqual(a.fastRate, b.fastRate, accuracy: 0.000000001)
        }
    }

    func testCoverageRequiresMinimumObservedTimeForSelectedWindow() throws {
        for window in UsageTrendWindow.allCases {
            func samples(start: Double) -> [UsageTrendSample] {
                let segment = UUID()
                var offsets = Array(stride(from: start, through: 0, by: 300))
                if offsets.last != 0 { offsets.append(0) }
                return offsets.map { UsageTrendSample(date: now.addingTimeInterval($0), remaining: 40 - $0 / 1800,
                    reset: now.addingTimeInterval(7 * 86400), segment: segment) }
            }
            let boundary = -window.minimumObservedDuration
            XCTAssertNotNil(UsageTrend.forecast(samples: samples(start: boundary), at: now, window: window))
            guard case .insufficientCoverage = UsageTrend.assess(samples: samples(start: boundary + 1), at: now, window: window) else {
                return XCTFail("Incomplete \(window) window must not be forecast")
            }
            guard case .insufficientCoverage = UsageTrend.assess(samples: samples(start: -600), at: now, window: window) else {
                return XCTFail("Ten minutes cannot represent \(window)")
            }
        }
    }

    func testFewIntegerStepsUseCoarseHourlyEstimateWithoutLongWindowFallback() throws {
        let segment = UUID()
        let samples = stride(from: -3600.0, through: 0, by: 30).map {
            UsageTrendSample(date: now.addingTimeInterval($0), remaining: 41 - floor(($0 + 3600) / 1800),
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now))
        XCTAssertEqual(forecast.rate * 3600, 2, accuracy: 0.000001)
        XCTAssertEqual(forecast.slowRate * 3600, 1, accuracy: 0.000001)
        XCTAssertEqual(forecast.fastRate * 3600, 3, accuracy: 0.000001)
        XCTAssertNil(UsageTrend.forecast(samples: samples, at: now, window: .eightHours))
        XCTAssertNil(UsageTrend.forecast(samples: samples, at: now, window: .day))
    }

    func testOnePercentagePointHourlyEstimateDoesNotDependOnStepTiming() throws {
        let segment = UUID(), reset = now.addingTimeInterval(86400)
        for dropAt in [-3300.0, -1800, -300] {
            let samples = stride(from: -3600.0, through: 0, by: 30).map { offset in
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: offset < dropAt ? 50 : 49,
                    reset: reset, segment: segment)
            }
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now))
            XCTAssertEqual(forecast.rate * 3600, 1, accuracy: 0.000001)
            XCTAssertEqual(forecast.slowRate, 0)
            XCTAssertEqual(forecast.fastRate * 3600, 2, accuracy: 0.000001)
        }
        let smallDrop = stride(from: -3600.0, through: 0, by: 30).map { offset in
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: offset < -1800 ? 50 : 49.5,
                reset: reset, segment: segment)
        }
        guard case .insufficientSignal = UsageTrend.assess(samples: smallDrop, at: now) else {
            return XCTFail("A sub-percentage-point isolated step should remain insufficient")
        }
    }

    func testSingleStepStillDoesNotUnlockLongWindowForecast() {
        let segment = UUID(), reset = now.addingTimeInterval(86400)
        for window in [UsageTrendWindow.eightHours, .day] {
            let samples = stride(from: -window.lookback, through: 0, by: 300).map { offset in
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: offset < -3600 ? 50 : 49,
                    reset: reset, segment: segment)
            }
            guard case .insufficientSignal = UsageTrend.assess(samples: samples, at: now, window: window) else {
                return XCTFail("Only the hourly window may use a coarse single-step forecast")
            }
        }
    }

    func testOutsidePredecessorCannotSupplyThirdConsumptionStep() throws {
        for window in UsageTrendWindow.allCases {
            let segment = UUID()
            func sample(_ offset: Double, _ remaining: Double) -> UsageTrendSample {
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                                 reset: now.addingTimeInterval(7 * 86400), segment: segment)
            }
            var inside = stride(from: -window.lookback + 1, through: -299, by: 300).map {
                sample($0, $0 < -window.lookback / 2 ? 80 : 79)
            }
            inside.append(sample(0, 78))
            let predecessor = sample(-window.lookback - 299, 80.1)
            for readings in [inside, [predecessor] + inside] {
                if window == .hour {
                    let forecast = try XCTUnwrap(UsageTrend.forecast(samples: readings, at: now, window: window))
                    XCTAssertEqual(forecast.rate * 3600, 2, accuracy: 0.001)
                    XCTAssertEqual(forecast.fastRate, forecast.rate * 1.5, accuracy: 0.000000001)
                } else if case .insufficientSignal = UsageTrend.assess(samples: readings, at: now, window: window) {
                    // Outside-window steps must not unlock a long-window forecast.
                } else {
                    XCTFail("Boundary interpolation must not manufacture a third in-window step")
                }
            }
        }
    }

    func testCutoffStraddlingDropIsUncertainRatherThanZeroConsumption() throws {
        let segment = UUID(), reset = now.addingTimeInterval(86400)
        for window in UsageTrendWindow.allCases {
            func sample(_ offset: Double, _ remaining: Double) -> UsageTrendSample {
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                                 reset: reset, segment: segment)
            }
            let inside = stride(from: -window.lookback + 299, through: -1, by: 300).map { sample($0, 55) }
                + [sample(0, 55)]
            let crossing = [sample(-window.lookback - 1, 60)] + inside
            guard case .insufficientSignal = UsageTrend.assess(samples: crossing, at: now, window: window) else {
                return XCTFail("A cutoff-straddling drop must not be labelled no consumption")
            }
            let outside = [sample(-window.lookback - 600, 60), sample(-window.lookback - 1, 55)] + inside
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: outside, at: now, window: window))
            XCTAssertEqual(forecast.rate, 0)
            XCTAssertNil(forecast.exhaustion)
        }
    }

    func testLongGapStraddlingCutoffCannotBeReportedAsZeroConsumption() {
        let before = UUID(), after = UUID(), reset = now.addingTimeInterval(86400)
        for window in [UsageTrendWindow.eightHours, .day] {
            let start = window == .day ? -20 * 3600.0 : -6 * 3600.0
            let predecessor = UsageTrendSample(date: now.addingTimeInterval(-window.lookback - 1),
                remaining: 60, reset: reset, segment: before)
            let inside = stride(from: start, through: 0, by: 300).map { offset in
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 55, reset: reset, segment: after)
            }
            guard case .insufficientSignal = UsageTrend.assess(samples: [predecessor] + inside, at: now, window: window) else {
                return XCTFail("Missing boundary interpolation must not turn an uncertain drop into no consumption")
            }
        }
    }

    func testConfirmedHourlyDropJustInsideCutoffStillGetsCoarseEstimate() throws {
        let segment = UUID(), reset = now.addingTimeInterval(86400)
        for firstOffset in [-3600.0, -3599] {
            func sample(_ offset: Double, _ remaining: Double) -> UsageTrendSample {
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                                 reset: reset, segment: segment)
            }
            let samples = [sample(firstOffset, 60), sample(firstOffset + 1, 59)]
                + stride(from: firstOffset + 300, through: -1, by: 300).map { sample($0, 59) }
                + [sample(0, 59)]
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now))
            XCTAssertEqual(forecast.rate * 3600, 3600 / -firstOffset, accuracy: 0.000001)
        }
    }

    func testBoundaryInterpolationCannotSupplyMinimumNetConsumption() {
        let segment = UUID()
        func sample(_ offset: Double, _ remaining: Double) -> UsageTrendSample {
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        var inside = stride(from: -3301.0, through: -1, by: 300).map {
            sample($0, 80 - 0.9 * ($0 + 3301) / 3301)
        }
        inside.append(sample(0, 79.1))
        // Interpolation at -3600 adds almost 1pp, but actual in-window readings lost only 0.9pp.
        for readings in [inside, [sample(-3601, 81)] + inside] {
            guard case .insufficientSignal = UsageTrend.assess(samples: readings, at: now) else {
                return XCTFail("Only observed in-window consumption can meet the 1pp signal floor")
            }
        }
    }

    func testStrongInWindowSignalStillAllowsBoundaryInterpolation() throws {
        let segment = UUID()
        func sample(_ offset: Double) -> UsageTrendSample {
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 74 - offset / 600,
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        var inside = stride(from: -3599.0, through: -299, by: 300).map(sample)
        inside.append(sample(0))
        for readings in [inside, [sample(-3899)] + inside] {
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: readings, at: now))
            XCTAssertEqual(forecast.rate * 3600, 6, accuracy: 0.000001)
            XCTAssertEqual(forecast.anchor.remaining, 74)
        }
    }

    func testScenarioRangeUsesLongerAverageRatesInsteadOfQuantizationSpikes() throws {
        let segment = UUID()
        let samples = stride(from: -3600.0, through: 0, by: 30).map {
            UsageTrendSample(date: now.addingTimeInterval($0), remaining: 44 - floor(($0 + 3600) / 900),
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now))
        XCTAssertGreaterThan(forecast.slowRate * 3600, 0)
        XCTAssertLessThan(forecast.fastRate * 3600, 6)
    }

    func testMissingIntervalsAreNotInterpolatedEvenWithMatchingSegment() {
        let segment = UUID()
        let samples = stride(from: -3600.0, through: 0, by: 300).filter { $0 <= -2100 || $0 >= -600 }.map {
            UsageTrendSample(date: now.addingTimeInterval($0), remaining: 60 - $0 / 300,
                             reset: now.addingTimeInterval(9000), segment: segment)
        }
        guard case .insufficientCoverage = UsageTrend.assess(samples: samples, at: now) else {
            return XCTFail("A 25-minute gap must not be filled")
        }
    }

    func testLongWindowsUseBothSidesOfReadGapsAtRealElapsedTimes() throws {
        for window in [UsageTrendWindow.eightHours, .day] {
            let before = UUID(), after = UUID()
            let samples = stride(from: -window.lookback, through: 0, by: 300).filter {
                $0 <= -5 * 3600 || $0 >= -4 * 3600
            }.map { offset in
                UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 40 - offset / 1800,
                    reset: now.addingTimeInterval(86400), segment: offset <= -5 * 3600 ? before : after)
            }
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now, window: window))
            XCTAssertEqual(forecast.rate * 3600, 2, accuracy: 0.000001)
            XCTAssertEqual(forecast.slowRate * 3600, 2, accuracy: 0.000001)
            XCTAssertEqual(forecast.fastRate * 3600, 2, accuracy: 0.000001)
            XCTAssertEqual(Set(samples.map(\.segment)).count, 2)
        }
    }

    func testDayForecastRequiresTwoThirdsActualCoverageNotJustGridEndpoints() throws {
        let before = UUID(), after = UUID()
        let samples = stride(from: -86400.0, through: 0, by: 300).filter {
            $0 <= -16 * 3600 || $0 >= -8 * 3600
        }.map { offset in
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 40 - offset / 1800,
                reset: now.addingTimeInterval(86400), segment: offset <= -16 * 3600 ? before : after)
        }
        XCTAssertNotNil(UsageTrend.forecast(samples: samples, at: now, window: .day))
        let lessCoverage = samples.filter { $0.date != now.addingTimeInterval(-8 * 3600) }
        guard case .insufficientCoverage = UsageTrend.assess(samples: lessCoverage, at: now, window: .day) else {
            return XCTFail("More than eight hours without observations must fail coverage")
        }
        let hourlyOnly = stride(from: -86400.0, through: 0, by: 3600).map { offset in
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 40 - offset / 1800,
                reset: now.addingTimeInterval(86400), segment: before)
        }
        guard case .insufficientCoverage = UsageTrend.assess(samples: hourlyOnly, at: now, window: .day) else {
            return XCTFail("Exact hourly grid points do not establish continuous observed coverage")
        }
    }

    func testUnobservedGapDropsCannotSupplyConsumptionEvidence() {
        let before = UUID(), after = UUID()
        let samples = stride(from: -86400.0, through: 0, by: 300).filter {
            $0 <= -12 * 3600 || $0 >= -11 * 3600
        }.map { offset -> UsageTrendSample in
            let older = offset <= -43200
            let remaining: Double = older ? 70 : 60
            return UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                reset: now.addingTimeInterval(86400), segment: older ? before : after)
        }
        guard case .insufficientSignal = UsageTrend.assess(samples: samples, at: now, window: .day) else {
            return XCTFail("A drop during an unobserved gap is not measured consumption signal")
        }
    }

    func testRecoveryDeadlineChangeAndUnexplainedSegmentsStillBlockPooling() {
        let before = UUID(), after = UUID(), reset = now.addingTimeInterval(86400)
        for boundary in ["recovery", "deadline", "unexplained"] {
            let samples = stride(from: -86400.0, through: 0, by: 300).filter {
                boundary == "unexplained" || $0 <= -9 * 3600 || $0 >= -8 * 3600
            }.map { offset in
                let older = offset <= -9 * 3600
                let remaining = 40 - offset / 1800 - (older && boundary == "recovery" ? 20 : 0)
                return UsageTrendSample(date: now.addingTimeInterval(offset), remaining: remaining,
                    reset: older && boundary == "deadline" ? reset.addingTimeInterval(-61) : reset,
                    segment: older ? before : after)
            }
            guard case .insufficientCoverage = UsageTrend.assess(samples: samples, at: now, window: .day) else {
                return XCTFail("Must not pool across \(boundary)")
            }
        }
    }

    func testLegacySecondScaleDeadlineJitterDoesNotHideDayHistory() throws {
        let reset = now.addingTimeInterval(86400)
        let samples = stride(from: -86400.0, through: 0, by: 300).enumerated().map { index, offset in
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 40 - offset / 1800,
                reset: reset.addingTimeInterval(Double(index % 2)), segment: UUID())
        }
        let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: now, window: .day))
        XCTAssertEqual(forecast.rate * 3600, 2, accuracy: 0.000001)
    }

    func testResetJitterPreservesCanonicalDeadlineAndForecast() throws {
        try withStore { store, _ in
            let reset = now.addingTimeInterval(9000)
            var history: [String: [UsageTrendSample]] = [:]
            for step in 0...12 {
                history = try store.record(account: "a", windows: [window(10 + Double(step),
                    reset: reset.addingTimeInterval(Double([0, 2, -2][step % 3])))], at: now.addingTimeInterval(Double(step * 300)))
            }
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(Set(samples.map(\.segment)).count, 1)
            XCTAssertEqual(Set(samples.map(\.reset)), [reset])
            XCTAssertNotNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(3600)))
            let changed = try store.record(account: "a", windows: [window(23, reset: reset.addingTimeInterval(61))],
                                           at: now.addingTimeInterval(3900))
            XCTAssertNotEqual(changed["codex.primary"]?.last?.segment, samples.last?.segment)
        }
    }

    func testResetToleranceCannotAccumulateDriftOrKeepAnExpiredDeadline() throws {
        try withStore { store, _ in
            let reset = now.addingTimeInterval(9000)
            _ = try store.record(account: "a", windows: [window(10, reset: reset)], at: now)
            _ = try store.record(account: "a", windows: [window(11, reset: reset.addingTimeInterval(40))], at: now.addingTimeInterval(300))
            let history = try store.record(account: "a", windows: [window(12, reset: reset.addingTimeInterval(80))], at: now.addingTimeInterval(600))
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples[0].segment, samples[1].segment)
            XCTAssertNotEqual(samples[1].segment, samples[2].segment)
        }
        try withStore { store, _ in
            _ = try store.record(account: "a", windows: [window(10, reset: now.addingTimeInterval(600))], at: now)
            let history = try store.record(account: "a", windows: [window(10, reset: now.addingTimeInterval(602))], at: now.addingTimeInterval(600))
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertNotEqual(samples[0].segment, samples[1].segment)
            XCTAssertGreaterThan(samples[1].reset, samples[1].date)
        }
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
            for seconds in stride(from: 0.0, through: 3600, by: 300) {
                let used = 10 + seconds / 600
                _ = try store.record(account: "a", windows: [window(used)], at: now.addingTimeInterval(seconds))
            }
            let date = now.addingTimeInterval(3605)
            let history = try store.record(account: "a", windows: [window(16.1)], at: date)
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples.count, 13)
            let forecast = try XCTUnwrap(UsageTrend.forecast(samples: samples, at: date))
            XCTAssertEqual(forecast.anchor.remaining, 83.9, accuracy: 0.0001)
            XCTAssertEqual(forecast.anchor.date, date)
            let restored = try UsageTrendStore(directory: directory).record(account: "a", windows: [], at: date)
            XCTAssertEqual(restored["codex.primary"], samples)
        }
    }

    func testFrequentChangedReadingsDoNotStarveSampling() throws {
        try withStore { store, _ in
            var history: [String: [UsageTrendSample]] = [:]
            for seconds in stride(from: 0, through: 3600, by: 5) {
                history = try store.record(account: "a", windows: [window(10 + Double(seconds) / 120)],
                                           at: now.addingTimeInterval(Double(seconds)))
            }
            let samples = try XCTUnwrap(history["codex.primary"])
            XCTAssertEqual(samples.count, 121)
            XCTAssertEqual(Set(samples.map { floor($0.date.timeIntervalSince1970 / 30) }).count, samples.count)
            XCTAssertEqual(samples.last?.remaining, 60)
            XCTAssertNotNil(UsageTrend.forecast(samples: samples, at: now.addingTimeInterval(3600)))
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

    func testLayeredRetentionKeepsEightDaysAndExactPredictionInputs() throws {
        let segment = UUID(), reset = now.addingTimeInterval(86400)
        let original = stride(from: -9 * 86400.0, through: 0, by: 30).map { offset in
            UsageTrendSample(date: now.addingTimeInterval(offset), remaining: 40 + min(floor(-offset / 300) * 0.2, 50),
                             reset: reset, segment: segment)
        }
        let retained = UsageTrendStore.retainedSamples(original, at: now)
        XCTAssertEqual(retained.first, original.first { $0.date > now.addingTimeInterval(-8 * 86400) })
        XCTAssertGreaterThan(retained.count, 4096)
        XCTAssertLessThan(retained.count, original.count / 2)
        let detailedSince = now.addingTimeInterval(-25 * 3600)
        XCTAssertEqual(retained.filter { $0.date >= detailedSince }, original.filter { $0.date >= detailedSince })
        XCTAssertEqual(UsageTrendStore.retainedSamples(retained, at: now), retained)
        for window in UsageTrendWindow.allCases {
            let before = try XCTUnwrap(UsageTrend.forecast(samples: original, at: now, window: window))
            let after = try XCTUnwrap(UsageTrend.forecast(samples: retained, at: now, window: window))
            XCTAssertEqual(before.rate, after.rate)
            XCTAssertEqual(before.slowRate, after.slowRate)
            XCTAssertEqual(before.fastRate, after.fastRate)
            XCTAssertEqual(before.anchor, after.anchor)
        }
        try withStore { store, directory in
            _ = try store.record(account: "a", windows: [window(60, reset: reset)], at: now)
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            try JSONEncoder().encode(["codex.primary": original]).write(to: file)
            let loaded = try store.record(account: "a", windows: [], at: now)
            XCTAssertEqual(loaded["codex.primary"], retained)
            let appended = try store.record(account: "a", windows: [window(60, reset: reset)], at: now.addingTimeInterval(30))
            XCTAssertLessThan(try XCTUnwrap(appended["codex.primary"]?.first).date, now.addingTimeInterval(-7 * 86400))
            XCTAssertGreaterThan(appended["codex.primary"]?.count ?? 0, 4096)
        }
    }

    func testOlderHistoryKeepsChangesAndSegmentEdgesWithinOneBucket() {
        let first = UUID(), second = UUID()
        let base = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300 - 2 * 86400)
        let values: [(Double, UUID)] = [(80, first), (80, first), (79, first), (79, first),
                                        (79, second), (79, second), (79, second), (78, second)]
        let samples = values.enumerated().map { index, value in
            UsageTrendSample(date: base.addingTimeInterval(Double(index) * 30), remaining: value.0,
                             reset: now.addingTimeInterval(86400), segment: value.1)
        }
        let retained = UsageTrendStore.retainedSamples(samples, at: now)
        XCTAssertEqual(retained, [0, 1, 2, 3, 4, 6, 7].map { samples[$0] })
        XCTAssertEqual(UsageTrendStore.retainedSamples(retained, at: now), retained)
        XCTAssertEqual(UsageTrend.chartSamples(retained), UsageTrend.chartSamples(samples))
    }

    func testOlderFlatHistoryKeepsFixedFiveMinuteRepresentatives() {
        let segment = UUID()
        let base = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300 - 2 * 86400)
        let samples = (0..<40).map { index in
            UsageTrendSample(date: base.addingTimeInterval(Double(index) * 30), remaining: 80,
                             reset: now.addingTimeInterval(86400), segment: segment)
        }
        XCTAssertEqual(UsageTrendStore.retainedSamples(samples, at: now), [0, 9, 19, 29, 39].map { samples[$0] })
        XCTAssertEqual(UsageTrendStore.retainedSamples([], at: now), [])
        XCTAssertEqual(UsageTrendStore.retainedSamples([samples[0]], at: now), [samples[0]])
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
