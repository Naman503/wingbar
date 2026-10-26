import AppKit
import ApplicationServices

/// Facts about the system menu bar that decide where the Left Wing can go.
@MainActor
enum MenuBarState {
    /// Right edge of the frontmost app's menus (File, Edit, …), or nil if unknown.
    static func appMenusMaxX() -> CGFloat? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Our own menus can't be read through accessibility from our main thread
        // (it would be answering itself), so measure them from their titles.
        if app.processIdentifier == getpid() { return ownMenusMaxX() }
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return nil }
        return items.compactMap(frame).filter { $0.width > 0 && $0.minY < 50 }.map(\.maxX).max()
    }

    /// Apple menu plus Wingbar's own menu titles, as the menu bar lays them out.
    private static func ownMenusMaxX() -> CGFloat {
        let font = NSFont.menuBarFont(ofSize: 0)
        let titles = NSApp.mainMenu?.items.map(\.title) ?? []
        let bold = NSFont.boldSystemFont(ofSize: font.pointSize)
        let widths = titles.enumerated().map { i, title in
            (title as NSString).size(withAttributes: [.font: i == 0 ? bold : font]).width + 22
        }
        return 46 + widths.reduce(0, +)
    }

    /// False while the menu bar is hidden: a full-screen app is in front, or
    /// the user has the menu bar set to hide automatically.
    static func isMenuBarVisible() -> Bool {
        if UserDefaults.standard.bool(forKey: "_HIHideMenuBar") || isFrontWindowFullScreen() { return false }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == level,
                  (w[kCGWindowOwnerName as String] as? String) == "Window Server",
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return b["Y"] == 0 && (b["Height"] ?? 0) < 60 && (b["Width"] ?? 0) > 200
        }
    }

    /// The window server keeps reporting the menu bar window in full-screen
    /// Spaces on notched Macs, so ask the front app's window directly.
    static func isFrontWindowFullScreen() -> Bool {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
