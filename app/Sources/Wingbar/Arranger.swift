import AppKit
import WingbarCore

/// Backs the Arrange tab. The two lists start as the real menu bar, left to
/// right: icons right of Wingbar's line, and icons left of it (drawn when
/// there's room, otherwise in the Left Wing). Dragging only edits a draft;
/// Apply turns the draft into real moves in one pass, moving as few icons as
/// possible and planning around icons whose app ignores synthetic moves.
@MainActor
final class Arranger: ObservableObject {
    struct Row: Identifiable, Equatable {
        let item: MenuBarItem
        let icon: NSImage?
        /// False for Clock and Control Centre, parked icons (no window), and
        /// apps known to ignore synthetic moves.
        let movable: Bool
        let ignoresMoves: Bool
        var id: String { item.id }
        /// Drawn in the menu bar right now (rather than under the notch or off screen).
        var isDrawn: Bool { item.placement == .visible }

        static func == (a: Row, b: Row) -> Bool { a.id == b.id }
    }

    enum Side { case menuBar, leftWing }

    /// The draft, as shown in the lists.
    @Published private(set) var menuBarRows: [Row] = []
    /// Left of the line. Parked icons (no room at all) are pinned first.
    @Published private(set) var leftWingRows: [Row] = []
    @Published private(set) var busy = false
    @Published var message: String?

    /// The real bar's order when the lists were last read.
    private var realMenuBar: [String] = []
    private var realLeftWing: [String] = []

    var hasChanges: Bool {
        menuBarRows.map(\.id) != realMenuBar || leftWingRows.map(\.id) != realLeftWing
    }

    private let sections: SectionController
    private let store = WingStore.shared
    private let mover = MoveEngine()
    var picture: ((MenuBarItem) -> NSImage?)?
    var didChange: (() -> Void)?

    private static let fixedByMacOS: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]
    private static let line = "§line"

    init(sections: SectionController) {
        self.sections = sections
    }

    /// Re-reads the real bar. Discards the draft.
    func refresh() async {
        // The lists are the real order; a custom Left Wing order would contradict them.
        if store.prefs.order == .custom || !store.prefs.customOrder.isEmpty {
            store.prefs.order = .menuBar
            store.prefs.customOrder = []
        }
        let result = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        let lineEdge = sections.hiddenDivider.button?.window?.frame.maxX ?? .infinity
        let unmovable = store.prefs.unmovable
        let rows = result.items.map { item in
            let ignores = unmovable.contains(item.id)
            return Row(item: item,
                       icon: picture?(item) ?? NSRunningApplication(processIdentifier: item.pid)?.icon,
                       movable: item.windowID != nil && !Self.fixedByMacOS.contains(item.identifier ?? "") && !ignores,
                       ignoresMoves: ignores)
        }
        // By position, not by whether it's drawn this instant: with the screen locked
        // or a full-screen app in front, nothing is drawn but the order still holds.
        menuBarRows = rows.filter { $0.item.windowID != nil && $0.item.placement != .parked && $0.item.frame.minX >= lineEdge - 1 }
            .sorted { $0.item.frame.minX < $1.item.frame.minX }
        let menuBarIDs = Set(menuBarRows.map(\.id))
        let hidden = rows.filter { !menuBarIDs.contains($0.id) }
        leftWingRows = hidden.filter { $0.item.windowID == nil }.sorted { $0.item.displayName < $1.item.displayName }
            + hidden.filter { $0.item.windowID != nil }.sorted { $0.item.frame.minX < $1.item.frame.minX }
        realMenuBar = menuBarRows.map(\.id)
        realLeftWing = leftWingRows.map(\.id)
    }

    // MARK: - Draft

    /// Puts `id` just before `target` in `side`'s list (or at the drop zone: the
    /// start of the menu bar list, or the end of the hidden list, next to the line).
    func drop(_ id: String, before target: Row?, in side: Side) {
        guard !busy, let row = (menuBarRows + leftWingRows).first(where: { $0.id == id }), target?.id != id else { return }
        guard row.movable else {
            message = reason(cantMove: row)
            return
        }
        menuBarRows.removeAll { $0.id == id }
        leftWingRows.removeAll { $0.id == id }
        switch side {
        case .menuBar:
            let index = target.flatMap { t in menuBarRows.firstIndex(of: t) } ?? 0
            menuBarRows.insert(row, at: index)
        case .leftWing:
            // Parked rows stay pinned at the top; nothing goes above them.
            let firstOnBar = leftWingRows.firstIndex { $0.item.windowID != nil } ?? leftWingRows.count
            let index = target.flatMap { t in leftWingRows.firstIndex(of: t) }.map { max($0, firstOnBar) } ?? leftWingRows.count
            leftWingRows.insert(row, at: index)
        }
        message = nil
    }

    /// Arrow buttons: to the start of the menu bar list, or to the top of the
    /// hidden list (the first icon to overflow into the Left Wing).
    func sendToMenuBar(_ row: Row) { drop(row.id, before: menuBarRows.first, in: .menuBar) }
    func sendToLeftWing(_ row: Row) {
        drop(row.id, before: leftWingRows.first { $0.item.windowID != nil && $0.id != row.id }, in: .leftWing)
    }

    func revert() {
        message = nil
        Task { await refresh() }
    }

    private func reason(cantMove row: Arranger.Row) -> String {
        if row.item.windowID == nil {
            return "macOS has no room for \(row.item.displayName) at all, so it can't be placed. Hide or quit a few menu bar apps to make room."
        }
        if row.ignoresMoves {
            return "\(row.item.displayName) ignores moves from other apps. ⌘-drag it in the menu bar yourself; Wingbar arranges the others around it."
        }
        return "macOS keeps \(row.item.displayName) where it is."
    }

    // MARK: - Apply

    /// Turns the draft into real moves, in one pass.
    func apply() {
        guard !busy, hasChanges else { return }
        let desired = draftOrder()
        busy = true
        message = "Arranging… keep the mouse still"
        Task {
            // `notes` explain (e.g. an icon that ignores moves); `problems` only
            // matter if the bar doesn't end up matching the draft.
            var notes = [String]()
            var problems = [String]()
            // Hidden icons are only laid out (and reachable) with the section open.
            let wasCollapsed = !sections.state.showsHidden
            if wasCollapsed {
                sections.toggle(includingAlwaysHidden: false)
                try? await Task.sleep(for: .milliseconds(450))
            }
            do {
                // An icon found to ignore moves gets fixed and the rest re-planned.
                for _ in 0..<3 {
                    if try await runPlan(desired: desired, notes: &notes, problems: &problems) == .done { break }
                }
            } catch MoveEngine.Failure.menuBarHidden {
                problems.append("The menu bar is hidden (a full-screen app?). Apply again with it showing.")
            } catch MoveEngine.Failure.userBusy {
                problems.append("The mouse kept moving, so Wingbar stopped. Apply again and keep it still.")
            } catch {
                problems.append("macOS stopped accepting moves. Details are in ~/Library/Logs/Wingbar/moves.log.")
            }
            // Judge by where the icons end up. Near the notch macOS settles slowly,
            // so look again before reporting anything as failed.
            var matches = false
            for settle in [400, 2000] {
                try? await Task.sleep(for: .milliseconds(settle))
                matches = await barMatches(desired)
                if matches { break }
            }
            if wasCollapsed { sections.collapse() }
            await refresh()
            if matches {
                message = (["Done. The menu bar matches your arrangement."] + notes).joined(separator: " ")
            } else {
                if problems.isEmpty {
                    problems.append("Some icons couldn't go exactly there; the lists show where they are now.")
                }
                message = (notes + problems).joined(separator: " ")
            }
            busy = false
            didChange?()
        }
    }

    private enum Outcome { case done, replan }

    /// One pass of the plan from the bar as it is now. Returns `.replan` when an
    /// icon turned out to ignore moves (it's now fixed, so the plan changes).
    /// Whether the real bar's order (icons on the bar plus the line) equals `desired`.
    private func barMatches(_ desired: [String]) async -> Bool {
        let fresh = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        let lineEdge = sections.hiddenDivider.button?.window?.frame.maxX ?? .infinity
        let onBar = fresh.items.filter { $0.windowID != nil && $0.placement != .parked }.sorted { $0.frame.minX < $1.frame.minX }
        let real = onBar.filter { $0.frame.minX < lineEdge - 1 }.map(\.id) + [Self.line] + onBar.filter { $0.frame.minX >= lineEdge - 1 }.map(\.id)
        return real.filter { desired.contains($0) } == desired.filter { real.contains($0) }
    }

    private func runPlan(desired: [String], notes: inout [String], problems: inout [String]) async throws -> Outcome {
        let fresh = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        var windows = [Self.line: (window: try lineWindow(), pid: pid_t(0))]
        for item in fresh.items {
            if let window = item.windowID { windows[item.id] = (window, item.pid) }
        }
        // The real order now, with the line in its place.
        let lineEdge = sections.hiddenDivider.button?.window?.frame.maxX ?? .infinity
        let onBar = fresh.items.filter { $0.windowID != nil && $0.placement != .parked }.sorted { $0.frame.minX < $1.frame.minX }
        var current = onBar.filter { $0.frame.minX < lineEdge - 1 }.map(\.id) + [Self.line]
            + onBar.filter { $0.frame.minX >= lineEdge - 1 }.map(\.id)
        let wanted = desired.filter { current.contains($0) }
        current = current.filter { wanted.contains($0) }

        var fixed: Set<String> = [Self.line]
        fixed.formUnion(store.prefs.unmovable)
        fixed.formUnion(fresh.items.filter { Self.fixedByMacOS.contains($0.identifier ?? "") }.map(\.id))
        guard let steps = ArrangePlan.steps(current: current, desired: wanted, fixed: fixed) else {
            problems.append("Two icons that can't be moved would have to swap places, so that part was skipped.")
            return .done
        }
        let names = Dictionary(fresh.items.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        for (n, step) in steps.enumerated() {
            guard let moving = windows[step.id] else { continue }
            let name = names[step.id] ?? "An icon"
            message = steps.count > 1 ? "Arranging \(n + 1) of \(steps.count)… keep the mouse still" : "Moving \(name)…"
            let destination: MoveEngine.Destination?
            if let after = step.after.flatMap({ windows[$0]?.window }), Self.isUsableEdge(after, right: true) {
                destination = .rightOf(after)
            } else if let before = step.before.flatMap({ windows[$0]?.window }), Self.isUsableEdge(before, right: false) {
                destination = .leftOf(before)
            } else {
                destination = nil
            }
            guard let destination else {
                problems.append("\(name) belongs between two icons under the notch, where drops don't land, so it stayed put.")
                continue
            }
            do {
                try await mover.move(window: moving.window, pid: moving.pid, to: destination)
            } catch MoveEngine.Failure.ignored {
                store.prefs.unmovable.insert(step.id)
                notes.append("\(name) ignores moves from other apps, so Wingbar arranged the others around it.")
                return .replan
            } catch MoveEngine.Failure.didNotMove, MoveEngine.Failure.unsafeDropPoint {
                problems.append("\(name) didn't land where planned.")
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return .done
    }

    /// The whole bar as drafted, left to right, with the line between the lists.
    private func draftOrder() -> [String] {
        leftWingRows.filter { $0.item.windowID != nil }.map(\.id) + [Self.line] + menuBarRows.map(\.id)
    }

    private func lineWindow() throws -> CGWindowID {
        guard let frame = sections.hiddenDivider.button?.window?.frame,
              let line = MoveEngine.windowID(matching: frame) else { throw MoveEngine.Failure.noBounds }
        return line
    }

    /// A drop lands at an edge that's on screen and clear of the notch (with a
    /// little margin), whether or not the icon itself is drawn this instant.
    private static func isUsableEdge(_ window: CGWindowID, right: Bool) -> Bool {
        guard let frame = MoveEngine.bounds(of: window), let screen = NSScreen.screens.first else { return false }
        let x = right ? frame.maxX : frame.minX
        let notch = MenuBarScanner.currentNotch()?.notchSpan
        let nearNotch = notch.map { x > $0.lowerBound - 4 && x < $0.upperBound + 4 } ?? false
        return x > screen.frame.minX + 2 && x < screen.frame.maxX - 2 && !nearNotch
    }
}
