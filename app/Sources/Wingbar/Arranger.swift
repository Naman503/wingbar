import AppKit
import WingbarCore

/// Backs the Arrange tab. Both lists mirror the real menu bar, left to right:
/// icons right of Wingbar's line, and icons left of it (drawn when there's
/// room, otherwise in the Left Wing). Every drop moves real icons: the plan
/// keeps as many in place as possible and drops the rest next to a neighbour
/// whose edge is visible, since drops under the notch don't land.
@MainActor
final class Arranger: ObservableObject {
    struct Row: Identifiable {
        let item: MenuBarItem
        let icon: NSImage?
        /// Clock and Control Centre can't be moved; parked icons have no window to drag.
        let movable: Bool
        var id: String { item.id }
        /// Drawn in the menu bar right now (rather than under the notch or off screen).
        var isDrawn: Bool { item.placement == .visible }
    }

    enum Side { case menuBar, leftWing }

    @Published private(set) var menuBarRows: [Row] = []
    /// Left of the line, real order. Parked icons (no room at all) come first.
    @Published private(set) var leftWingRows: [Row] = []
    @Published private(set) var busy = false
    @Published var message: String?

    private let sections: SectionController
    private let store = WingStore.shared
    private let mover = MoveEngine()
    var picture: ((MenuBarItem) -> NSImage?)?
    var didChange: (() -> Void)?

    private static let fixed: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]

    init(sections: SectionController) {
        self.sections = sections
    }

    func refresh() async {
        // The lists are the real order; a custom Left Wing order would contradict them.
        if store.prefs.order == .custom || !store.prefs.customOrder.isEmpty {
            store.prefs.order = .menuBar
            store.prefs.customOrder = []
        }
        let result = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        let lineEdge = sections.hiddenDivider.button?.window?.frame.maxX ?? .infinity
        let rows = result.items.map { item in
            Row(item: item,
                icon: picture?(item) ?? NSRunningApplication(processIdentifier: item.pid)?.icon,
                movable: item.windowID != nil && !Self.fixed.contains(item.identifier ?? ""))
        }
        // By position, not by whether it's drawn this instant: with the screen locked
        // or a full-screen app in front, nothing is drawn but the order still holds.
        menuBarRows = rows.filter { $0.item.windowID != nil && $0.item.placement != .parked && $0.item.frame.minX >= lineEdge - 1 }
            .sorted { $0.item.frame.minX < $1.item.frame.minX }
        let menuBarIDs = Set(menuBarRows.map(\.id))
        let hidden = rows.filter { !menuBarIDs.contains($0.id) }
        leftWingRows = hidden.filter { $0.item.windowID == nil }.sorted { $0.item.displayName < $1.item.displayName }
            + hidden.filter { $0.item.windowID != nil }.sorted { $0.item.frame.minX < $1.item.frame.minX }
    }

    // MARK: - Drag and drop

    /// Drops `id` just before `target` in `side`'s list. With no target it goes
    /// to the drop zone: the start of the menu bar list, or, for the hidden
    /// list, the spot next to the notch (the first icon to overflow).
    func drop(_ id: String, before target: Row?, in side: Side) {
        guard let dragged = (menuBarRows + leftWingRows).first(where: { $0.id == id }), target?.id != id else { return }
        guard dragged.movable, let window = dragged.item.windowID else {
            message = dragged.item.windowID == nil
                ? "macOS has no room for \(dragged.item.displayName) at all, so it can't be placed. Hide or quit a few menu bar apps to make room."
                : "macOS keeps \(dragged.item.displayName) where it is."
            return
        }
        switch side {
        case .menuBar:
            let rows = menuBarRows.filter { $0.id != id }
            let index = target.flatMap { t in rows.firstIndex { $0.id == t.id } } ?? 0
            let anchor = index > 0 ? rows[index - 1].item.windowID : nil
            perform("Moving \(dragged.item.displayName)…") {
                // Right of the icon before it, or right of the line for the first spot.
                try await self.mover.move(window: window, pid: dragged.item.pid, to: .rightOf(anchor ?? self.lineWindow()))
            }
        case .leftWing:
            let onBar = leftWingRows.filter { $0.item.windowID != nil }
            let current = onBar.map(\.id) + (onBar.contains { $0.id == id } ? [] : [id])
            // Dropping on a parked row (they're pinned first) means "first on the bar".
            let targetOnBar = target.flatMap { t in onBar.contains { $0.id == t.id } ? t.id : onBar.first { $0.id != id }?.id }
            let desired = ArrangePlan.reordered(current, moving: id, before: target == nil ? firstDrawnHidden(excluding: id) : targetOnBar)
            arrangeHidden(current: current, desired: desired, moving: dragged)
        }
    }

    /// Arrow buttons: right of the line = always in the menu bar; left of it =
    /// the first icon to overflow (next to the notch).
    func sendToMenuBar(_ row: Row) { drop(row.id, before: menuBarRows.first, in: .menuBar) }
    func sendToLeftWing(_ row: Row) { drop(row.id, before: nil, in: .leftWing) }

    /// The leftmost icon left of the line that's drawn: dropping just before it
    /// makes the dropped icon the first one pushed under the notch.
    private func firstDrawnHidden(excluding id: String) -> String? {
        leftWingRows.first { $0.id != id && $0.item.windowID != nil && $0.isDrawn }?.id
    }

    private func arrangeHidden(current: [String], desired: [String], moving dragged: Row) {
        let steps = ArrangePlan.steps(current: current, desired: desired)
        guard !steps.isEmpty else { return }
        let windows = Dictionary(uniqueKeysWithValues: (menuBarRows + leftWingRows).compactMap { row in
            row.item.windowID.map { (row.id, (window: $0, pid: row.item.pid)) }
        })
        let status = steps.count == 1 ? "Moving \(dragged.item.displayName)…" : "Arranging \(steps.count) icons… keep the mouse still"
        perform(status) {
            // Hidden icons are only laid out (and reachable) with the section open.
            let wasCollapsed = !self.sections.state.showsHidden
            if wasCollapsed {
                self.sections.toggle(includingAlwaysHidden: false)
                try? await Task.sleep(for: .milliseconds(450))
            }
            defer { if wasCollapsed { self.sections.collapse() } }

            for (index, step) in steps.enumerated() {
                guard let moving = windows[step.id] else { continue }
                if let after = step.after.flatMap({ windows[$0]?.window }), Self.hasVisibleEdge(after, right: true) {
                    try await self.mover.move(window: moving.window, pid: moving.pid, to: .rightOf(after))
                } else if let before = step.before.flatMap({ windows[$0]?.window }), Self.hasVisibleEdge(before, right: false) {
                    try await self.mover.move(window: moving.window, pid: moving.pid, to: .leftOf(before))
                } else {
                    // Both neighbours are under the notch. Rebuild the rest of the
                    // order next to the line (always visible), left to right.
                    let start = desired.firstIndex(of: step.id) ?? 0
                    self.message = "Arranging \(desired.count - start) icons next to the notch… keep the mouse still"
                    let line = try self.lineWindow()
                    for id in desired[start...] {
                        guard let w = windows[id] else { continue }
                        try await self.mover.move(window: w.window, pid: w.pid, to: .leftOf(line))
                    }
                    break
                }
                if index < steps.count - 1 { try? await Task.sleep(for: .milliseconds(150)) }
            }
        }
    }

    private func lineWindow() throws -> CGWindowID {
        guard let frame = sections.hiddenDivider.button?.window?.frame,
              let line = MoveEngine.windowID(matching: frame) else { throw MoveEngine.Failure.noBounds }
        return line
    }

    /// Drops only land at an edge that's drawn, on screen, and outside the notch.
    private static func hasVisibleEdge(_ window: CGWindowID, right: Bool) -> Bool {
        guard MoveEngine.isOnScreen(window), let frame = MoveEngine.bounds(of: window),
              let screen = NSScreen.screens.first else { return false }
        let x = right ? frame.maxX : frame.minX
        let underNotch = MenuBarScanner.currentNotch()?.notchSpan?.contains(x) ?? false
        return x > screen.frame.minX && x < screen.frame.maxX && !underNotch
    }

    private func perform(_ status: String, _ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = status
        Task {
            do {
                try await work()
                message = nil
            } catch MoveEngine.Failure.menuBarHidden {
                message = "The menu bar is hidden (a full-screen app?). Try again with it showing."
            } catch MoveEngine.Failure.userBusy {
                message = "Waiting for the mouse to be still timed out. Try again without moving it."
            } catch {
                message = "macOS didn't accept that move. Try again, or ⌘-drag the icon in the menu bar."
            }
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
            busy = false
            didChange?()
        }
    }
}
