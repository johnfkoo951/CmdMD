import XCTest
@testable import CmdMD

/// Showing a pane in a window narrower than the split views' combined minimum
/// aborted the app (endless update-constraints loop). `PaneRoom.plan` decides
/// how to keep the layout satisfiable.
final class PaneRoomTests: XCTestCase {
    private typealias Panes = PaneRoom.Panes

    private let both = Panes(sidebar: true, inspector: true)
    private let inspectorOnly = Panes(sidebar: false, inspector: true)
    private let sidebarOnly = Panes(sidebar: true, inspector: false)
    private let none = Panes(sidebar: false, inspector: false)

    private func required(_ panes: Panes) -> CGFloat {
        PaneRoom.fallbackMinimum[panes] ?? 0
    }

    func testFitsAlreadyChangesNothing() {
        let plan = PaneRoom.plan(wanted: both, keep: .inspector, windowWidth: 1200, availableWidth: 1800, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: both, growTo: nil))
    }

    func testGrowsWindowWhenScreenHasRoom() {
        let plan = PaneRoom.plan(wanted: both, keep: .inspector, windowWidth: 760, availableWidth: 1800, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: both, growTo: 960))
    }

    func testClosesSidebarToKeepRequestedInspector() {
        let plan = PaneRoom.plan(wanted: both, keep: .inspector, windowWidth: 760, availableWidth: 800, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: inspectorOnly, growTo: nil))
    }

    func testClosesInspectorToKeepRequestedSidebar() {
        let plan = PaneRoom.plan(wanted: both, keep: .sidebar, windowWidth: 760, availableWidth: 800, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: sidebarOnly, growTo: nil))
    }

    func testFallsBackToNoPanesOnATinyScreen() {
        let plan = PaneRoom.plan(wanted: inspectorOnly, keep: .inspector, windowWidth: 500, availableWidth: 600, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: none, growTo: nil))
    }

    func testGrowsOnlyAsFarAsTheSmallerLayoutNeeds() {
        // Both panes need 960 but the screen offers 900: keep the inspector
        // alone, which still needs the window to grow from 600 to 710.
        let plan = PaneRoom.plan(wanted: both, keep: .inspector, windowWidth: 600, availableWidth: 900, required: required)
        XCTAssertEqual(plan, PaneRoom.Plan(panes: inspectorOnly, growTo: 710))
    }
}
