import XCTest
@testable import WatcherCore

final class LocalizationTests: XCTestCase {
    func testExplicitLocalesAndRegionalLanguageMatching() {
        XCTAssertEqual(L10n.text("今日到期", locale: Locale(identifier: "en_GB")), "Expires today")
        XCTAssertEqual(L10n.text("今日到期", locale: Locale(identifier: "zh_CN")), "今日到期")
        XCTAssertEqual(L10n.text("仪表盘", locale: Locale(identifier: "en_US")), "Gauge")
        XCTAssertEqual(L10n.text("重置已完成。", locale: Locale(identifier: "en_US")), "Reset completed.")
    }

    func testCreditCountUsesPluralRulesAndPreservesNumericType() {
        let english = Locale(identifier: "en_US")
        let chinese = Locale(identifier: "zh_CN")
        for (count, expected) in [(0, "0 credits available"), (1, "1 credit available"), (2, "2 credits available")] {
            XCTAssertEqual(L10n.text("\(count) 张可用", locale: english), expected)
        }
        XCTAssertEqual(L10n.text("\(2) 张可用", locale: chinese), "2 张可用")
    }

    func testErrorCodeIsAnIdentifierWithoutDigitGrouping() {
        let message = L10n.text("Codex 请求失败（\(String(-32000))），请检查登录状态或 CLI 版本。", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(message, "Codex request failed (-32000). Check your sign-in status or CLI version.")
    }
}
