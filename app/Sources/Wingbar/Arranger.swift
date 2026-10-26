import AppKit
import WingbarCore

/// Backs the Arrange tab. The menu bar side holds real icons, so reordering it
/// ⌘-drags them; the Left Wing is drawn by Wingbar, so its order is just a
/// preference. Moving an icon between the two means moving it across
/// Wingbar's line.
@MainActor
final class Arranger: ObservableObject {
    struct Row: Identifiable {
        let item: MenuBarItem
        let icon: NSImage?
        /// Clock and Control Centre can't be moved; parked icons have no window to drag.
        let movable: Bool
        var id: String { item.id }
    }

    @Published private(set) var menuBarRows: [Row] = []
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
        let result = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        let lineEdge = sections.hiddenDivider.button?.window?.frame.maxX ?? .infinity
        let rows = result.items.map { item in
            Row(item: item,
                icon: picture?(item) ?? NSRunningApplication(processIdentifier: item.pid)?.icon,
                movable: item.windowID != nil && !Self.fixed.contains(item.identifier ?? ""))
        }
        menuBarRows = rows.filter { $0.item.placement == .visible && $0.item.frame.minX >= lineEdge - 1 }
            .sorted { $0.item.frame.minX < $1.item.frame.minX }
        let menuBarIDs = Set(menuBarRows.map(\.id))
        let hidden = rows.filter { !menuBarIDs.contains($0.id) }
        let order = WingOrdering.sorted(hidden.map(\.item), by: store.prefs).map(\.id)
        leftWingRows = order.compactMap { id in hidden.first { $0.id == id } }
    }

    // MARK: - Drag and drop

    enum Side { case menuBar, leftWing }

    /// Drops `id` just before `target` in `side`'s list (or, with no target, at
    /// that list's drop zone: the start of the menu bar, or hidden next to the
    /// line). Both lists mirror the real menu bar, left to right, so a drop
    /// moves the real icon, anchored to a neighbour whose edge is visible.
    func drop(_ id: String, before target: Row?, in side: Side) {
        guard let dragged = (menuBarRows + leftWingRows).first(where: { $0.id == id }), target?.id != id else { return }
        guard let window = dragged.item.windowID, dragged.movable else {
            // Parked icons have no window; only the Left Wing order can change.
            if side == .leftWing { reorderLeftWingOnly(id, before: target) }
            return
        }
        let pid = dragged.item.pid
        perform("Moving \(dragged.item.displayName)…") {
            switch side {
            case .menuBar:
                let rows = self.menuBarRows.filter { $0.id != id }
                let index = target.flatMap { t in rows.firstIndex { $0.id == t.id } } ?? 0
                if index > 0, let prev = rows[index - 1].item.windowID {
                    try await self.mover.move(window: window, pid: pid, to: .rightOf(prev))
                } else {
                    try await self.mover.move(window: window, pid: pid, to: .rightOf(try self.lineWindow()))
                }
            case .leftWing:
                // Hidden icons are only laid out (and reachable) with the section open.
                let wasCollapsed = !self.sections.state.showsHidden
                if wasCollapsed {
                    self.sections.toggle(includingAlwaysHidden: false)
                    try? await Task.sleep(for: .milliseconds(450))
                }
                defer { if wasCollapsed { self.sections.collapse() } }
                guard let target else {
                    return try await self.mover.move(window: window, pid: pid, to: .leftOf(try self.lineWindow()))
                }
                let rows = self.leftWingRows.filter { $0.id != id }
                let index = rows.firstIndex { $0.id == target.id } ?? 0
                if index > 0, let prev = rows[index - 1].item.windowID, Self.hasVisibleEdge(prev, right: true) {
                    try await self.mover.move(window: window, pid: pid, to: .rightOf(prev))
                } else if let next = target.item.windowID, Self.hasVisibleEdge(next, right: false) {
                    try await self.mover.move(window: window, pid: pid, to: .leftOf(next))
                } else {
                    // Both neighbours are under the notch, where drops don't land reliably.
                    self.reorderLeftWingOnly(id, before: target)
                    self.message = "Both neighbours are under the notch, so only the Left Wing order changed."
                    return
                }
            }
            // The real bar now has the order the user wants; let the Left Wing follow it.
            self.store.prefs.order = .menuBar
            self.store.prefs.customOrder = []
        }
    }

    /// Arrow buttons: right of the line = always in the menu bar; left of it = hidden.
    func sendToMenuBar(_ row: Row) { drop(row.id, before: menuBarRows.first, in: .menuBar) }
    func sendToLeftWing(_ row: Row) { drop(row.id, before: nil, in: .leftWing) }

    private func reorderLeftWingOnly(_ id: String, before target: Row?) {
        var ids = leftWingRows.map(\.id).filter { $0 != id }
        let index = target.flatMap { t in ids.firstIndex(of: t.id) } ?? ids.count
        ids.insert(id, at: index)
        store.prefs.customOrder = ids
        store.prefs.order = .custom
        Task { await refresh() }
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
