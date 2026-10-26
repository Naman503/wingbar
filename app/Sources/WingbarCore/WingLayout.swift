import CoreGraphics

/// Something that can take a slot in the Left Wing: a single item or a group.
public struct WingEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case item(String)
        case group(ItemGroupID)
    }

    public typealias ItemGroupID = String

    public let kind: Kind
    /// Drawn width in points (already scaled), without spacing.
    public let width: CGFloat
    /// Items that must not sit in the wing go straight to the overflow.
    public let overflowOnly: Bool

    public init(kind: Kind, width: CGFloat, overflowOnly: Bool = false) {
        self.kind = kind
        self.width = width
        self.overflowOnly = overflowOnly
    }
}

public struct WingSlot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case entry(WingEntry.Kind)
        /// The "»" button that opens the overflow.
        case overflow
    }

    public let kind: Kind
    public let x: CGFloat
    public let width: CGFloat
}

public struct WingLayoutResult: Equatable, Sendable {
    public var slots: [WingSlot] = []
    /// Entries that didn't fit (or must not be in the wing), in display order.
    public var overflow: [WingEntry.Kind] = []

    public var isEmpty: Bool { slots.isEmpty }
}

public enum WingLayout {
    /// The free span of the left wing: after the app menus (plus a gap) up to the
    /// notch (minus a small margin). nil when there's no notch or no room at all.
    public static func region(notch: NotchGeometry, appMenusMaxX: CGFloat, gapAfterMenus: CGFloat, notchMargin: CGFloat = 8) -> ClosedRange<CGFloat>? {
        guard let span = notch.notchSpan else { return nil }
        let start = max(appMenusMaxX + gapAfterMenus, notch.screenFrame.minX)
        let end = span.lowerBound - notchMargin
        return end > start ? start...end : nil
    }

    /// Lays entries out in `region`, given in display order (left to right).
    ///
    /// Entries nearest the notch are kept first, since they continue the menu bar
    /// past it. When not everything fits, the leftmost ones are replaced by an
    /// overflow button.
    public static func layout(
        entries: [WingEntry],
        region: ClosedRange<CGFloat>?,
        spacing: CGFloat,
        overflowButtonWidth: CGFloat,
        alignment: WingAlignment
    ) -> WingLayoutResult {
        var result = WingLayoutResult()
        let candidates = entries.filter { !$0.overflowOnly }
        let forced = entries.filter(\.overflowOnly).map(\.kind)
        guard let region, !entries.isEmpty else {
            result.overflow = entries.map(\.kind)
            return result
        }
        let available = region.upperBound - region.lowerBound

        func width(of list: ArraySlice<WingEntry>) -> CGFloat {
            list.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(list.count - 1, 0))
        }

        // Keep as many entries as fit, counting from the notch side.
        var kept = candidates[...]
        var dropped = [WingEntry]()
        let needsButton = { (keptCount: Int) in keptCount < candidates.count || !forced.isEmpty }
        while !kept.isEmpty {
            let buttonWidth = needsButton(kept.count) ? overflowButtonWidth + spacing : 0
            if width(of: kept) + buttonWidth <= available { break }
            dropped.append(kept.removeFirst())
        }
        let showButton = needsButton(kept.count)
        if kept.isEmpty, showButton, overflowButtonWidth > available {
            result.overflow = entries.map(\.kind)
            return result
        }

        let total = width(of: kept) + (showButton ? overflowButtonWidth + (kept.isEmpty ? 0 : spacing) : 0)
        var x = alignment == .towardNotch ? region.upperBound - total : region.lowerBound
        if showButton {
            result.slots.append(WingSlot(kind: .overflow, x: x, width: overflowButtonWidth))
            x += overflowButtonWidth + spacing
        }
        for entry in kept {
            result.slots.append(WingSlot(kind: .entry(entry.kind), x: x, width: entry.width))
            x += entry.width + spacing
        }
        result.overflow = dropped.map(\.kind) + forced
        return result
    }
}
