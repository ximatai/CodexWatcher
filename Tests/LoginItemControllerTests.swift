import ServiceManagement
import XCTest
@testable import WatcherCore

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testExternalChangesAreReadBeforeUpdatingAndApprovalCanBeCancelled() throws {
        var systemStatus = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let controller = LoginItemController(readStatus: { systemStatus }, register: {
            registrations += 1
            systemStatus = .requiresApproval
        }, unregister: {
            removals += 1
            systemStatus = .notRegistered
        })
        XCTAssertFalse(controller.isRequested)
        try controller.setEnabled(true)
        XCTAssertTrue(controller.needsApproval)
        XCTAssertTrue(controller.title.contains("待系统允许"))
        try controller.setEnabled(true)
        XCTAssertEqual(registrations, 1, "Do not re-register a pending approval")
        try controller.setEnabled(false)
        XCTAssertEqual(removals, 1)
        XCTAssertFalse(controller.isRequested)
        systemStatus = .enabled
        try controller.setEnabled(false)
        XCTAssertEqual(removals, 2, "Respect external changes instead of a cached toggle")
        XCTAssertFalse(controller.isRequested)
    }

    func testRegistrationAndUnregistrationFailuresPreserveSystemState() throws {
        var systemStatus = SMAppService.Status.notRegistered
        let controller = LoginItemController(readStatus: { systemStatus }, register: {
            throw NSError(domain: "FakeLoginItem", code: 1)
        }, unregister: {
            throw NSError(domain: "FakeLoginItem", code: 2)
        })
        XCTAssertThrowsError(try controller.setEnabled(true))
        XCTAssertFalse(controller.isRequested)
        systemStatus = .enabled
        XCTAssertThrowsError(try controller.setEnabled(false))
        XCTAssertTrue(controller.isRequested)
        systemStatus = .requiresApproval
        controller.refresh()
        XCTAssertTrue(controller.needsApproval)
        systemStatus = .notRegistered
        controller.refresh()
        XCTAssertFalse(controller.isRequested)
    }
}
