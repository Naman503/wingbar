import AppKit

/// Moves and clicks other apps' menu bar items with synthetic events, the way a
/// person ⌘-drags them. Proven in the Phase 0/2 spikes on macOS 26:
///
/// - A move is a ⌘ mouse-down stamped with the moving item's window, then a
///   mouse-up stamped with the target item's window, both at the drop point.
///   Each event goes to the session stream *and* straight to the item's app.
/// - The drop point must be on screen and outside the notch; drops under the
///   notch land in the wrong slot.
///
/// Every operation is refused while the menu bar is hidden (a full-screen app
/// would receive the events instead) or while the user is using the mouse.
@MainActor
final class MoveEngine {
    enum Destination {
        case rightOf(CGWindowID)
        case leftOf(CGWindowID)

        var target: CGWindowID {
            switch self {
            case let .rightOf(id), let .leftOf(id): id
            }
        }
    }

    enum Failure: Error {
        case menuBarHidden, userBusy, noBounds, unsafeDropPoint, didNotMove
        /// The icon never budged: its app ignores synthetic moves (e.g. Cloudflare WARP).
        case ignored
    }

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    init() {
        // Synthetic events are otherwise briefly suppressed after real input.
        let permit = CGEventSource(stateID: .combinedSessionState)
        let all: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        permit?.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateSuppressionInterval)
        permit?.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateRemoteMouseDrag)
        permit?.localEventsSuppressionInterval = 0
    }

    // MARK: - Moving

    /// Moves the item's window to `destination`, retrying a couple of times.
    func move(window: CGWindowID, pid: pid_t, to destination: Destination) async throws {
        var origin: CGRect?
        var everMoved = false
        for attempt in 1...3 {
            try await waitUntilSafe()
            guard let start = Self.bounds(of: window), let target = Self.bounds(of: destination.target) else { throw Failure.noBounds }
            if Self.isPlaced(start, relativeTo: target, destination) { return }
            if origin == nil { origin = start }
            let point: CGPoint
            switch destination {
            case .rightOf: point = CGPoint(x: target.maxX, y: target.minY)
            case .leftOf: point = CGPoint(x: target.minX, y: target.minY)
            }
            guard Self.isSafeDropPoint(point) else {
                Self.log("move \(window) → \(destination): unsafe drop point \(point)")
                throw Failure.unsafeDropPoint
            }
            Self.log("move \(window) (pid \(pid)) attempt \(attempt): from \(start) to \(destination) target \(target) at \(point)")

            await withHiddenCursor(at: point) {
                self.post(self.mouseEvent(.leftMouseDown, at: point, window: window, pid: pid, flags: .maskCommand, isMove: true), to: pid)
                try? await Task.sleep(for: .milliseconds(120))
                for _ in 0..<2 { // A second mouse-up keeps the item from getting stuck mid-drag.
                    self.post(self.mouseEvent(.leftMouseUp, at: point, window: destination.target, pid: pid, flags: [], isMove: true), to: pid)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            // Window frames lag behind the menu bar's re-layout, so give the
            // window list time to catch up before judging the move.
            // Next to the notch, macOS can take a couple of seconds to settle.
            for wait in [250, 600, 1200, 2500] {
                try? await Task.sleep(for: .milliseconds(wait))
                let now = Self.bounds(of: window), target = Self.bounds(of: destination.target)
                Self.log("  after +\(wait) ms: item \(now.map { "\($0)" } ?? "gone") target \(target.map { "\($0)" } ?? "gone")")
                if let now, let target, Self.isPlaced(now, relativeTo: target, destination) { return }
                if let now, let origin, abs(now.minX - origin.minX) >= 1 { everMoved = true }
            }
            // Two attempts without the slightest movement: the app isn't listening.
            if attempt == 2, !everMoved { break }
        }
        Self.log(everMoved ? "  gave up: did not land" : "  gave up: the app ignores synthetic moves")
        throw everMoved ? Failure.didNotMove : Failure.ignored
    }

    // MARK: - Log

    /// ~/Library/Logs/Wingbar/moves.log: every move attempt and its outcome,
    /// for diagnosing icons that won't move. Kept to the last ~200 KB.
    static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wingbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("moves.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int), size > 200_000 {
            try? FileManager.default.removeItem(at: file)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: - Clicking

    /// Clicks the item's window where it is now (it must be visible). Tries a
    /// plain HID click first, then one delivered to the session and the app.
    /// Returns true if the app put up a new window (its menu or popover).
    func click(window: CGWindowID, pid: pid_t) async throws -> Bool {
        for deliverToApp in [false, true] {
            try await waitUntilSafe()
            guard let frame = Self.bounds(of: window) else { throw Failure.noBounds }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            guard Self.isSafeDropPoint(point) else {
                Self.log("click \(window): icon isn't in a visible spot (\(point))")
                throw Failure.unsafeDropPoint
            }
            Self.log("click \(window) (pid \(pid)) at \(point), \(deliverToApp ? "to app" : "HID")")
            let before = Self.windowIDs(of: pid)
            await withHiddenCursor(at: point) {
                let down = self.mouseEvent(.leftMouseDown, at: point, window: window, pid: pid, flags: [], isMove: false)
                let up = self.mouseEvent(.leftMouseUp, at: point, window: window, pid: pid, flags: [], isMove: false)
                if deliverToApp { self.post(down, to: pid) } else { down?.post(tap: .cghidEventTap) }
                try? await Task.sleep(for: .milliseconds(70))
                if deliverToApp { self.post(up, to: pid) } else { up?.post(tap: .cghidEventTap) }
            }
            try? await Task.sleep(for: .milliseconds(700))
            if !Self.windowIDs(of: pid).subtracting(before).isEmpty { return true }
        }
        return false
    }

    // MARK: - Events

    private func mouseEvent(_ type: CGEventType, at point: CGPoint, window: CGWindowID, pid: pid_t, flags: CGEventFlags, isMove: Bool) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        if isMove, let windowField = CGEventField(rawValue: 0x33) {
            event.setIntegerValueField(windowField, value: Int64(window))
        } else {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        return event
    }

    private func post(_ event: CGEvent?, to pid: pid_t) {
        guard let event else { return }
        event.post(tap: .cgSessionEventTap)
        event.postToPid(pid)
    }

    /// The drop or click lands where the cursor is, so put it there briefly and
    /// hidden, then return it.
    /// True while Wingbar is posting synthetic events, and for a moment after,
    /// so watchers of "clicks elsewhere" can tell them from the user's.
    static var isPostingEvents: Bool {
        activeOperations > 0 || Date().timeIntervalSince(lastEventTime) < 0.6
    }
    private static var activeOperations = 0
    private static var lastEventTime = Date.distantPast

    private func withHiddenCursor(at point: CGPoint, _ body: () async -> Void) async {
        Self.activeOperations += 1
        defer {
            Self.activeOperations -= 1
            Self.lastEventTime = Date()
        }
        let original = CGEvent(source: nil)?.location ?? point
        CGWarpMouseCursorPosition(point)
        CGDisplayHideCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(20))
        await body()
        CGWarpMouseCursorPosition(original)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    // MARK: - Safety

    /// Waits up to a second for the user to stop using the mouse; refuses while
    /// the menu bar is hidden.
    private func waitUntilSafe() async throws {
        for _ in 0..<20 {
            guard MenuBarState.isMenuBarVisible() else {
                Self.log("refused: menu bar hidden")
                throw Failure.menuBarHidden
            }
            let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
                || CGEventSource.buttonState(.combinedSessionState, button: .right)
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
            if !buttonDown && idle > 0.15 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.userBusy
    }

    private static func isSafeDropPoint(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let onScreen = point.x > screen.frame.minX && point.x < screen.frame.maxX
        let underNotch = MenuBarScanner.currentNotch()?.notchSpan?.contains(point.x) ?? false
        return onScreen && !underNotch
    }

    private static func isPlaced(_ item: CGRect, relativeTo target: CGRect, _ destination: Destination) -> Bool {
        switch destination {
        case .rightOf: abs(item.minX - target.maxX) < 1
        case .leftOf: abs(item.maxX - target.minX) < 1
        }
    }

    static func bounds(of window: CGWindowID) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == window }),
              let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Whether the window server is drawing the window (false under the notch or off screen).
    static func isOnScreen(_ window: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == window }
    }

    static func windowIDs(of pid: pid_t) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    /// The window-list ID of one of Wingbar's own status items, found by its
    /// frame (AppKit's windowNumber for status items isn't the window-list ID).
    static func windowID(matching frame: NSRect) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.statusWindow))
        return list.first { info in
            guard (info[kCGWindowLayer as String] as? Int) == level,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return abs((b["X"] ?? 0) - frame.minX) < 1 && abs((b["Width"] ?? 0) - frame.width) < 1 && (b["Y"] ?? 1) == 0
        }?[kCGWindowNumber as String] as? CGWindowID
    }
}
