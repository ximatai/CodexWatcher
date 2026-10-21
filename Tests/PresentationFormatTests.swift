import XCTest
@testable import WatcherCore

final class PresentationFormatTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

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
