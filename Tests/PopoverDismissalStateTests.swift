import Foundation
import XCTest
@testable import WatcherCore

final class PopoverDismissalStateTests: XCTestCase {
    func testOutsideInteractionClosesWithoutMenu() {
        var state = PopoverDismissalState()
        XCTAssertTrue(state.outsideInteraction())
    }

    func testMenuCanOpenAndCancelWithoutClosingPanel() {
        var state = PopoverDismissalState()
        let menu = NSObject()
        state.menuBegan(menu)
        XCTAssertFalse(state.menuEnded(menu))
        XCTAssertTrue(state.outsideInteraction(), "The next external click must still close the panel")
    }

    func testExternalInteractionDuringMenuIsHandledAfterMenuCloses() {
        var state = PopoverDismissalState()
        let menu = NSObject()
        state.menuBegan(menu)
        XCTAssertFalse(state.outsideInteraction())
        XCTAssertTrue(state.menuEnded(menu), "App switches and outside clicks must not be lost")
        XCTAssertFalse(state.menuEnded(menu), "The pending close must only be delivered once")
    }

    func testNestedMenuDoesNotCloseUntilLastMenuEnds() {
        var state = PopoverDismissalState()
        let parent = NSObject(), child = NSObject()
        state.menuBegan(parent)
        state.menuBegan(child)
        XCTAssertFalse(state.outsideInteraction())
        XCTAssertFalse(state.menuEnded(child))
        XCTAssertTrue(state.menuEnded(parent))
    }

    func testClosingAndReopeningClearsPreviousPendingInteraction() {
        var state = PopoverDismissalState()
        let old = NSObject(), new = NSObject()
        state.menuBegan(old)
        XCTAssertFalse(state.outsideInteraction())
        state.reset()
        state.menuBegan(new)
        XCTAssertFalse(state.menuEnded(old))
        XCTAssertFalse(state.menuEnded(new))
        XCTAssertTrue(state.outsideInteraction())
    }
}
