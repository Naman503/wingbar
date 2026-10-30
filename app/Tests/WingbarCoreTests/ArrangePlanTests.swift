import XCTest
@testable import WingbarCore

final class ArrangePlanTests: XCTestCase {
    /// Applies steps the way the menu bar would, to check the plan reaches `desired`.
    func simulate(_ current: [String], _ steps: [ArrangePlan.Step]) -> [String] {
        var bar = current
        for step in steps {
            bar.removeAll { $0 == step.id }
            if let after = step.after, let i = bar.firstIndex(of: after) {
                bar.insert(step.id, at: i + 1)
            } else if let before = step.before, let i = bar.firstIndex(of: before) {
                bar.insert(step.id, at: i)
            } else {
                bar.insert(step.id, at: 0)
            }
        }
        return bar
    }

    func testSlackBeforeWARPIsOneMoveOfWARP() {
        // Real bar: WARP is leftmost (under the notch). The user drops Slack first.
        let current = ["WARP", "Slack", "PiP", "Tailscale"]
        let desired = ArrangePlan.reordered(current, moving: "Slack", before: "WARP")
        XCTAssertEqual(desired, ["Slack", "WARP", "PiP", "Tailscale"])
        let steps = ArrangePlan.steps(current: current, desired: desired)!
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.after, "Slack") // WARP goes right of Slack, whose edge is visible
        XCTAssertEqual(simulate(current, steps), desired)
    }

    func testMoveToEndIsOneMove() {
        let current = ["A", "B", "C", "D"]
        let desired = ArrangePlan.reordered(current, moving: "B", before: nil)
        let steps = ArrangePlan.steps(current: current, desired: desired)!
        XCTAssertEqual(steps, [ArrangePlan.Step(id: "B", after: "D", before: nil)])
        XCTAssertEqual(simulate(current, steps), desired)
    }

    func testAlreadyInOrderNeedsNothing() {
        XCTAssertTrue(ArrangePlan.steps(current: ["A", "B"], desired: ["A", "B"])!.isEmpty)
    }

    func testReverseReachesDesired() {
        let current = ["A", "B", "C", "D", "E"]
        let desired = Array(current.reversed())
        let steps = ArrangePlan.steps(current: current, desired: desired)!
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(simulate(current, steps), desired)
    }

    func testBeforeOnlyPointsAtStayingIcons() {
        let current = ["A", "B", "C"]
        let desired = ["C", "A", "B"]
        let steps = ArrangePlan.steps(current: current, desired: desired)!
        XCTAssertEqual(steps, [ArrangePlan.Step(id: "C", after: nil, before: "A")])
        XCTAssertEqual(simulate(current, steps), desired)
    }

    func testFixedIconMakesTheOtherOneMove() {
        // WARP ignores synthetic moves, so Slack moves left of it instead.
        let current = ["WARP", "Slack", "PiP"]
        let desired = ["Slack", "WARP", "PiP"]
        let steps = ArrangePlan.steps(current: current, desired: desired, fixed: ["WARP"])!
        XCTAssertEqual(steps, [ArrangePlan.Step(id: "Slack", after: nil, before: "WARP")])
        XCTAssertEqual(simulate(current, steps), desired)
    }

    func testTwoFixedIconsCantSwap() {
        XCTAssertNil(ArrangePlan.steps(current: ["A", "B", "C"], desired: ["B", "A", "C"], fixed: ["A", "B"]))
    }

    func testFixedIconKeptEvenWhenItCostsMoves() {
        let current = ["F", "A", "B", "C"]
        let desired = ["A", "B", "C", "F"]
        let steps = ArrangePlan.steps(current: current, desired: desired, fixed: ["F"])!
        XCTAssertFalse(steps.contains { $0.id == "F" })
        XCTAssertEqual(simulate(current, steps), desired)
    }
}
