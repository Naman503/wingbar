import AppKit
@preconcurrency import ApplicationServices

/// Rebuilds a status item's menu as a native NSMenu from its accessibility tree,
/// so it can open under the item's Left Wing icon. Choosing an entry presses the
/// real menu item through accessibility, which works while the menu is closed.
@MainActor
enum MenuMirror {
    /// nil when the item has no standard menu (popover apps, Control Centre modules).
    static func menu(for element: AXUIElement) -> NSMenu? {
        guard let axMenu = children(of: element).first(where: { role(of: $0) == kAXMenuRole as String }) else { return nil }
        let menu = build(axMenu, depth: 0)
        return menu.items.contains(where: { !$0.isSeparatorItem }) ? menu : nil
    }

    private static func build(_ axMenu: AXUIElement, depth: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for child in children(of: axMenu) where role(of: child) == kAXMenuItemRole as String {
            if let item = makeItem(child, depth: depth) { menu.addItem(item) }
        }
        // Drop leading, trailing and doubled separators left by skipped custom rows.
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var i = 1
        while i < menu.items.count {
            if menu.items[i].isSeparatorItem && menu.items[i - 1].isSeparatorItem { menu.removeItem(at: i) } else { i += 1 }
        }
        return menu
    }

    private static func makeItem(_ element: AXUIElement, depth: Int) -> NSMenuItem? {
        let enabled: Bool = value(element, kAXEnabledAttribute) ?? true
        let kids = children(of: element)
        var title: String = value(element, kAXTitleAttribute) ?? ""
        if title.isEmpty {
            // Custom view rows (e.g. a header with buttons) carry their text in static texts.
            title = kids.filter { role(of: $0) == kAXStaticTextRole as String }
                .compactMap { value($0, kAXValueAttribute) as String? }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let submenu = kids.first { role(of: $0) == kAXMenuRole as String }
        if title.isEmpty {
            return submenu == nil && !enabled ? .separator() : nil
        }
        // Multi-line titles (an account name repeated) read badly in a menu.
        title = title.split(separator: "\n").first.map(String.init) ?? title

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        switch value(element, kAXMenuItemMarkCharAttribute) as String? {
        case "✓"?, "✔"?: item.state = .on
        case "-"?, "•"?, "●"?: item.state = .mixed
        default: break
        }
        if let key: String = value(element, kAXMenuItemCmdCharAttribute), !key.isEmpty {
            item.keyEquivalent = key.lowercased()
            item.keyEquivalentModifierMask = modifiers(value(element, kAXMenuItemCmdModifiersAttribute) ?? 0)
        }
        if let submenu, depth < 4 {
            item.submenu = build(submenu, depth: depth + 1)
        } else if enabled {
            let target = PressTarget(element: element)
            item.target = target
            item.action = #selector(PressTarget.press(_:))
            item.representedObject = target // keeps the target alive with the item
        }
        return item
    }

    /// AX encodes menu modifiers as: 1 shift, 2 option, 4 control, 8 = no command.
    private static func modifiers(_ raw: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = raw & 8 == 0 ? [.command] : []
        if raw & 1 != 0 { flags.insert(.shift) }
        if raw & 2 != 0 { flags.insert(.option) }
        if raw & 4 != 0 { flags.insert(.control) }
        return flags
    }

    private final class PressTarget: NSObject {
        let element: AXUIElement
        init(element: AXUIElement) { self.element = element }

        @objc func press(_ sender: NSMenuItem) {
            let element = element
            // Our menu is still closing; press once it's gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementSetMessagingTimeout(element, 2)
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            }
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute)
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result as? T
    }
}
