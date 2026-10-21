import XCTest
@testable import WatcherCore

final class PresentationFormatTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testCreditExpiryUsesLocalDatesAndOmitsExpiredOrDistantCards() throws {
        let format = PresentationFormat(locale: Locale(identifier: "zh_CN"), timeZone: shanghai)
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-10-21T23:30:00+08:00"))
        func date(_ value: String) throws -> Date { try XCTUnwrap(parser.date(from: value)) }
        XCTAssertEqual(format.creditExpiryUrgency(try date("2026-10-21T23:59:00+08:00"), at: now), .today)
        // Only 31 minutes away, but across local midnight: tomorrow rather than today.
        XCTAssertEqual(format.creditExpiryUrgency(try date("2026-10-22T00:01:00+08:00"), at: now), .tomorrow)
        XCTAssertEqual(format.creditExpiryUrgency(try date("2026-10-23T12:00:00+08:00"), at: now), .withinThreeDays)
        XCTAssertEqual(format.creditExpiryUrgency(try date("2026-10-24T23:30:00+08:00"), at: now), .withinThreeDays)
        XCTAssertNil(format.creditExpiryUrgency(try date("2026-10-24T23:30:01+08:00"), at: now))
        XCTAssertNil(format.creditExpiryUrgency(now, at: now))
        XCTAssertNil(format.creditExpiryUrgency(now.addingTimeInterval(-1), at: now))
        XCTAssertNil(format.creditExpiryUrgency(nil, at: now))

        let utc = PresentationFormat(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(utc.creditExpiryUrgency(try date("2026-10-22T00:01:00+08:00"), at: now), .today)
    }

    func testThreeDayExpiryCutoffUsesCalendarDaysAcrossDaylightSaving() throws {
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-10-30T12:00:00-07:00"))
        let expiry = try XCTUnwrap(parser.date(from: "2026-11-02T12:00:00-08:00"))
        let format = PresentationFormat(locale: Locale(identifier: "en_US"),
                                        timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(format.creditExpiryUrgency(expiry, at: now), .withinThreeDays)
        XCTAssertNil(format.creditExpiryUrgency(expiry.addingTimeInterval(1), at: now))
    }

    func testChineseDatesUseLocalOrderAndExplicitTimeZoneInConfirmation() {
        let format = PresentationFormat(locale: Locale(identifier: "zh_CN"), timeZone: shanghai)
        let date = Date(timeIntervalSince1970: 1793082734)
        let normal = format.date(date)
        XCTAssertTrue(normal.contains("2026"))
        XCTAssertTrue(normal.contains("10月"))
        XCTAssertTrue(normal.contains("27"))
        XCTAssertFalse(normal.contains("Oct"))
        let precise = format.date(date, precise: true)
        XCTAssertTrue(precise.contains("14"))
        XCTAssertTrue(precise.contains("32"))
        XCTAssertNotEqual(precise, format.date(date.addingTimeInterval(1), precise: true))
        XCTAssertTrue(precise.contains("GMT+8") || precise.contains("CST") || precise.contains("中国"))
    }

    func testNumberAndPercentUseRegionalSeparators() {
        let format = PresentationFormat(locale: Locale(identifier: "de_DE"), timeZone: shanghai)
        XCTAssertTrue(format.percent(24.5, decimals: 1).contains("24,5"))
        XCTAssertEqual(format.number(1234.5, decimals: 1), "1.234,5")
        XCTAssertTrue(format.deviation(10.9).contains("+10,9"))
        XCTAssertTrue(format.deviation(-10.9).contains("-10,9"))
    }

    func testDateUsesSelectedTimeZone() {
        let date = Date(timeIntervalSince1970: 1793082734)
        let utc = PresentationFormat(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let china = PresentationFormat(locale: Locale(identifier: "en_GB"), timeZone: shanghai)
        XCTAssertTrue(utc.date(date, timeOnly: true).contains("06:32"))
        XCTAssertTrue(china.date(date, timeOnly: true).contains("14:32"))
    }

    func testKnownCardLabelsAreLocalizedAndUnknownTitlesSurvive() {
        let format = PresentationFormat(locale: Locale(identifier: "zh_CN"), timeZone: shanghai)
        XCTAssertEqual(format.creditTitle("Full reset"), "完整额度重置卡")
        XCTAssertEqual(format.creditTitle(nil), "额度重置卡")
        XCTAssertEqual(format.creditTitle("Special offer"), "Special offer")
        XCTAssertTrue(format.deviation(8.4).contains("个百分点"))
    }

    func testDurationDoesNotTruncateFractionalHoursOrClaimZeroMinutes() {
        let format = PresentationFormat(locale: Locale(identifier: "zh_CN"), timeZone: shanghai)
        let quota = format.quotaDuration(90)
        XCTAssertTrue(quota.contains("1") && quota.contains("30"))
        XCTAssertEqual(format.duration(30), "不足 1 分钟")
        XCTAssertEqual(format.quotaDuration(nil), "额度窗口")
    }
}
