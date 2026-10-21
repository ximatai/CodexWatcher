import AppKit
import XCTest
@testable import WatcherCore

final class AppAppearanceTests: XCTestCase {
    @MainActor
    func testReturningFromEitherManualModeClearsAppAndWindowOverrides() {
        let app = NSApplication.shared
        let previous = app.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            app.appearance = previous
        }
        for mode in [AppAppearance.light, .dark] {
            window.appearance = NSAppearance(named: .darkAqua)
            mode.apply(to: app)
            XCTAssertNil(window.appearance)
            XCTAssertEqual(app.appearance?.name, mode.nativeAppearance?.name)
            AppAppearance.system.apply(to: app)
            XCTAssertNil(app.appearance, "System mode must remove the override, not copy the current system color.")
            XCTAssertNil(window.appearance)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                           app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
        }
    }
}
