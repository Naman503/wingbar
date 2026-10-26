import CoreGraphics

/// The user's sections, right to left:
/// `[Wingbar icon] visible items | hidden items ‖ always-hidden items`.
/// The two dividers are Wingbar's own status items; everything left of a
/// divider belongs to the section behind it.
public enum MenuBarSection: String, Sendable, CaseIterable, Identifiable {
    case visible, hidden, alwaysHidden

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always hidden"
        }
    }

    /// Dividers are compared by their right edge: a collapsed divider stretches
    /// far to the left, but its right edge stays where the user put it.
    /// - Parameters:
    ///   - itemMinX: the item's left edge (window list frame).
    ///   - hiddenDividerMaxX / alwaysHiddenDividerMaxX: the dividers' right edges, if known.
    public static func classify(itemMinX: CGFloat, hiddenDividerMaxX: CGFloat?, alwaysHiddenDividerMaxX: CGFloat?) -> MenuBarSection {
        if let a = alwaysHiddenDividerMaxX, itemMinX < a { return .alwaysHidden }
        if let h = hiddenDividerMaxX, itemMinX < h { return .hidden }
        return .visible
    }
}

/// What is currently revealed. Drives the divider lengths.
public struct SectionState: Equatable, Sendable {
    public var showsHidden: Bool
    public var showsAlwaysHidden: Bool

    public init(showsHidden: Bool = false, showsAlwaysHidden: Bool = false) {
        self.showsHidden = showsHidden
        self.showsAlwaysHidden = showsAlwaysHidden
    }

    /// A divider this long pushes every item to its left off screen
    /// (the window server clamps it to roughly the display span).
    public static let collapsedLength: CGFloat = 10_000

    public enum Divider { case hidden, alwaysHidden }

    /// nil means "natural width" (`NSStatusItem.variableLength`).
    public func length(of divider: Divider) -> CGFloat? {
        switch divider {
        case .hidden: showsHidden ? nil : Self.collapsedLength
        // Showing always-hidden items implies showing hidden ones too.
        case .alwaysHidden: showsHidden && showsAlwaysHidden ? nil : Self.collapsedLength
        }
    }

    /// Clicking the Wingbar icon. Option-click also reveals the always-hidden section.
    public mutating func toggle(includingAlwaysHidden: Bool) {
        if includingAlwaysHidden {
            let show = !(showsHidden && showsAlwaysHidden)
            showsHidden = show
            showsAlwaysHidden = show
        } else {
            showsHidden.toggle()
            if !showsHidden { showsAlwaysHidden = false }
        }
    }

    public mutating func collapse() {
        showsHidden = false
        showsAlwaysHidden = false
    }
}

