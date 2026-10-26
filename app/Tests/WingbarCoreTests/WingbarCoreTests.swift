import CoreGraphics
import XCTest
@testable import WingbarCore

/// Numbers from a 14" MacBook Pro at 1800×1169 pt (measured in the Phase 0 spike).
let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
let notch = NotchGeometry(
    screenFrame: screen,
    leftArea: CGRect(x: 0, y: 1131, width: 790, height: 38),
    rightArea: CGRect(x: 1010, y: 1131, width: 790, height: 38))

final class NotchGeometryTests: XCTestCase {
    func testNotchSpanAndWings() {
        XCTAssertEqual(notch.notchSpan, 790...1010)
        XCTAssertEqual(notch.notchWidth, 220)
        XCTAssertEqual(notch.rightWing, 1010...1800)
        XCTAssertEqual(notch.leftWing, 0...790)
    }

    func testNoNotchOnExternalDisplay() {
        let external = NotchGeometry(screenFrame: CGRect(x: 1800, y: 0, width: 2560, height: 1440), leftArea: nil, rightArea: nil)
        XCTAssertFalse(external.hasNotch)
        XCTAssertNil(external.leftWing)
        XCTAssertFalse(external.isUnderNotch(CGRect(x: 2000, y: 0, width: 30, height: 39)))
    }

    func testUnderNotchIncludesPartialOverlap() {
        XCTAssertTrue(notch.isUnderNotch(CGRect(x: 930, y: 0, width: 38, height: 39)))
        XCTAssertTrue(notch.isUnderNotch(CGRect(x: 1000, y: 0, width: 38, height: 39)))
        XCTAssertFalse(notch.isUnderNotch(CGRect(x: 1010, y: 0, width: 38, height: 39)))
        XCTAssertFalse(notch.isUnderNotch(CGRect(x: 700, y: 0, width: 90, height: 39)))
    }
}

final class ItemMatcherTests: XCTestCase {
    func extra(_ x: CGFloat, _ w: CGFloat, _ app: String, y: CGFloat = 7, id: String? = nil) -> StatusExtra {
        StatusExtra(frame: CGRect(x: x, y: y, width: w, height: 24), pid: 1, appName: app, bundleID: "b.\(app)", title: "", identifier: id)
    }

    func testMatchesByContainmentAndClassifies() {
        let windows = [
            StatusWindow(windowID: 1, frame: CGRect(x: 928, y: 0, width: 38, height: 39), isOnScreen: false),
            StatusWindow(windowID: 2, frame: CGRect(x: 1116, y: 0, width: 36, height: 39), isOnScreen: true),
            StatusWindow(windowID: 3, frame: CGRect(x: 1400, y: 0, width: 30, height: 39), isOnScreen: false),
        ]
        // AX frames are inset icons, a few points right of each window's left edge.
        let extras = [extra(1117, 38, "PiP"), extra(937, 24, "Ledge"), extra(1405, 20, "Menus"), extra(-1, 34, "Cursor", y: 1168)]
        let items = ItemMatcher.match(windows: windows, extras: extras, notch: notch)

        XCTAssertEqual(items.map(\.appName), ["Ledge", "PiP", "Menus", "Cursor"])
        XCTAssertEqual(items.map(\.placement), [.underNotch, .visible, .offScreen, .parked])
        XCTAssertNil(items[3].windowID)
        XCTAssertEqual(items[0].extraIndex, 1)
    }

    func testDuplicateItemsGetUniqueIDsAndStaleWindowsAreDropped() {
        let windows = [
            StatusWindow(windowID: 1, frame: CGRect(x: 1100, y: 0, width: 30, height: 39), isOnScreen: true),
            StatusWindow(windowID: 2, frame: CGRect(x: 1200, y: 0, width: 30, height: 39), isOnScreen: true),
            StatusWindow(windowID: 3, frame: CGRect(x: 1300, y: 0, width: 30, height: 39), isOnScreen: true),
        ]
        let extras = [extra(1205, 20, "Stats"), extra(1305, 20, "Stats")]
        let items = ItemMatcher.match(windows: windows, extras: extras, notch: notch)
        XCTAssertEqual(items.map(\.appName), ["Stats", "Stats"])
        XCTAssertEqual(items.map(\.id), ["b.Stats|", "b.Stats|#1"])
    }

    func testWithoutAccessibilityDrawnWindowsAreUnknown() {
        let windows = [
            StatusWindow(windowID: 1, frame: CGRect(x: 1100, y: 0, width: 30, height: 39), isOnScreen: true),
            StatusWindow(windowID: 2, frame: CGRect(x: 950, y: 0, width: 30, height: 39), isOnScreen: false),
        ]
        let items = ItemMatcher.match(windows: windows, extras: [], notch: notch)
        XCTAssertEqual(items.map(\.appName), ["Unknown"])
        XCTAssertEqual(items[0].windowID, 1)
    }

    /// Right after a collapse the window list still has old frames, but AX has the
    /// real (off-screen) ones. Items must keep their names and read as off screen.
    func testStaleWindowFramesDoNotLoseItems() {
        let windows = [
            StatusWindow(windowID: 1, frame: CGRect(x: 1146, y: 0, width: 33, height: 39), isOnScreen: true),
            StatusWindow(windowID: 2, frame: CGRect(x: 1639, y: 0, width: 163, height: 39), isOnScreen: true),
        ]
        let extras = [extra(-3957, 34, "TypePilot"), extra(1647, 146, "Clock")]
        let items = ItemMatcher.match(windows: windows, extras: extras, notch: notch)
        XCTAssertEqual(items.map(\.appName), ["TypePilot", "Clock"])
        XCTAssertEqual(items[0].placement, .offScreen)
        XCTAssertEqual(items[0].frame.minX, -3957)
        XCTAssertEqual(items[1].windowID, 2)
    }

    func testIDIgnoresLiveTitles() {
        let a = StatusExtra(frame: CGRect(x: 1100, y: 7, width: 40, height: 24), pid: 9, appName: "Switcher", bundleID: "b.sw", title: "47%", identifier: nil)
        let b = StatusExtra(frame: CGRect(x: 1100, y: 7, width: 40, height: 24), pid: 9, appName: "Switcher", bundleID: "b.sw", title: "48%", identifier: nil)
        XCTAssertEqual(ItemMatcher.match(windows: [], extras: [a], notch: notch).first?.id,
                       ItemMatcher.match(windows: [], extras: [b], notch: notch).first?.id)
    }

    func testLaggingWindowFramesStillPairUp() {
        // Both icons moved 40 pt right; their windows still report the old spots.
        let windows = [
            StatusWindow(windowID: 1, frame: CGRect(x: 1000, y: 0, width: 36, height: 39), isOnScreen: true),
            StatusWindow(windowID: 2, frame: CGRect(x: 1036, y: 0, width: 99, height: 39), isOnScreen: true),
        ]
        let extras = [extra(1044, 28, "PiP"), extra(1080, 90, "Stats")]
        let items = ItemMatcher.match(windows: windows, extras: extras, notch: notch)
        XCTAssertEqual(items.map(\.appName), ["PiP", "Stats"])
        XCTAssertEqual(items.map(\.windowID), [1, 2])
    }

    func testAppleItemsUseTheirTitle() {
        let siri = StatusExtra(frame: CGRect(x: 1573, y: 7, width: 17, height: 24), pid: 663, appName: "SystemUIServer", bundleID: "com.apple.systemuiserver", title: "Siri", identifier: nil)
        let items = ItemMatcher.match(windows: [], extras: [siri, extra(1400, 20, "PiP")], notch: notch)
        XCTAssertEqual(items.map(\.displayName), ["PiP", "Siri"])
    }

    func testZeroWidthExtrasAreIgnored() {
        let items = ItemMatcher.match(windows: [], extras: [extra(0, 0, "Control Centre")], notch: notch)
        XCTAssertTrue(items.isEmpty)
    }
}

final class SectionTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(MenuBarSection.classify(itemMinX: 1300, hiddenDividerMaxX: 1200, alwaysHiddenDividerMaxX: 1100), .visible)
        XCTAssertEqual(MenuBarSection.classify(itemMinX: 1150, hiddenDividerMaxX: 1200, alwaysHiddenDividerMaxX: 1100), .hidden)
        XCTAssertEqual(MenuBarSection.classify(itemMinX: 900, hiddenDividerMaxX: 1200, alwaysHiddenDividerMaxX: 1100), .alwaysHidden)
        XCTAssertEqual(MenuBarSection.classify(itemMinX: 900, hiddenDividerMaxX: nil, alwaysHiddenDividerMaxX: nil), .visible)
    }

    func testDividerLengths() {
        var state = SectionState()
        XCTAssertEqual(state.length(of: .hidden), SectionState.collapsedLength)
        XCTAssertEqual(state.length(of: .alwaysHidden), SectionState.collapsedLength)

        state.toggle(includingAlwaysHidden: false)
        XCTAssertNil(state.length(of: .hidden))
        XCTAssertEqual(state.length(of: .alwaysHidden), SectionState.collapsedLength)

        state.toggle(includingAlwaysHidden: true)
        XCTAssertNil(state.length(of: .alwaysHidden))

        state.toggle(includingAlwaysHidden: false)
        XCTAssertEqual(state, SectionState())
    }

    func testOptionClickFromCollapsedShowsEverything() {
        var state = SectionState()
        state.toggle(includingAlwaysHidden: true)
        XCTAssertEqual(state, SectionState(showsHidden: true, showsAlwaysHidden: true))
        state.collapse()
        XCTAssertEqual(state, SectionState())
    }
}

