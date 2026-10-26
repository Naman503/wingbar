// Wingbar Phase 0 spike: throwaway. Proves on macOS 26 that we can
//   1. list every menu bar item and map it to its app (CG window list + AX extras menu bar)
//   2. capture each item's image (ScreenCaptureKit)
//   3. open a hidden (under-the-notch) item's menu (AXPress)
// Usage: open WingbarSpike.app --args <prompt|list|capture|press <query>>
// Output goes to spike/out/.

import AppKit
import ApplicationServices
import ScreenCaptureKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.first { $0.hasPrefix("--out=") }?.dropFirst(6).description
    ?? NSHomeDirectory() + "/wingbar-spike-out")
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--out=") && !$0.hasPrefix("-psn") }
var log = ""
func say(_ s: String) { print(s); log += s + "\n" }
func finish() -> Never {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try? log.write(to: outDir.appendingPathComponent("\(args.first ?? "none").log"), atomically: true, encoding: .utf8)
    exit(0)
}

// MARK: - Geometry

struct Notch { let minX: CGFloat; let maxX: CGFloat }
func notch() -> Notch? {
    guard let s = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }),
          let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
    return Notch(minX: l.maxX, maxX: r.minX)
}

// MARK: - Discovery

struct Item {
    let windowID: CGWindowID
    let frame: CGRect
    let onScreen: Bool
    var app = "?"
    var pid: pid_t = 0
    var title = ""
    var ax: AXUIElement?
    var underNotch = false
}

func axValue<T>(_ el: AXUIElement, _ attr: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v as? T
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p: AXValue = axValue(el, kAXPositionAttribute), let s: AXValue = axValue(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

struct AXExtra { let el: AXUIElement; let frame: CGRect; let app: String; let pid: pid_t; let title: String }

/// Every app's status items, read from its accessibility "extras menu bar".
func axExtras() -> [AXExtra] {
    var out = [AXExtra]()
    for app in NSWorkspace.shared.runningApplications {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        guard let bar: AXUIElement = axValue(el, "AXExtrasMenuBar"),
              let kids: [AXUIElement] = axValue(bar, kAXChildrenAttribute) else { continue }
        for k in kids {
            guard let f = axFrame(k) else { continue }
            let t = [axValue(k, kAXTitleAttribute), axValue(k, kAXDescriptionAttribute), axValue(k, "AXIdentifier")]
                .compactMap { (s: String?) in s }.filter { !$0.isEmpty }.joined(separator: " | ")
            out.append(AXExtra(el: k, frame: f, app: app.localizedName ?? "pid \(app.processIdentifier)", pid: app.processIdentifier, title: t))
        }
    }
    return out
}

func discover() -> [Item] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var items = list.compactMap { w -> Item? in
        guard (w[kCGWindowLayer as String] as? Int) == 25,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat],
              let h = b["Height"], h < 50, b["Y"] == 0 else { return nil }
        return Item(windowID: w[kCGWindowNumber as String] as! CGWindowID,
                    frame: CGRect(x: b["X"]!, y: 0, width: b["Width"]!, height: h),
                    onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }.sorted { $0.frame.minX < $1.frame.minX }
    let extras = axExtras().filter { $0.frame.width > 0 }
    let n = notch()
    var matched = Set<Int>()
    for i in items.indices {
        // The AX frame is the icon inset inside the item's window, so match by containment.
        if let j = extras.indices.first(where: { !matched.contains($0) && items[i].frame.contains(CGPoint(x: extras[$0].frame.midX, y: 10)) }) {
            let m = extras[j]; matched.insert(j)
            items[i].app = m.app; items[i].pid = m.pid; items[i].title = m.title; items[i].ax = m.el
        }
        if let n { items[i].underNotch = items[i].frame.maxX > n.minX && items[i].frame.minX < n.maxX }
    }
    // Items macOS couldn't fit at all have no window on the bar; their AX frame sits off-screen.
    for j in extras.indices where !matched.contains(j) {
        let m = extras[j]
        var it = Item(windowID: 0, frame: m.frame, onScreen: false)
        it.app = m.app; it.pid = m.pid; it.title = m.title; it.ax = m.el
        items.append(it)
    }
    return items
}

func printItems(_ items: [Item]) {
    if let n = notch() { say("notch: x \(Int(n.minX))–\(Int(n.maxX))") }
    say("AX trusted: \(AXIsProcessTrusted())  screen capture: \(CGPreflightScreenCaptureAccess())")
    say(String(format: "%-3@ %-8@ %-6@ %-6@ %-7@ %-24@ %@", "#", "window", "x", "w", "state", "app", "title"))
    for (i, it) in items.enumerated() {
        let state = it.windowID == 0 ? "PARKED" : it.underNotch ? "NOTCH" : (it.onScreen ? "shown" : "hidden")
        say(String(format: "%-3d %-8u %-6d %-6d %-7@ %-24@ %@", i, it.windowID, Int(it.frame.minX), Int(it.frame.width),
                   state, String(it.app.prefix(24)), it.title))
    }
}

// MARK: - Capture

func capture(_ items: [Item]) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let dir = outDir.appendingPathComponent("items")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, it) in items.enumerated() {
            guard let w = byID[it.windowID] else { say("#\(i) window \(it.windowID): not in SCShareableContent"); continue }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
            cfg.showsCursor = false
            do {
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                let name = String(format: "%02d-%@.png", i, it.app.replacingOccurrences(of: "/", with: "_"))
                let rep = NSBitmapImageRep(cgImage: img)
                try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
                say("#\(i) \(it.app): captured \(img.width)x\(img.height) -> items/\(name)\(it.underNotch ? " (under notch)" : "")")
            } catch { say("#\(i) \(it.app): capture failed: \(error.localizedDescription)") }
        }
    } catch { say("SCShareableContent failed: \(error.localizedDescription)") }
}

func screenshot(_ name: String) async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first else { return }
        let cfg = SCStreamConfiguration(); cfg.width = d.width * 2; cfg.height = d.height * 2
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg)
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
        say("screenshot -> \(name)")
    } catch { say("screenshot failed: \(error.localizedDescription)") }
}

/// On-screen windows above the menu bar layer, keyed by window ID, to see where a menu actually opened.
func menuWindows() -> [CGWindowID: String] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var out = [CGWindowID: String]()
    for w in list where (w[kCGWindowLayer as String] as? Int ?? 0) >= 25 {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat], let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
        out[id] = "layer \(w[kCGWindowLayer as String]!) \(w[kCGWindowOwnerName as String] ?? "?") (pid \(w[kCGWindowOwnerPID as String]!)) x \(Int(b["X"]!)) y \(Int(b["Y"]!)) \(Int(b["Width"]!))x\(Int(b["Height"]!))"
    }
    return out
}

// MARK: - Main

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

Task {
    switch args.first {
    case "prompt":
        let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        let sc = CGRequestScreenCaptureAccess()
        say("AX trusted: \(ax)  screen capture: \(sc)")
    case "list":
        printItems(discover())
        say("\nraw AX extras:")
        for e in axExtras().sorted(by: { $0.frame.minX < $1.frame.minX }) {
            say("  x \(Int(e.frame.minX)) y \(Int(e.frame.minY)) w \(Int(e.frame.width)) \(e.app) [\(e.title)]")
        }
    case "capture":
        let items = discover(); printItems(items); say(""); await capture(items)
    case "press":
        let q = args.dropFirst().joined(separator: " ").lowercased()
        let items = discover(); printItems(items)
        let target = Int(q).flatMap { items.indices.contains($0) ? items[$0] : nil }
            ?? items.first { $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            ?? items.first { $0.underNotch && $0.ax != nil }
        guard let t = target, let el = t.ax else { say("\nno pressable item for '\(q)'"); break }
        say("\npressing #\(items.firstIndex { $0.windowID == t.windowID }!) \(t.app) [\(t.title)] at x \(Int(t.frame.minX)) underNotch=\(t.underNotch)")
        say("frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        let before = menuWindows()
        AXUIElementSetMessagingTimeout(el, 2)
        let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
        say("AXPress result: \(err.rawValue == 0 ? "success" : "AXError \(err.rawValue)")")
        try? await Task.sleep(for: .milliseconds(800))
        let new = menuWindows().filter { before[$0.key] == nil }
        say(new.isEmpty ? "no new windows appeared" : "new windows:\n  " + new.values.sorted().joined(separator: "\n  "))
        await screenshot("press-screen.png")
        // Close only a menu we opened, and only by messaging that item's process.
        if !new.isEmpty {
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(t.pid) }
        }
    case "click":
        // Synthetic click posted straight to a process, tagged with the item's window,
        // so it never hits the notch and never moves the real cursor.
        let q = args.dropFirst().joined(separator: " ").lowercased()
        let items = discover()
        guard let t = items.first(where: { $0.windowID != 0 && ($0.app.lowercased().contains(q) || $0.title.lowercased().contains(q)) }) else {
            say("no on-bar item for '\(q)'"); break
        }
        let ccPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first?.processIdentifier ?? 0
        let pt = CGPoint(x: t.frame.midX, y: t.frame.midY)
        say("clicking \(t.app) window \(t.windowID) at \(Int(pt.x)),\(Int(pt.y)) underNotch=\(t.underNotch)")
        for (label, pid) in [("app", t.pid), ("Control Centre", ccPID)] where pid != 0 {
            let before = menuWindows()
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) else { continue }
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(t.windowID))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(t.windowID))
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                e.postToPid(pid)
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .milliseconds(800))
            let new = menuWindows().filter { before[$0.key] == nil }
            say("posted to \(label) (pid \(pid)): " + (new.isEmpty ? "no new windows" : "new windows:\n  " + new.values.sorted().joined(separator: "\n  ")))
            await screenshot("click-\(label == "app" ? "app" : "cc").png")
            if !new.isEmpty {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(pid) }
                break
            }
        }
    case "menu":
        // Dump an item's AX menu tree without opening it.
        let q = args.dropFirst().joined(separator: " ").lowercased()
        guard let t = discover().first(where: { $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) }), let el = t.ax else {
            say("no AX item for '\(q)'"); break
        }
        func dump(_ e: AXUIElement, _ depth: Int) {
            guard depth < 4 else { return }
            let kids: [AXUIElement] = axValue(e, kAXChildrenAttribute) ?? []
            for k in kids {
                let role: String = axValue(k, kAXRoleAttribute) ?? "?"
                let title: String = axValue(k, kAXTitleAttribute) ?? ""
                let enabled: Bool = axValue(k, kAXEnabledAttribute) ?? false
                let mark: String = axValue(k, kAXMenuItemMarkCharAttribute) ?? ""
                let key: String = axValue(k, kAXMenuItemCmdCharAttribute) ?? ""
                say(String(repeating: "  ", count: depth) + "\(role) '\(title)' enabled=\(enabled)\(mark.isEmpty ? "" : " mark=\(mark)")\(key.isEmpty ? "" : " key=\(key)")")
                dump(k, depth + 1)
            }
        }
        say("\(t.app):"); dump(el, 0)
    case "move":
        // move <item> > <target>: put <item> just right of <target> with a synthetic ⌘-drag.
        // move <item> < <target>: just left of it.
        let spec = args.dropFirst().joined(separator: " ")
        let leftOf = spec.contains("<")
        let parts = spec.split(whereSeparator: { $0 == ">" || $0 == "<" }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let items = discover()
        func find(_ q: String) -> Item? {
            if let id = UInt32(q) { return items.first { $0.windowID == id } }
            return items.first { $0.windowID != 0 && ($0.app.lowercased().contains(q) || $0.title.lowercased().contains(q)) }
        }
        guard parts.count == 2, let item = find(parts[0]), let target = find(parts[1]) else { say("not found"); break }
        func bounds(_ id: CGWindowID) -> CGRect? {
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let w = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
        }
        guard let start = bounds(item.windowID), let tb = bounds(target.windowID) else { say("no bounds"); break }
        let dest = CGPoint(x: leftOf ? tb.minX : tb.maxX, y: tb.minY)
        say("moving \(item.app) (win \(item.windowID) at \(Int(start.minX))) right of \(target.app) (maxX \(Int(tb.maxX))) pid \(item.pid)")
        let mode = CommandLine.arguments.contains("--hid") ? "hid" : "session+pid"
        let source = CGEventSource(stateID: .hidSystemState)
        let permit = CGEventSource(stateID: .combinedSessionState)
        permit?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        permit?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag)
        permit?.localEventsSuppressionInterval = 0
        let original = CGEvent(source: nil)?.location ?? .zero
        CGWarpMouseCursorPosition(dest)
        CGDisplayHideCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(20))
        func make(_ type: CGEventType, window: CGWindowID, flags: CGEventFlags) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: dest, mouseButton: .left) else { return nil }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            e.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: Int64(window))
            e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(item.pid))
            return e
        }
        func send(_ e: CGEvent) {
            if mode == "hid" { e.post(tap: .cghidEventTap) } else { e.post(tap: .cgSessionEventTap); e.postToPid(item.pid) }
        }
        if let down = make(.leftMouseDown, window: item.windowID, flags: .maskCommand) { send(down) }
        try? await Task.sleep(for: .milliseconds(120))
        let mid = bounds(item.windowID)
        for _ in 0..<2 {
            if let up = make(.leftMouseUp, window: target.windowID, flags: []) { send(up) }
            try? await Task.sleep(for: .milliseconds(40))
        }
        CGWarpMouseCursorPosition(original)
        CGDisplayShowCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(500))
        let end = bounds(item.windowID)
        let ax = item.ax.flatMap(axFrame)
        say("mode \(mode): window x \(Int(start.minX)) -> mid \(Int(mid?.minX ?? -1)) -> end \(Int(end?.minX ?? -1)); AX now x \(Int(ax?.minX ?? -1)); target maxX now \(Int(bounds(target.windowID)?.maxX ?? -1))")
    case "click2":
        // Click delivered to both the session stream and the owning process.
        let q = args.dropFirst().joined(separator: " ").lowercased()
        let items = discover()
        guard let t = (UInt32(q).flatMap { id in items.first { $0.windowID == id } }) ?? items.first(where: { $0.windowID != 0 && $0.app.lowercased().contains(q) }) else { say("not found"); break }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == t.windowID }),
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { say("no bounds"); break }
        let pt = CGPoint(x: b["X"]! + b["Width"]! / 2, y: b["Y"]! + b["Height"]! / 2)
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? .zero
        let before = menuWindows()
        CGWarpMouseCursorPosition(pt)
        CGDisplayHideCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(20))
        for (type, reps) in [(CGEventType.leftMouseDown, 1), (.leftMouseUp, 2)] {
            for _ in 0..<reps {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) else { continue }
                e.setIntegerValueField(.eventSourceUserData, value: Int64.random(in: 1...Int64.max))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(t.windowID))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(t.windowID))
                e.setIntegerValueField(.mouseEventClickState, value: 1)
                e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(t.pid))
                e.post(tap: .cgSessionEventTap)
                e.postToPid(t.pid)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        CGWarpMouseCursorPosition(original)
        CGDisplayShowCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(900))
        let new = menuWindows().filter { before[$0.key] == nil }
        say("clicked \(t.app) at \(Int(pt.x)): " + (new.isEmpty ? "no new windows" : new.values.sorted().joined(separator: "; ")))
        await screenshot("click2.png")
    case "menupress":
        // menupress <app> | <item title prefix>: AXPress a menu item while the menu stays closed.
        let parts = args.dropFirst().joined(separator: " ").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count == 2, let t = discover().first(where: { $0.app.lowercased().contains(parts[0]) }), let el = t.ax,
              let menu = (axValue(el, kAXChildrenAttribute) as [AXUIElement]?)?.first,
              let entries = axValue(menu, kAXChildrenAttribute) as [AXUIElement]?,
              let target = entries.first(where: { (axValue($0, kAXTitleAttribute) as String? ?? "").lowercased().hasPrefix(parts[1]) }) else {
            say("not found"); break
        }
        let before = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let beforeIDs = Set(before.compactMap { $0[kCGWindowNumber as String] as? Int })
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(900))
        let after = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let new = after.filter { !beforeIDs.contains($0[kCGWindowNumber as String] as? Int ?? 0) && ($0[kCGWindowOwnerPID as String] as? Int32) == t.pid }
        let title: String = axValue(target, kAXTitleAttribute) ?? ""
        say("pressed '\(title)' err \(err.rawValue); new \(t.app) windows: \(new.count)")
        let menuNow: [AXUIElement] = axValue(menu, kAXChildrenAttribute) ?? []
        say("titles now: " + menuNow.prefix(4).map { axValue($0, kAXTitleAttribute) as String? ?? "" }.joined(separator: " / "))
    case "actions":
        // List an item's AX actions (and its children's), then try each non-press one.
        let q = args.dropFirst().joined(separator: " ").lowercased()
        let items = discover()
        guard let t = items.first(where: { $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q) }), let el = t.ax else {
            say("no AX item for '\(q)'"); break
        }
        func names(_ e: AXUIElement) -> [String] {
            var arr: CFArray?
            AXUIElementCopyActionNames(e, &arr)
            return (arr as? [String]) ?? []
        }
        let role: String = axValue(el, kAXRoleAttribute) ?? "?"
        let subrole: String = axValue(el, kAXSubroleAttribute) ?? "-"
        say("\(t.app): role \(role)/\(subrole) actions \(names(el))")
        let kids: [AXUIElement] = axValue(el, kAXChildrenAttribute) ?? []
        for k in kids { say("  child \(axValue(k, kAXRoleAttribute) as String? ?? "?") actions \(names(k))") }
        for action in names(el) where action != kAXPressAction as String {
            let before = menuWindows()
            let err = AXUIElementPerformAction(el, action as CFString)
            try? await Task.sleep(for: .milliseconds(700))
            let new = menuWindows().filter { before[$0.key] == nil }
            say("  \(action): err \(err.rawValue) -> " + (new.isEmpty ? "nothing" : new.values.sorted().joined(separator: "; ")))
            if !new.isEmpty {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(t.pid) }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    case "hidclick":
        // Real click through the HID tap: warp the cursor onto the item (even under the
        // notch), stamp the item's window into the event, then put the cursor back.
        let q = args.dropFirst().joined(separator: " ").lowercased()
        let items = discover()
        guard let t = items.first(where: { $0.windowID != 0 && ($0.app.lowercased().contains(q) || $0.title.lowercased().contains(q)) }) else {
            say("no on-bar item for '\(q)'"); break
        }
        let ax = t.ax.flatMap(axFrame) ?? t.frame
        let pt = CGPoint(x: ax.midX, y: ax.midY)
        say("hid-clicking \(t.app) window \(t.windowID) at \(Int(pt.x)),\(Int(pt.y)) underNotch=\(t.underNotch)")
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag)
        source?.localEventsSuppressionInterval = 0
        let original = CGEvent(source: nil)?.location ?? .zero
        let before = menuWindows()
        CGWarpMouseCursorPosition(pt)
        CGDisplayHideCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(15))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pt, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(t.windowID))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(t.windowID))
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(40))
        }
        CGWarpMouseCursorPosition(original)
        CGDisplayShowCursor(CGMainDisplayID())
        try? await Task.sleep(for: .milliseconds(800))
        let new = menuWindows().filter { before[$0.key] == nil }
        say(new.isEmpty ? "no new windows" : "new windows:\n  " + new.values.sorted().joined(separator: "\n  "))
        await screenshot("hidclick.png")
        if !new.isEmpty, t.pid != 0 {
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.postToPid(t.pid) }
        }
    case "shot":
        // shot            -> whole display
        // shot <app name> -> each on-screen window of that app
        let q = args.dropFirst().joined(separator: " ").lowercased()
        if q.isEmpty { await screenshot("shot.png"); break }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter { ($0.owningApplication?.applicationName.lowercased() ?? "").contains(q) && $0.frame.height > 50 }
            for (i, w) in windows.enumerated() {
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
                let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("shot-\(i).png"))
                say("shot-\(i).png: \(w.title ?? "") \(Int(w.frame.width))x\(Int(w.frame.height))")
            }
            if windows.isEmpty { say("no windows for '\(q)'") }
        } catch { say("shot failed: \(error.localizedDescription)") }
    default:
        say("usage: prompt | list | capture | press <index|name>")
    }
    finish()
}
NSApp.run()
