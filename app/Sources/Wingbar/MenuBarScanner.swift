import AppKit
import ApplicationServices
import WingbarCore

/// A snapshot of every status item, with the accessibility elements needed to press them.
struct ScanResult {
    var items: [MenuBarItem] = []
    /// Indexed by `MenuBarItem.extraIndex`.
    var elements: [AXUIElement] = []
    var notch: NotchGeometry?

    func element(for item: MenuBarItem) -> AXUIElement? {
        item.extraIndex.flatMap { elements.indices.contains($0) ? elements[$0] : nil }
    }
}

/// Finds status items the way the Phase 0 spike proved works on macOS 26:
/// the window list gives frames and on-screen state (no permission needed),
/// and each app's accessibility "extras menu bar" says who owns them.
enum MenuBarScanner {
    /// The built-in display's notch, or the main display's geometry when there is none.
    static func currentNotch() -> NotchGeometry? {
        let screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
        guard let screen else { return nil }
        return NotchGeometry(screenFrame: screen.frame, leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    /// - Parameter excluding: window IDs of Wingbar's own status items.
    static func scan(excluding ownWindows: Set<UInt32>) -> ScanResult {
        let notch = currentNotch()
        let windows = statusWindows().filter { !ownWindows.contains($0.windowID) }
        let (extras, elements) = statusExtras()
        let own = getpid()
        let items = ItemMatcher.match(windows: windows, extras: extras, notch: notch).filter { $0.pid != own }
        return ScanResult(items: items, elements: elements, notch: notch)
    }

    /// Async wrapper so a slow app's accessibility replies never block the UI.
    static func scanInBackground(excluding ownWindows: Set<UInt32>) async -> ScanResult {
        await Task.detached(priority: .userInitiated) { scan(excluding: ownWindows) }.value
    }

    static func debugDescription(excluding ownWindows: Set<UInt32>) -> String {
        var out = "AX trusted: \(AXIsProcessTrusted())\nown windows: \(ownWindows.sorted())\n\nwindows:\n"
        for w in statusWindows() { out += "  \(w.windowID) \(w.frame) onScreen=\(w.isOnScreen)\n" }
        out += "\nextras:\n"
        let started = Date()
        let extras = statusExtras().0
        let cold = Date().timeIntervalSince(started)
        let warmStart = Date()
        _ = statusExtras()
        out += "  (cold read \(Int(cold * 1000)) ms, warm \(Int(Date().timeIntervalSince(warmStart) * 1000)) ms, \(NSWorkspace.shared.runningApplications.count) apps)\n"
        for e in extras { out += "  \(e.frame) \(e.appName) pid=\(e.pid) [\(e.title)] \(e.identifier ?? "")\n" }
        out += "\nitems:\n"
        for i in scan(excluding: ownWindows).items { out += "  \(i.windowID.map(String.init) ?? "-") \(i.frame.minX) \(i.placement) \(i.displayName)\n" }
        return out
    }

    private static func statusWindows() -> [StatusWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = getpid()
        return list.compactMap { w in
            // Wingbar's own panels (Left Wing, notch hover) sit at the same level.
            guard (w[kCGWindowOwnerPID as String] as? Int32) != own,
                  (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  // Status items on the main menu bar; popovers at this level are taller,
                  // and a collapsed divider is far wider than any real item.
                  // Too small to be an icon: privacy indicator dots and the like.
                  y == 0, height < 50, height >= 20, width >= 12, width < 1000,
                  let id = w[kCGWindowNumber as String] as? UInt32 else { return nil }
            return StatusWindow(windowID: id, frame: CGRect(x: x, y: y, width: width, height: height),
                                isOnScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// Apps found to have no menu bar icons, and when; they're asked again
    /// only after `quietRecheck`, since most of ~100 running apps never have one.
    nonisolated(unsafe) private static var quietApps = [pid_t: Date]()
    private static let quietLock = NSLock()
    private static let quietRecheck: TimeInterval = 30

    private static func statusExtras() -> ([StatusExtra], [AXUIElement]) {
        guard AXIsProcessTrusted() else { return ([], []) }
        let now = Date()
        // Wingbar's own items are left out: their windows are filtered out too,
        // and the counts must agree for order-based matching.
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != getpid() else { return false }
            quietLock.lock(); defer { quietLock.unlock() }
            guard let checked = quietApps[app.processIdentifier] else { return true }
            return now.timeIntervalSince(checked) > quietRecheck
        }

        // Ask apps in parallel: one slow or hung app shouldn't hold up the rest.
        var results = [[(StatusExtra, AXUIElement)]](repeating: [], count: apps.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let app = apps[i]
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard let bar: AXUIElement = value(appElement, "AXExtrasMenuBar"),
                  let children: [AXUIElement] = value(bar, kAXChildrenAttribute), !children.isEmpty else {
                quietLock.lock(); quietApps[app.processIdentifier] = now; quietLock.unlock()
                return
            }
            quietLock.lock(); quietApps[app.processIdentifier] = nil; quietLock.unlock()
            var found = [(StatusExtra, AXUIElement)]()
            for child in children {
                guard let frame = frame(of: child) else { continue }
                let title = [value(child, kAXTitleAttribute), value(child, kAXDescriptionAttribute)]
                    .compactMap { (s: String?) in s?.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty } ?? ""
                found.append((StatusExtra(
                    frame: frame, pid: app.processIdentifier,
                    appName: app.localizedName ?? "Unknown", bundleID: app.bundleIdentifier,
                    title: title, identifier: value(child, "AXIdentifier")), child))
            }
            resultsLock.lock(); results[i] = found; resultsLock.unlock()
        }
        let all = results.flatMap { $0 }
        return (all.map(\.0), all.map(\.1))
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let p: AXValue = value(element, kAXPositionAttribute),
              let s: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &origin)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Opens an item's menu through accessibility. Works for apps with a standard
    /// status menu, even hidden ones; Control Centre modules and apps with custom
    /// click handlers ignore it (they need a reveal + real click, Phase 2).
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 2)
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        // -25204 (cannot complete) often still opens the menu; treat it as sent.
        return error == .success || error == .cannotComplete
    }
}
