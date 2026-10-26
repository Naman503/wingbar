import AppKit

/// Borderless, non-activating panel for drawing on or near the menu bar.
/// Clicking it never steals focus from the app you're in.
class BarPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.level = level
        // No .fullScreenAuxiliary: nothing of Wingbar's shows over a full-screen app,
        // where the menu bar (and the space it would sit in) is gone.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One icon, drawn like a native menu bar item: no hover effect, a rounded
/// highlight while pressed or while its menu is open.
final class WingButton: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Horizontal inset of the highlight from the button's edges.
    var highlightInset: CGFloat = 0
    var isHighlighted = false { didSet { needsDisplay = true } }
    var onClick: ((WingButton) -> Void)?
    var onRightClick: ((WingButton, NSEvent) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        isHighlighted = true
        onClick?(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        isHighlighted = true
        onRightClick?(self, event)
        isHighlighted = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The window server sends clicks on fully transparent pixels to whatever is
        // below, so give the whole button a 1/255 fill: invisible, but hit-testable.
        NSColor.black.withAlphaComponent(1 / 255).setFill()
        bounds.fill()
        if isHighlighted {
            let height = min(bounds.height - 8, 26)
            let rect = NSRect(x: highlightInset, y: (bounds.height - height) / 2, width: bounds.width - highlightInset * 2, height: height)
            (dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
        guard let image else { return }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        if image.isTemplate {
            Self.tinted(image, with: dark ? .white : .black).draw(in: rect)
        } else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    static func tinted(_ image: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// A row in the list-style overflow: icon + name, highlighted on hover like a menu item.
final class WingRow: NSView {
    let icon: NSImage?
    let title: String
    var onClick: ((WingRow) -> Void)?
    var onRightClick: ((WingRow, NSEvent) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    init(icon: NSImage?, title: String) {
        self.icon = icon
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        onClick?(self)
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(self, event) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let textColor: NSColor = hovering ? .white : .labelColor
        if let icon {
            // Captured icons keep the bar's height; fit them in a 30 × 20 box.
            let ratio = icon.size.width / max(icon.size.height, 1)
            var h: CGFloat = 20, w = h * ratio
            if w > 30 { w = 30; h = w / ratio }
            let rect = NSRect(x: 12 + (30 - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            if icon.isTemplate { WingButton.tinted(icon, with: textColor).draw(in: rect) } else {
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: textColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 52, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }

    static func width(for title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width + 52 + 18
    }
}

/// Rounded, translucent container matching system menus: Liquid Glass on macOS 26,
/// the menu material before that.
enum GlassBackground {
    static func make(cornerRadius: CGFloat, content: NSView) -> NSView {
        // NSGlassEffectView is in the macOS 26 SDK (Swift 6.2 toolchains); older
        // Xcodes, like CI's, build the material fallback only.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.addSubview(content)
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        return effect
    }
}

/// View that reports when the pointer enters or leaves it (for hover panels).
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    /// Fill so the pointer registers (fully transparent pixels pass events through).
    /// Black is invisible over the notch, which is black hardware.
    var fill: NSColor = NSColor.black.withAlphaComponent(1 / 255)

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// A small glass bubble with a message, shown below a point and dismissed after a few seconds.
@MainActor
final class HintBubble {
    private let panel = BarPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, below point: NSPoint, on screen: NSScreen) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 280
        let size = label.fittingSize
        let padding = NSSize(width: 14, height: 9)
        let frameSize = NSSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        let content = NSView(frame: NSRect(origin: .zero, size: frameSize))
        label.frame = NSRect(x: padding.width, y: padding.height, width: size.width, height: size.height)
        content.addSubview(label)
        let glass = GlassBackground.make(cornerRadius: 12, content: content)
        glass.frame = content.frame
        panel.contentView = glass
        panel.hasShadow = true
        var origin = NSPoint(x: point.x - frameSize.width / 2, y: point.y - frameSize.height - 6)
        origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - frameSize.width - 8)
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}
