import CoreGraphics

/// A status-item window from the window list (layer 25, on the menu bar).
/// On macOS 26 every one of these is owned by Control Centre, so the window
/// alone does not say which app the item belongs to.
public struct StatusWindow: Equatable, Sendable {
    public let windowID: UInt32
    public let frame: CGRect
    public let isOnScreen: Bool

    public init(windowID: UInt32, frame: CGRect, isOnScreen: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

/// A child of some app's accessibility "extras menu bar": one status item, with
/// its real owner. Its frame is the icon, inset a few points inside the window.
public struct StatusExtra: Equatable, Sendable {
    public let frame: CGRect
    public let pid: Int32
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let identifier: String?

    public init(frame: CGRect, pid: Int32, appName: String, bundleID: String?, title: String, identifier: String?) {
        self.frame = frame
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.identifier = identifier
    }
}

/// Why an item is or isn't drawn.
public enum ItemPlacement: String, Sendable, CaseIterable {
    /// Drawn in the menu bar.
    case visible
    /// Has a window, but it sits under the notch, so macOS doesn't draw it.
    case underNotch
    /// Has a window that macOS keeps off screen for another reason (e.g. app menus overlap it).
    case offScreen
    /// macOS couldn't fit it at all: no window on the bar, only an off-screen AX element.
    case parked
}

public struct MenuBarItem: Identifiable, Equatable, Sendable {
    /// Stable across launches: app + fixed item identifier + occurrence index.
    public let id: String
    public let windowID: UInt32?
    public let frame: CGRect
    public let pid: Int32
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let identifier: String?
    public let placement: ItemPlacement
    /// Index into the `extras` array the item was built from (to find its AX element).
    public let extraIndex: Int?

    public var displayName: String {
        // Apple's items all belong to Control Centre or SystemUIServer; their title says what they are.
        if bundleID?.hasPrefix("com.apple.") == true, !title.isEmpty { return title }
        return title.isEmpty || title == appName ? appName : "\(appName) – \(title)"
    }
}

public enum ItemMatcher {
    /// Builds the item list from AX extras, which always have the real position.
    /// Right after the bar changes, the window list can still report old frames,
    /// so a window is only used for its ID and on-screen flag: it belongs to the
    /// extra whose icon centre it contains. Every status item has an AX element,
    /// so leftover windows are stale entries; they're listed (as "Unknown") only
    /// when there are no extras at all, i.e. without Accessibility permission.
    public static func match(windows: [StatusWindow], extras: [StatusExtra], notch: NotchGeometry?) -> [MenuBarItem] {
        var usedWindows = Set<UInt32>()
        var items = [MenuBarItem]()
        var seen = [String: Int]()

        func makeID(_ extra: StatusExtra?) -> String {
            // Titles can be live values ("47%"), so only fixed identity goes in the ID;
            // an app's untitled items are told apart by their order.
            let base = "\(extra?.bundleID ?? extra?.appName ?? "unknown")|\(extra?.identifier ?? "")"
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return n == 0 ? base : "\(base)#\(n)"
        }

        let menuBarHeight: CGFloat = 50
        // Pass 1: the window that contains the icon's centre.
        var windowFor = [Int: StatusWindow]()
        for (i, extra) in extras.enumerated() where extra.frame.width > 0 && extra.frame.midY < menuBarHeight {
            if let window = windows.first(where: { w in
                !usedWindows.contains(w.windowID) && w.frame.minX <= extra.frame.midX && extra.frame.midX <= w.frame.maxX
            }) {
                usedWindows.insert(window.windowID)
                windowFor[i] = window
            }
        }
        // Pass 2: right after the bar re-lays out, window frames lag behind, so
        // some icons find no window (and pass 1 may have paired neighbours).
        // The left-to-right order doesn't lag, so if every icon on the bar has
        // a window to pair with, pair them all in order.
        let onBar = extras.indices.filter { extras[$0].frame.width > 0 && extras[$0].frame.midY < menuBarHeight }
        if onBar.contains(where: { windowFor[$0] == nil }), onBar.count == windows.count {
            let sortedExtras = onBar.sorted { extras[$0].frame.minX < extras[$1].frame.minX }
            let sortedWindows = windows.sorted { $0.frame.minX < $1.frame.minX }
            windowFor = Dictionary(uniqueKeysWithValues: zip(sortedExtras, sortedWindows).map { ($0, $1) })
            usedWindows = Set(sortedWindows.map(\.windowID))
        }

        for (i, extra) in extras.enumerated() where extra.frame.width > 0 {
            let window = windowFor[i]

            let placement: ItemPlacement
            if extra.frame.minY >= menuBarHeight {
                // macOS parks items it can't fit below the bar, with no window.
                placement = .parked
            } else if let screen = notch?.screenFrame, extra.frame.maxX <= screen.minX || extra.frame.minX >= screen.maxX {
                placement = .offScreen
            } else if notch?.isUnderNotch(extra.frame) == true {
                placement = .underNotch
            } else if window?.isOnScreen == false {
                placement = .offScreen
            } else {
                placement = .visible
            }
            items.append(MenuBarItem(
                id: makeID(extra), windowID: window?.windowID, frame: extra.frame,
                pid: extra.pid, appName: extra.appName, bundleID: extra.bundleID,
                title: extra.title, identifier: extra.identifier,
                placement: placement, extraIndex: i))
        }
        for window in windows where extras.isEmpty && window.isOnScreen {
            items.append(MenuBarItem(
                id: makeID(nil), windowID: window.windowID, frame: window.frame,
                pid: 0, appName: "Unknown", bundleID: nil, title: "", identifier: nil,
                placement: notch?.isUnderNotch(window.frame) == true ? .underNotch : .visible, extraIndex: nil))
        }
        return items.sorted { a, b in
            (a.placement == .parked ? 1 : 0, a.frame.minX) < (b.placement == .parked ? 1 : 0, b.frame.minX)
        }
    }
}
