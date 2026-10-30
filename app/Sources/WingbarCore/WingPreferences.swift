import Foundation

/// Everything the user can customize about where hidden icons appear.
/// Stored as one JSON blob so new options default sensibly for old installs.
public struct WingPreferences: Codable, Equatable, Sendable {
    // MARK: Left Wing
    /// Show icons macOS isn't drawing in the free space left of the notch.
    public var leftWingEnabled = true
    /// Draw scale for icons, 0.6...1.0.
    public var iconScale: Double = 1.0
    /// Extra points between icons, on top of each icon's own width.
    public var spacing: Double = 8
    public var alignment: WingAlignment = .towardNotch
    public var order: WingOrder = .menuBar
    /// Gap kept clear between the app's last menu and the first icon.
    public var gapAfterMenus: Double = 16
    public var background: WingBackground = .none
    /// How to draw an icon Wingbar can't capture (no Screen Recording, or parked items).
    public var fallbackIconStyle: FallbackIconStyle = .monochrome
    /// Refresh live icon images (clocks, CPU graphs) this often, in seconds; 0 = never.
    public var liveRefreshInterval: Double = 3
    /// When Wingbar uses Screen Recording to picture icons.
    public var iconPictures: IconPictureMode = .captureOnce
    /// Icons kept live even in capture-once mode (e.g. a CPU graph you keep in the Left Wing).
    public var liveItems: Set<String> = []
    /// Left Wing order when `order` is `.custom`; items not listed follow in menu bar order.
    public var customOrder: [String] = []
    public var visibility: WingVisibility = .always

    // MARK: Right side and behaviour
    /// Left Wing mode: keep everything left of Wingbar's line out of the menu bar
    /// (it shows in the Left Wing instead); clicking the icon still peeks.
    public var keepHiddenClosed = false
    /// How often Wingbar looks for icons that appeared, moved or vanished.
    public var scanInterval: Double = 2.5
    public var hotkey: HotkeyChoice = .none
    public var wingbarIconStyle: WingbarIconStyle = .chevrons

    // MARK: Overflow
    /// Where icons go when the Left Wing is full (or turned off).
    public var overflowStyle: OverflowStyle = .bar
    /// Hovering the notch shows every hidden icon below it.
    public var notchHoverEnabled = false
    public var notchHoverDelay: Double = 0.25

    /// For icons that ignore remote clicks: ⌘-drag them into view, click, and move them back.
    public var moveToOpen = true

    // MARK: Per item
    public var rules: [String: ItemRule] = [:]
    public var groups: [ItemGroup] = []
    /// Items that ignored every remote click; Wingbar reveals them instead of retrying.
    public var needsDirectClick: Set<String> = []

    public init() {}

    public func rule(for itemID: String) -> ItemRule {
        rules[itemID] ?? .automatic
    }

    public func group(containing itemID: String) -> ItemGroup? {
        groups.first { $0.itemIDs.contains(itemID) }
    }

    // Tolerate missing keys so adding an option never resets the others.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = WingPreferences()
        leftWingEnabled = try c.decodeIfPresent(Bool.self, forKey: .leftWingEnabled) ?? base.leftWingEnabled
        iconScale = try c.decodeIfPresent(Double.self, forKey: .iconScale) ?? base.iconScale
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? base.spacing
        alignment = try c.decodeIfPresent(WingAlignment.self, forKey: .alignment) ?? base.alignment
        order = try c.decodeIfPresent(WingOrder.self, forKey: .order) ?? base.order
        gapAfterMenus = try c.decodeIfPresent(Double.self, forKey: .gapAfterMenus) ?? base.gapAfterMenus
        background = try c.decodeIfPresent(WingBackground.self, forKey: .background) ?? base.background
        fallbackIconStyle = try c.decodeIfPresent(FallbackIconStyle.self, forKey: .fallbackIconStyle) ?? base.fallbackIconStyle
        liveRefreshInterval = try c.decodeIfPresent(Double.self, forKey: .liveRefreshInterval) ?? base.liveRefreshInterval
        iconPictures = try c.decodeIfPresent(IconPictureMode.self, forKey: .iconPictures) ?? base.iconPictures
        liveItems = try c.decodeIfPresent(Set<String>.self, forKey: .liveItems) ?? base.liveItems
        customOrder = try c.decodeIfPresent([String].self, forKey: .customOrder) ?? base.customOrder
        visibility = try c.decodeIfPresent(WingVisibility.self, forKey: .visibility) ?? base.visibility
        keepHiddenClosed = try c.decodeIfPresent(Bool.self, forKey: .keepHiddenClosed) ?? base.keepHiddenClosed
        scanInterval = try c.decodeIfPresent(Double.self, forKey: .scanInterval) ?? base.scanInterval
        hotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey) ?? base.hotkey
        wingbarIconStyle = try c.decodeIfPresent(WingbarIconStyle.self, forKey: .wingbarIconStyle) ?? base.wingbarIconStyle
        overflowStyle = try c.decodeIfPresent(OverflowStyle.self, forKey: .overflowStyle) ?? base.overflowStyle
        notchHoverEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchHoverEnabled) ?? base.notchHoverEnabled
        notchHoverDelay = try c.decodeIfPresent(Double.self, forKey: .notchHoverDelay) ?? base.notchHoverDelay
        moveToOpen = try c.decodeIfPresent(Bool.self, forKey: .moveToOpen) ?? base.moveToOpen
        rules = try c.decodeIfPresent([String: ItemRule].self, forKey: .rules) ?? base.rules
        groups = try c.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? base.groups
        needsDirectClick = try c.decodeIfPresent(Set<String>.self, forKey: .needsDirectClick) ?? base.needsDirectClick
    }
}

public enum WingAlignment: String, Codable, CaseIterable, Sendable {
    /// Packed against the notch, as if the menu bar continued past it.
    case towardNotch
    /// Packed right after the app's menus.
    case afterMenus

    public var title: String {
        switch self {
        case .towardNotch: "Next to the notch"
        case .afterMenus: "After app menus"
        }
    }
}

public enum WingOrder: String, Codable, CaseIterable, Sendable {
    /// The order the items have in the menu bar.
    case menuBar
    case alphabetical
    case custom

    public var title: String {
        switch self {
        case .menuBar: "Menu bar order"
        case .alphabetical: "Alphabetical"
        case .custom: "Custom (Arrange tab)"
        }
    }
}

public enum IconPictureMode: String, Codable, CaseIterable, Sendable {
    /// Capture each icon once (and when the menu bar switches light/dark), keep it on disk.
    case captureOnce
    /// Keep capturing so changing icons (clocks, graphs) stay current.
    case live
    /// Never use Screen Recording; show monochrome app icons.
    case off

    public var title: String {
        switch self {
        case .captureOnce: "Capture once, then reuse"
        case .live: "Live (keep updating)"
        case .off: "Off (app icons, no Screen Recording)"
        }
    }
}

public enum WingVisibility: String, Codable, CaseIterable, Sendable {
    case always
    /// Only while the pointer is over the menu bar.
    case onHover

    public var title: String {
        switch self {
        case .always: "Always"
        case .onHover: "When the pointer is on the menu bar"
        }
    }
}

public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case none, optionCommandB, controlOptionSpace, controlOptionCommandM

    public var title: String {
        switch self {
        case .none: "None"
        case .optionCommandB: "⌥⌘B"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionCommandM: "⌃⌥⌘M"
        }
    }
}

public enum WingbarIconStyle: String, Codable, CaseIterable, Sendable {
    case chevrons, dot, line

    public var title: String {
        switch self {
        case .chevrons: "Chevrons «"
        case .dot: "Dot"
        case .line: "Bar"
        }
    }
}

public enum WingOrdering {
    /// Items in the order the Left Wing shows them, left to right.
    public static func sorted(_ items: [MenuBarItem], by prefs: WingPreferences) -> [MenuBarItem] {
        // Menu bar order; parked items have no place in the bar, so furthest from the notch.
        let byBar = items.sorted { ($0.placement == .parked ? 0 : 1, $0.frame.minX) < ($1.placement == .parked ? 0 : 1, $1.frame.minX) }
        switch prefs.order {
        case .menuBar:
            return byBar
        case .alphabetical:
            return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .custom:
            let rank = Dictionary(prefs.customOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let listed = byBar.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            return listed + byBar.filter { rank[$0.id] == nil }
        }
    }
}

public enum WingBackground: String, Codable, CaseIterable, Sendable {
    /// Icons sit directly on the menu bar, like native ones.
    case none
    /// A faint rounded pill behind the Left Wing.
    case pill
    /// A thin line separating the wing from the app menus.
    case separator

    public var title: String {
        switch self {
        case .none: "None (native)"
        case .pill: "Subtle pill"
        case .separator: "Separator line"
        }
    }
}

public enum FallbackIconStyle: String, Codable, CaseIterable, Sendable {
    /// App icon tinted to the menu bar's text color, like native menu bar icons.
    case monochrome
    /// The app's full-color icon.
    case color

    public var title: String {
        switch self {
        case .monochrome: "Monochrome (native)"
        case .color: "App icon in color"
        }
    }
}

public enum OverflowStyle: String, Codable, CaseIterable, Sendable {
    /// A row of icons in a small bar below the notch.
    case bar
    /// A menu-like list with each icon's name.
    case list

    public var title: String {
        switch self {
        case .bar: "Icon bar"
        case .list: "List with names"
        }
    }
}

/// Where one item may appear.
public enum ItemRule: String, Codable, CaseIterable, Sendable {
    /// Left Wing when there's room, otherwise the overflow.
    case automatic
    /// Never in the Left Wing; only in the overflow / notch hover.
    case overflowOnly
    /// Not shown by Wingbar at all.
    case never

    public var title: String {
        switch self {
        case .automatic: "Show"
        case .overflowOnly: "Overflow only"
        case .never: "Don't show"
        }
    }
}

/// User-made folder of items, shown as one icon that opens the rest.
public struct ItemGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol for the group's icon.
    public var symbol: String
    public var itemIDs: [String]

    public init(id: UUID = UUID(), name: String, symbol: String = "square.grid.2x2", itemIDs: [String] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.itemIDs = itemIDs
    }
}
