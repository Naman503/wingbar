import CoreGraphics
import Foundation
import XCTest
@testable import WingbarCore

final class WingLayoutTests: XCTestCase {
    func item(_ id: String, _ width: CGFloat, overflowOnly: Bool = false) -> WingEntry {
        WingEntry(kind: .item(id), width: width, overflowOnly: overflowOnly)
    }

    func testRegionSitsBetweenMenusAndNotch() {
        // ChatGPT's menus end around x 365; the notch starts at 790.
        XCTAssertEqual(WingLayout.region(notch: notch, appMenusMaxX: 365, gapAfterMenus: 16), 381...782)
        XCTAssertNil(WingLayout.region(notch: notch, appMenusMaxX: 780, gapAfterMenus: 16))
        let external = NotchGeometry(screenFrame: screen, leftArea: nil, rightArea: nil)
        XCTAssertNil(WingLayout.region(notch: external, appMenusMaxX: 100, gapAfterMenus: 16))
    }

    func testEverythingFitsPackedAgainstNotch() {
        let r = WingLayout.layout(entries: [item("a", 20), item("b", 30)], region: 400...782, spacing: 8, overflowButtonWidth: 24, alignment: .towardNotch)
        XCTAssertEqual(r.slots.map(\.x), [724, 752])
        XCTAssertEqual(r.slots.last.map { $0.x + $0.width }, 782)
        XCTAssertTrue(r.overflow.isEmpty)
    }

    func testAfterMenusAlignment() {
        let r = WingLayout.layout(entries: [item("a", 20), item("b", 30)], region: 400...782, spacing: 8, overflowButtonWidth: 24, alignment: .afterMenus)
        XCTAssertEqual(r.slots.map(\.x), [400, 428])
    }

    func testOverflowDropsLeftmostAndAddsButton() {
        // 100 pt of room: two 30 pt items + spacing + a 24 pt button fit, the third doesn't.
        let entries = [item("a", 30), item("b", 30), item("c", 30)]
        let r = WingLayout.layout(entries: entries, region: 0...100, spacing: 8, overflowButtonWidth: 24, alignment: .towardNotch)
        XCTAssertEqual(r.slots.map(\.kind), [.overflow, .entry(.item("b")), .entry(.item("c"))])
        XCTAssertEqual(r.overflow, [.item("a")])
        XCTAssertLessThanOrEqual(r.slots.first!.x, r.slots.last!.x)
        XCTAssertGreaterThanOrEqual(r.slots.first!.x, 0)
    }

    func testOverflowOnlyItemsForceTheButton() {
        let r = WingLayout.layout(entries: [item("a", 20), item("b", 20, overflowOnly: true)], region: 0...300, spacing: 8, overflowButtonWidth: 24, alignment: .towardNotch)
        XCTAssertEqual(r.slots.map(\.kind), [.overflow, .entry(.item("a"))])
        XCTAssertEqual(r.overflow, [.item("b")])
    }

    func testNoRegionSendsEverythingToOverflow() {
        let r = WingLayout.layout(entries: [item("a", 20)], region: nil, spacing: 8, overflowButtonWidth: 24, alignment: .towardNotch)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.overflow, [.item("a")])
    }

    func testTinyRegionOnlyButton() {
        let r = WingLayout.layout(entries: [item("a", 40), item("b", 40)], region: 0...30, spacing: 8, overflowButtonWidth: 24, alignment: .towardNotch)
        XCTAssertEqual(r.slots.map(\.kind), [.overflow])
        XCTAssertEqual(r.overflow, [.item("a"), .item("b")])
    }
}

final class WingPreferencesTests: XCTestCase {
    func testDecodingOldBlobKeepsDefaultsForNewKeys() throws {
        let old = #"{"iconScale":0.8,"rules":{"x":"never"}}"#.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(WingPreferences.self, from: old)
        XCTAssertEqual(prefs.iconScale, 0.8)
        XCTAssertEqual(prefs.rule(for: "x"), .never)
        XCTAssertEqual(prefs.rule(for: "y"), .automatic)
        XCTAssertTrue(prefs.leftWingEnabled)
        XCTAssertEqual(prefs.overflowStyle, .bar)
    }

    func testRoundTrip() throws {
        var prefs = WingPreferences()
        prefs.groups = [ItemGroup(name: "Network", itemIDs: ["a", "b"])]
        prefs.needsDirectClick = ["c"]
        let decoded = try JSONDecoder().decode(WingPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(decoded.group(containing: "b")?.name, "Network")
    }
}

final class WingOrderingTests: XCTestCase {
    func item(_ name: String, x: CGFloat, parked: Bool = false) -> MenuBarItem {
        let extra = StatusExtra(frame: CGRect(x: x, y: parked ? 1168 : 7, width: 20, height: 24), pid: 1, appName: name, bundleID: "b.\(name)", title: "", identifier: nil)
        return ItemMatcher.match(windows: [], extras: [extra], notch: notch)[0]
    }

    func testMenuBarOrderPutsParkedFirst() {
        let items = [item("B", x: 950), item("P", x: 0, parked: true), item("A", x: 900)]
        XCTAssertEqual(WingOrdering.sorted(items, by: WingPreferences()).map(\.appName), ["P", "A", "B"])
    }

    func testCustomOrderThenUnlisted() {
        var prefs = WingPreferences()
        prefs.order = .custom
        let items = [item("A", x: 900), item("B", x: 950), item("C", x: 980)]
        prefs.customOrder = [items[2].id, items[0].id]
        XCTAssertEqual(WingOrdering.sorted(items, by: prefs).map(\.appName), ["C", "A", "B"])
    }

    func testNewDefaults() {
        let prefs = WingPreferences()
        XCTAssertFalse(prefs.notchHoverEnabled)
        XCTAssertEqual(prefs.iconPictures, .captureOnce)
        XCTAssertFalse(prefs.keepHiddenClosed)
    }
}
