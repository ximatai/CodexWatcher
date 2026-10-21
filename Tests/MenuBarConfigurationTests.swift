import AppKit
import XCTest
@testable import WatcherCore

final class MenuBarConfigurationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_000_000)
    private var quota: QuotaWindow {
        QuotaWindow(usedPercent: 40, windowDurationMins: 100,
                    resetsAt: date.addingTimeInterval(75 * 60).timeIntervalSince1970)
    }

    func testStaleDataHidesDeviationUntilFreshDataArrives() {
        let config = MenuBarConfiguration(showTimeProgress: true, showDeviation: true)
        let format = PresentationFormat(locale: Locale(identifier: "en_US"))
        // Retain last known usage and independently calculable time progress, as the panel does.
        XCTAssertEqual(config.title(quota: quota, at: date, format: format, isStale: true),
                       "40% · 25% · —pp")
        XCTAssertEqual(config.title(quota: quota, at: date.addingTimeInterval(600), format: format, isStale: true),
                       "40% · 35% · —pp")
        let refreshed = QuotaWindow(usedPercent: 60, windowDurationMins: 100, resetsAt: quota.resetsAt)
        XCTAssertEqual(config.title(quota: refreshed, at: date.addingTimeInterval(600), format: format, isStale: false),
                       "60% · 35% · +25.0pp")
        XCTAssertEqual(config.title(quota: nil, at: date, format: format, isStale: true), "—% · —% · —pp")
    }

    func testIndependentTextOptionsAndMissingData() {
        let format = PresentationFormat(locale: Locale(identifier: "en_US"))
        var config = MenuBarConfiguration()
        XCTAssertEqual(config.title(quota: quota, at: date, format: format), "40%")
        config.showUsage = false
        config.showTimeProgress = true
        XCTAssertEqual(config.title(quota: quota, at: date, format: format), "25%")
        config.showTimeProgress = false
        config.showDeviation = true
        XCTAssertEqual(config.title(quota: quota, at: date, format: format), "+15.0pp")
        config.showUsage = true
        config.showTimeProgress = true
        XCTAssertEqual(config.title(quota: quota, at: date, format: format), "40% · 25% · +15.0pp")
        XCTAssertEqual(config.title(quota: nil, at: date, format: format), "—% · —% · —pp")
        XCTAssertEqual(config.title(quota: quota, at: date.addingTimeInterval(75 * 60), format: format),
                       "40% · —% · —pp")
    }

    @MainActor
    func testEveryIconAndTextCombinationKeepsVisibleMenuAccess() throws {
        for icon in MenuBarIcon.allCases {
            for mask in 0..<8 {
                let config = MenuBarConfiguration(icon: icon, showUsage: mask & 1 != 0,
                                                  showTimeProgress: mask & 2 != 0, showDeviation: mask & 4 != 0)
                let title = config.title(quota: quota, at: date)
                XCTAssertTrue(config.effectiveSymbol != nil || !title.isEmpty)
                let image = MenuBarLabelRenderer.image(title: title, symbolName: config.effectiveSymbol)
                XCTAssertTrue(image.isTemplate)
                XCTAssertGreaterThan(image.size.width, 1)
                XCTAssertEqual(image.representations.count, 2)
                for rep in image.representations {
                    let bitmap = try XCTUnwrap(rep as? NSBitmapImageRep)
                    let pixels = try XCTUnwrap(bitmap.bitmapData)
                    XCTAssertTrue((0..<bitmap.pixelsHigh).contains { y in
                        (0..<bitmap.pixelsWide).contains { x in
                            pixels[y * bitmap.bytesPerRow + x * 4 + 3] > 64
                        }
                    }, "Empty label: \(icon), mask \(mask)")
                }
            }
        }
        let text = MenuBarLabelRenderer.image(title: "40%", symbolName: nil)
        let combined = MenuBarLabelRenderer.image(title: "40%")
        XCTAssertEqual(combined.size.width - text.size.width,
                       MenuBarLabelRenderer.iconWidth + MenuBarLabelRenderer.spacing)
        XCTAssertEqual(MenuBarLabelRenderer.image(title: "").size.width, MenuBarLabelRenderer.iconWidth)
    }
}
