import AppKit
import XCTest
@testable import Ping_Island

@MainActor
final class NotchWindowControllerTests: XCTestCase {
    func testNotchPanelRemainsAvailableAcrossSpacesAndStationaryInMissionControl() {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testActiveSpaceChangeReordersWindowOutsideActiveSpace() {
        XCTAssertEqual(
            NotchWindowController.windowOrderAction(
                isVisible: true,
                isOnActiveSpace: false,
                recoverAfterSpaceChange: true
            ),
            .restoreOnActiveSpace
        )
    }

    func testActiveSpaceChangeDoesNotReorderWindowAlreadyOnActiveSpace() {
        XCTAssertEqual(
            NotchWindowController.windowOrderAction(
                isVisible: true,
                isOnActiveSpace: true,
                recoverAfterSpaceChange: true
            ),
            .none
        )
    }

    func testHiddenWindowUsesNormalFrontOrderingWithoutSpaceChange() {
        XCTAssertEqual(
            NotchWindowController.windowOrderAction(
                isVisible: false,
                isOnActiveSpace: true,
                recoverAfterSpaceChange: false
            ),
            .orderFront
        )
    }

    func testVisibleWindowIsNotReorderedWithoutSpaceChange() {
        XCTAssertEqual(
            NotchWindowController.windowOrderAction(
                isVisible: true,
                isOnActiveSpace: false,
                recoverAfterSpaceChange: false
            ),
            .none
        )
    }
}
