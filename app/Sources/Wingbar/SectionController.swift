import AppKit
import WingbarCore

/// Wingbar's status items: the icon, and the dividers that hide everything
/// to their left by growing to `SectionState.collapsedLength`.
@MainActor
final class SectionController {
    enum Name {
        static let icon = "Wingbar.Icon"
        static let hiddenDivider = "Wingbar.HiddenDivider"
        static let alwaysHiddenDivider = "Wingbar.AlwaysHiddenDivider"
    }

    /// AppKit reads `NSStatusItem Preferred Position <autosaveName>` as roughly
    /// "points from the right edge" (0 = next to Control Centre), but items
    /// that were never ⌘-dragged have no saved position and slot in
    /// unpredictably around ones that do. So nothing can be placed precisely
    /// between other apps' items: the icon goes rightmost, each divider right
    /// beside it, and the user ⌘-drags items to arrange them.
    private enum Seed {
        static let version = 2
        static let icon = 0.0
        static let hiddenDivider = 1.0
        static let alwaysHiddenDivider = 2.0
    }

    let icon: NSStatusItem
    let hiddenDivider: NSStatusItem
    private(set) var alwaysHiddenDivider: NSStatusItem?

    private(set) var state: SectionState
    var onChange: ((SectionState) -> Void)?

    init() {
        if Settings.seededPositionsVersion < Seed.version {
            Settings.setPreferredPosition(Seed.icon, for: Name.icon)
            Settings.setPreferredPosition(Seed.hiddenDivider, for: Name.hiddenDivider)
            Settings.setPreferredPosition(Seed.alwaysHiddenDivider, for: Name.alwaysHiddenDivider)
            Settings.seededPositionsVersion = Seed.version
            // Every item starts out left of the new divider, so show them all
            // instead of hiding the user's whole menu bar.
            Settings.showsHidden = true
        }
        // Left Wing mode: hidden icons live in the Left Wing, so start closed.
        state = SectionState(showsHidden: Settings.showsHidden && !WingStore.shared.prefs.keepHiddenClosed)

        let bar = NSStatusBar.system
        icon = bar.statusItem(withLength: NSStatusItem.squareLength)
        icon.autosaveName = Name.icon
        // The icon can't be ⌘-dragged out of the bar: without it there'd be no way back.
        icon.behavior = []
        hiddenDivider = bar.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = Name.hiddenDivider
        hiddenDivider.behavior = []
        hiddenDivider.button?.toolTip = "Click for Wingbar settings. ⌘-drag icons across this line to hide or show them."
        if Settings.alwaysHiddenEnabled { addAlwaysHiddenDivider() }
        apply()
    }

    /// Window IDs of Wingbar's own items, so scans can skip them.
    var ownWindowIDs: Set<UInt32> {
        Set([icon, hiddenDivider, alwaysHiddenDivider].compactMap { item in
            // windowNumber can be negative or out of the window list's 32-bit range
            // for status items; the scanner also drops our items by pid, so skip those.
            item?.button?.window.flatMap { UInt32(exactly: $0.windowNumber) }
        })
    }

    /// Right edges of the dividers, in window-list coordinates, for `MenuBarSection.classify`.
    var dividerEdges: (hidden: CGFloat?, alwaysHidden: CGFloat?) {
        (hiddenDivider.button?.window?.frame.maxX, alwaysHiddenDivider?.button?.window?.frame.maxX)
    }

    func toggle(includingAlwaysHidden: Bool) {
        state.toggle(includingAlwaysHidden: includingAlwaysHidden && alwaysHiddenDivider != nil)
        apply()
    }

    func collapse() {
        guard state != SectionState() else { return }
        state.collapse()
        apply()
    }

    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        Settings.alwaysHiddenEnabled = enabled
        if enabled, alwaysHiddenDivider == nil {
            // Appears beside the hidden divider; the user drags it left from there.
            Settings.setPreferredPosition(Seed.alwaysHiddenDivider, for: Name.alwaysHiddenDivider)
            addAlwaysHiddenDivider()
            state.showsHidden = true
            state.showsAlwaysHidden = true
        } else if !enabled, let item = alwaysHiddenDivider {
            NSStatusBar.system.removeStatusItem(item)
            alwaysHiddenDivider = nil
            state.showsAlwaysHidden = false
        }
        apply()
    }

    /// Called when the always-hidden divider appears, so it can be wired up like the other.
    var onDividerAdded: ((NSStatusItem) -> Void)?

    private func addAlwaysHiddenDivider() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Name.alwaysHiddenDivider
        item.behavior = []
        item.button?.toolTip = "Click for Wingbar settings. Icons left of this line stay hidden until you Option-click Wingbar."
        alwaysHiddenDivider = item
        onDividerAdded?(item)
    }

    private func apply() {
        configure(hiddenDivider, length: state.length(of: .hidden), image: Self.dividerImage(dashed: false))
        if let alwaysHiddenDivider {
            configure(alwaysHiddenDivider, length: state.length(of: .alwaysHidden), image: Self.dividerImage(dashed: true))
        }
        updateIcon()
        Settings.showsHidden = state.showsHidden
        onChange?(state)
    }

    /// The Wingbar icon, in the style chosen in Settings; it shows whether the hidden section is open.
    func updateIcon() {
        let symbol: String
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        switch WingStore.shared.prefs.wingbarIconStyle {
        case .chevrons: symbol = state.showsHidden ? "chevron.right.2" : "chevron.left.2"
        case .dot:
            symbol = state.showsHidden ? "circle" : "circle.fill"
            config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        case .line: symbol = state.showsHidden ? "line.3.horizontal.decrease" : "line.3.horizontal"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.showsHidden ? "Hide items" : "Show hidden items")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        icon.button?.image = image
    }

    private func configure(_ item: NSStatusItem, length: CGFloat?, image: NSImage) {
        item.length = length ?? NSStatusItem.variableLength
        // A collapsed divider is an invisible spacer; an open one shows a thin line.
        item.button?.image = length == nil ? image : nil
    }

    private static func dividerImage(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: 1))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if dashed { path.setLineDash([2, 2.5], count: 2, phase: 0) }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
