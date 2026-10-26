import AppKit
import Combine
import WingbarCore

/// Shows the icons macOS isn't drawing (under the notch, parked, or behind
/// Wingbar's collapsed divider) in the free menu bar space left of the notch,
/// with an overflow bar for whatever doesn't fit, and opens them on click.
@MainActor
final class LeftWingController {
    private let sections: SectionController
    private let store = WingStore.shared
    private let images = ItemImageCache()
    private let hint = HintBubble()
    private let mover = MoveEngine()
    /// True while an icon is moved into view; auto-hide waits for it.
    private(set) var isRevealing = false

    private let wingPanel = BarPanel(level: .statusBar)
    private let notchPanel = BarPanel(level: .statusBar)
    private let overflowPanel = BarPanel(level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))

    private var scan = ScanResult()
    /// Items Wingbar shows (not drawn by macOS, not ruled out), in display order.
    private(set) var hiddenItems: [MenuBarItem] = []
    private var overflowKinds: [WingEntry.Kind] = []
    private var appMenusMaxX: CGFloat?
    private var menuBarVisible = true

    private var tickTimer: Timer?
    private var scanTimer: Timer?
    private var imageTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTask: Task<Void, Never>?
    private var overflowAnchor: OverflowAnchor?
    private var pointerInOverflow = false
    private var pointerInNotch = false
    private var clickMonitor: Any?
    var openSettings: (() -> Void)?

    private enum OverflowAnchor: Equatable {
        case notch
        case button(NSRect)
        case group(UUID, NSRect)
    }

    init(sections: SectionController) {
        self.sections = sections
    }

    var prefs: WingPreferences { store.prefs }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(); self?.rescan() }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        store.$prefs.dropFirst().receive(on: RunLoop.main).sink { [weak self] prefs in
            MainActor.assumeIsolated {
                guard let self else { return }
                let old = self.lastPrefs
                self.lastPrefs = prefs
                self.restartImageTimer()
                if old.scanInterval != prefs.scanInterval { self.restartScanTimer() }
                if old.visibility != prefs.visibility { self.updateHoverMonitor() }
                if old.iconPictures != prefs.iconPictures || old.liveItems != prefs.liveItems { self.rescan() }
                self.rebuild()
                self.setUpNotchPanel()
            }
        }.store(in: &cancellables)

        // Cheap checks every second: app menu width and menu bar visibility.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        restartScanTimer()
        restartImageTimer()
        updateHoverMonitor()
        setUpNotchPanel()
        tick()
        rescan()
    }

    /// Called when the hidden section opens or closes; items move a moment later.
    func sectionsChanged() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            rescan()
        }
    }

    // MARK: - Refresh

    private lazy var lastPrefs = prefs
    private var hoverMonitors: [Any] = []
    private var pointerOnBar = false

    /// Full item scan; items appear, disappear and move as apps launch and quit.
    private func restartScanTimer() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: max(prefs.scanInterval, 1), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRevealing else { return }
                self.rescan()
            }
        }
    }

    /// "When the pointer is on the menu bar": watch the pointer and fade the wing in and out.
    private func updateHoverMonitor() {
        hoverMonitors.forEach(NSEvent.removeMonitor)
        hoverMonitors = []
        guard prefs.visibility == .onHover else {
            wingPanel.alphaValue = 1
            return
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) { hoverMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { handler($0); return $0 }) { hoverMonitors.append(local) }
        pointerMoved()
    }

    private func pointerMoved() {
        guard let bar = sections.icon.button?.window?.frame else { return }
        let onBar = NSEvent.mouseLocation.y >= bar.minY - 2
        guard onBar != pointerOnBar || wingPanel.alphaValue == (onBar ? 0 : 1) else { return }
        pointerOnBar = onBar
        NSAnimationContext.runAnimationGroup { context in
            context.duration = onBar ? 0.12 : 0.35
            wingPanel.animator().alphaValue = onBar ? 1 : 0
        }
    }

    private func tick() {
        let maxX = MenuBarState.appMenusMaxX()
        let visible = MenuBarState.isMenuBarVisible()
        if let anchor = sections.icon.button?.effectiveAppearance {
            wingPanel.appearance = anchor
            // Pictures carry the bar's look; when it flips light/dark, use (or take) the other set.
            let look = anchor.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
            if look != images.appearance {
                images.appearance = look
                rescan()
            }
        }
        guard maxX != appMenusMaxX || visible != menuBarVisible else { return }
        appMenusMaxX = maxX
        menuBarVisible = visible
        rebuild()
    }

    private func rescan() {
        let own = sections.ownWindowIDs
        Task {
            let result = await MenuBarScanner.scanInBackground(excluding: own)
            scan = result
            let prefs = self.prefs
            hiddenItems = result.items.filter { $0.placement != .visible && prefs.rule(for: $0.id) != .never }
            await images.refresh(hiddenItems, prefs: prefs)
            rebuild()
            setUpNotchPanel()
        }
    }

    private func restartImageTimer() {
        imageTimer?.invalidate()
        imageTimer = nil
        // Only live pictures need a timer: everything (live mode) or the icons marked live.
        let interval = prefs.liveRefreshInterval
        let anyLive = prefs.iconPictures == .live || (prefs.iconPictures == .captureOnce && !prefs.liveItems.isEmpty)
        guard interval > 0, anyLive else { return }
        imageTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wingPanel.isVisible || self.overflowPanel.isVisible else { return }
                Task {
                    let resized = await self.images.refresh(self.hiddenItems, prefs: self.prefs)
                    if resized { self.rebuild() } else { self.refreshImagesInPlace() }
                }
            }
        }
    }

    // MARK: - Entries

    private var scaleFactor: CGFloat { CGFloat(prefs.iconScale) }

    func displayImage(for item: MenuBarItem) -> NSImage? {
        if let image = images.image(for: item) { return image }
        // No capture (no Screen Recording, or a parked item without a window): app icon.
        guard let appIcon = NSRunningApplication(processIdentifier: item.pid)?.icon else { return nil }
        let side: CGFloat = prefs.fallbackIconStyle == .monochrome ? 16 : 17
        if prefs.fallbackIconStyle == .monochrome, let mono = Self.monochrome(appIcon, side: side) { return mono }
        let icon = appIcon.copy() as! NSImage
        icon.size = NSSize(width: side, height: side)
        return icon
    }

    /// The app icon as a template: brightness becomes opacity, so it takes the
    /// menu bar's text color like a native item instead of a colored tile.
    private static func monochrome(_ icon: NSImage, side: CGFloat) -> NSImage? {
        let px = Int(side * 2)
        guard let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: px * px * 4) else { return nil }
        // Brightness becomes opacity. Most app icons are a light glyph on a darker
        // tile or the reverse, so try both polarities and keep the smaller shape
        // (the glyph), unless it's nearly empty; a solid tile reads as noise.
        let count = px * px
        var lum = [Double](repeating: 0, count: count), alpha = [Double](repeating: 0, count: count)
        for p in 0..<count {
            let a = Double(data[p * 4 + 3]) / 255
            alpha[p] = a
            guard a > 0 else { continue }
            lum[p] = (0.299 * Double(data[p * 4]) + 0.587 * Double(data[p * 4 + 1]) + 0.114 * Double(data[p * 4 + 2])) / (255 * a)
        }
        func coverage(_ invert: Bool) -> Double {
            var sum = 0.0
            for p in 0..<count { sum += max(0, min(1, ((invert ? 1 - lum[p] : lum[p]) - 0.25) / 0.6)) * alpha[p] }
            return sum / Double(count)
        }
        let plain = coverage(false), inverted = coverage(true)
        let invert = min(plain, inverted) < 0.04 ? inverted > plain : inverted < plain
        for p in 0..<count {
            let l = invert ? 1 - lum[p] : lum[p]
            data[p * 4] = 0; data[p * 4 + 1] = 0; data[p * 4 + 2] = 0
            data[p * 4 + 3] = UInt8(max(0, min(1, (l - 0.25) / 0.6)) * alpha[p] * 255)
        }
        guard let out = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: out, size: NSSize(width: side, height: side))
        image.isTemplate = true
        return image
    }

    private func groupImage(_ group: ItemGroup) -> NSImage? {
        let image = NSImage(systemSymbolName: group.symbol, accessibilityDescription: group.name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        return image
    }

    /// Items (and groups standing in for their members) in display order.
    private func entries() -> [WingEntry] {
        let ordered = WingOrdering.sorted(hiddenItems, by: prefs)
        var result = [WingEntry]()
        var placedGroups = Set<UUID>()
        for item in ordered {
            if let group = prefs.group(containing: item.id) {
                guard placedGroups.insert(group.id).inserted else { continue }
                let width = (groupImage(group)?.size.width ?? 18) * scaleFactor
                result.append(WingEntry(kind: .group(group.id.uuidString), width: width))
            } else {
                let width = (displayImage(for: item)?.size.width ?? 18) * scaleFactor
                result.append(WingEntry(kind: .item(item.id), width: width, overflowOnly: prefs.rule(for: item.id) == .overflowOnly))
            }
        }
        return result
    }

    private func item(_ id: String) -> MenuBarItem? {
        hiddenItems.first { $0.id == id }
    }

    private func members(of groupID: String) -> [MenuBarItem] {
        guard let group = prefs.groups.first(where: { $0.id.uuidString == groupID }) else { return [] }
        return group.itemIDs.compactMap(item)
    }

    /// Overflow entries with groups expanded into their members.
    private func flattened(_ kinds: [WingEntry.Kind]) -> [MenuBarItem] {
        kinds.flatMap { kind -> [MenuBarItem] in
            switch kind {
            case let .item(id): item(id).map { [$0] } ?? []
            case let .group(id): members(of: id)
            }
        }
    }

    // MARK: - Left Wing

    private func rebuild() {
        let entries = entries()
        guard let notch = scan.notch ?? MenuBarScanner.currentNotch(),
              let screen = NSScreen.screens.first(where: { $0.frame == notch.screenFrame }),
              let bar = sections.icon.button?.window?.frame,
              prefs.leftWingEnabled, menuBarVisible, let menusMaxX = appMenusMaxX else {
            wingPanel.orderOut(nil)
            overflowKinds = entries.map(\.kind)
            return
        }
        let spacing = CGFloat(prefs.spacing)
        let region = WingLayout.region(notch: notch, appMenusMaxX: menusMaxX, gapAfterMenus: CGFloat(prefs.gapAfterMenus))
        let layout = WingLayout.layout(entries: entries, region: region, spacing: spacing,
                                       overflowButtonWidth: 18 * scaleFactor, alignment: prefs.alignment)
        overflowKinds = layout.overflow
        guard let first = layout.slots.first, let last = layout.slots.last else {
            wingPanel.orderOut(nil)
            return
        }

        // Panel spans the slots plus half the spacing on each side, at the menu bar's height.
        let pad = max(spacing / 2, 4)
        let minX = first.x - pad, maxX = last.x + last.width + pad
        let frame = NSRect(x: minX, y: bar.minY, width: maxX - minX, height: bar.height)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        if prefs.background == .pill {
            content.wantsLayer = true
            content.layer?.cornerRadius = min(frame.height - 10, 24) / 2
            content.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            content.frame = content.frame
        }
        for slot in layout.slots {
            let button = WingButton(frame: NSRect(x: slot.x - minX - pad, y: 0, width: slot.width + pad * 2, height: frame.height))
            button.scale = scaleFactor
            button.highlightInset = max(pad - 5, 0)
            switch slot.kind {
            case .overflow:
                let image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: "More icons")?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
                image?.isTemplate = true
                button.image = image
                button.toolTip = "\(flattened(overflowKinds).count) more"
                button.onClick = { [weak self] b in self?.toggleOverflow(.button(self?.screenRect(of: b) ?? .zero)); b.isHighlighted = false }
            case let .entry(.item(id)):
                guard let item = item(id) else { continue }
                button.image = displayImage(for: item)
                button.toolTip = item.displayName
                button.identifier = NSUserInterfaceItemIdentifier(id)
                button.onClick = { [weak self] b in self?.activate(item, from: b) }
                button.onRightClick = { [weak self] b, event in self?.showContextMenu(for: item, event: event, in: b) }
            case let .entry(.group(id)):
                guard let group = prefs.groups.first(where: { $0.id.uuidString == id }) else { continue }
                button.image = groupImage(group)
                button.toolTip = "\(group.name) (\(members(of: id).count))"
                button.onClick = { [weak self] b in
                    self?.toggleOverflow(.group(group.id, self?.screenRect(of: b) ?? .zero))
                    b.isHighlighted = false
                }
            }
            content.addSubview(button)
        }
        if prefs.background == .separator {
            let line = NSBox(frame: NSRect(x: 0, y: (frame.height - 16) / 2, width: 1, height: 16))
            line.boxType = .separator
            content.addSubview(line)
        }
        wingPanel.contentView = content
        wingPanel.appearance = sections.icon.button?.effectiveAppearance
        wingPanel.setFrame(frame, display: true)
        if wingPanel.screen != screen || !wingPanel.isVisible { wingPanel.orderFrontRegardless() }
    }

    private func refreshImagesInPlace() {
        for case let button as WingButton in wingPanel.contentView?.subviews ?? [] {
            guard let id = button.identifier?.rawValue, let item = item(id) else { continue }
            button.image = displayImage(for: item)
        }
    }

    private func screenRect(of view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: - Notch hover

    private func setUpNotchPanel() {
        guard prefs.notchHoverEnabled, let notch = MenuBarScanner.currentNotch(), let span = notch.notchSpan,
              let bar = sections.icon.button?.window?.frame else {
            notchPanel.orderOut(nil)
            return
        }
        let frame = NSRect(x: span.lowerBound, y: bar.minY, width: span.upperBound - span.lowerBound, height: bar.height)
        if notchPanel.frame != frame || notchPanel.contentView == nil {
            let view = HoverView(frame: NSRect(origin: .zero, size: frame.size))
            view.onEnter = { [weak self] in self?.notchHover(true) }
            view.onExit = { [weak self] in self?.notchHover(false) }
            view.onClick = { [weak self] in self?.toggleOverflow(.notch) }
            notchPanel.contentView = view
            notchPanel.setFrame(frame, display: false)
        }
        if !notchPanel.isVisible { notchPanel.orderFrontRegardless() }
    }

    private func notchHover(_ inside: Bool) {
        pointerInNotch = inside
        hoverTask?.cancel()
        if inside {
            let delay = prefs.notchHoverDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.pointerInNotch else { return }
                self.showOverflow(.notch)
            }
        } else {
            scheduleHoverClose()
        }
    }

    private func scheduleHoverClose() {
        guard overflowAnchor == .notch else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, !self.pointerInNotch, !self.pointerInOverflow else { return }
            self.closeOverflow()
        }
    }

    // MARK: - Overflow

    private func toggleOverflow(_ anchor: OverflowAnchor) {
        if overflowPanel.isVisible, overflowAnchor == anchor { closeOverflow() } else { showOverflow(anchor) }
    }

    private func showOverflow(_ anchor: OverflowAnchor) {
        let items: [MenuBarItem]
        switch anchor {
        case .notch: items = flattened(entries().map(\.kind))
        case .button: items = flattened(overflowKinds)
        case let .group(id, _): items = members(of: id.uuidString)
        }
        guard !items.isEmpty, let notch = MenuBarScanner.currentNotch(),
              let screen = NSScreen.screens.first(where: { $0.frame == notch.screenFrame }) ?? NSScreen.main,
              let bar = sections.icon.button?.window?.frame else { return }

        let content: NSView
        let size: NSSize
        switch prefs.overflowStyle {
        case .bar:
            let spacing: CGFloat = 6, height: CGFloat = 34
            let widths = items.map { (displayImage(for: $0)?.size.width ?? 18) * scaleFactor + spacing * 2 }
            size = NSSize(width: widths.reduce(0, +) + 12, height: height + 8)
            content = NSView(frame: NSRect(origin: .zero, size: size))
            var x: CGFloat = 6
            for (item, width) in zip(items, widths) {
                let button = WingButton(frame: NSRect(x: x, y: 4, width: width, height: height))
                button.image = displayImage(for: item)
                button.scale = scaleFactor
                button.highlightInset = 1
                button.toolTip = item.displayName
                button.onClick = { [weak self] b in self?.activate(item, from: b) }
                button.onRightClick = { [weak self] b, event in self?.showContextMenu(for: item, event: event, in: b) }
                content.addSubview(button)
                x += width
            }
        case .list:
            let rowHeight: CGFloat = 26
            let width = min(max(items.map { WingRow.width(for: $0.displayName) }.max() ?? 180, 180), 340)
            size = NSSize(width: width, height: CGFloat(items.count) * rowHeight + 10)
            content = FlippedView(frame: NSRect(origin: .zero, size: size))
            for (i, item) in items.enumerated() {
                let row = WingRow(icon: displayImage(for: item), title: item.displayName)
                row.frame = NSRect(x: 0, y: 5 + CGFloat(i) * rowHeight, width: width, height: rowHeight)
                row.onClick = { [weak self] r in self?.activate(item, from: r) }
                row.onRightClick = { [weak self] r, event in self?.showContextMenu(for: item, event: event, in: r) }
                content.addSubview(row)
            }
        }

        let hover = HoverView(frame: NSRect(origin: .zero, size: size))
        hover.onEnter = { [weak self] in self?.pointerInOverflow = true }
        hover.onExit = { [weak self] in
            self?.pointerInOverflow = false
            self?.scheduleHoverClose()
        }
        let glass = GlassBackground.make(cornerRadius: 12, content: content)
        glass.frame = hover.bounds
        glass.autoresizingMask = [.width, .height]
        hover.addSubview(glass)

        let anchorRect: NSRect
        switch anchor {
        case .notch:
            let span = notch.notchSpan ?? (notch.screenFrame.midX...notch.screenFrame.midX)
            anchorRect = NSRect(x: span.lowerBound, y: bar.minY, width: span.upperBound - span.lowerBound, height: bar.height)
        case let .button(rect), let .group(_, rect):
            anchorRect = rect
        }
        var origin = NSPoint(x: anchorRect.midX - size.width / 2, y: bar.minY - size.height - 4)
        origin.x = min(max(origin.x, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)

        overflowPanel.contentView = hover
        overflowPanel.hasShadow = true
        overflowPanel.appearance = nil
        overflowPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        overflowPanel.orderFrontRegardless()
        overflowAnchor = anchor
        installClickMonitor()
    }

    private func closeOverflow() {
        overflowPanel.orderOut(nil)
        overflowAnchor = nil
        pointerInOverflow = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Clicking anywhere else closes the overflow, like a menu.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeOverflow() }
        }
    }

    // MARK: - Opening items

    private func activate(_ item: MenuBarItem, from view: NSView) {
        defer { (view as? WingButton)?.isHighlighted = false }
        guard let element = scan.element(for: item) else { return }
        if !prefs.needsDirectClick.contains(item.id), let menu = MenuMirror.menu(for: element) {
            // Native copy of the item's menu, right under its icon.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 2), in: view)
            closeOverflow()
            return
        }
        closeOverflow()
        guard !prefs.needsDirectClick.contains(item.id) else { return reveal(item) }
        let before = Self.windowIDs(of: item.pid)
        MenuBarScanner.press(element)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if Self.windowIDs(of: item.pid).subtracting(before).isEmpty {
                // The app ignored the press: remember, and show the real icon instead.
                store.prefs.needsDirectClick.insert(item.id)
                reveal(item)
            }
        }
    }

    private func hintName(_ item: MenuBarItem) -> String {
        item.bundleID?.hasPrefix("com.apple.") == true ? item.displayName : item.appName
    }

    private var hintAnchorY: CGFloat {
        (NSScreen.screens.first?.frame.maxY ?? 0) - (sections.icon.button?.window?.frame.height ?? 38)
    }

    /// For icons that ignore remote clicks: ⌘-drag the real icon into view
    /// (just right of Wingbar's line), click it, wait for its menu or popover to
    /// close, then move it back where it was.
    private func reveal(_ item: MenuBarItem) {
        guard !isRevealing else { return }
        guard prefs.moveToOpen, item.windowID != nil, item.pid != 0 else { return showStuckHint(item) }
        isRevealing = true
        Task {
            defer {
                isRevealing = false
                rescan()
            }
            let own = sections.ownWindowIDs
            let fresh = await MenuBarScanner.scanInBackground(excluding: own)
            guard let current = fresh.items.first(where: { $0.id == item.id }), let window = current.windowID,
                  let dividerFrame = sections.hiddenDivider.button?.window?.frame,
                  let divider = MoveEngine.windowID(matching: dividerFrame) else { return showStuckHint(item) }

            // Neighbours on the bar, to put it back exactly where it was.
            let onBar = fresh.items.filter { $0.windowID != nil && $0.placement != .parked }.sorted { $0.frame.minX < $1.frame.minX }
            let index = onBar.firstIndex { $0.id == item.id }
            let left = index.flatMap { $0 > 0 ? onBar[$0 - 1].windowID : nil }
            let right = index.flatMap { $0 + 1 < onBar.count ? onBar[$0 + 1].windowID : nil }

            do {
                try await mover.move(window: window, pid: current.pid, to: .rightOf(divider))
                let baseline = MoveEngine.windowIDs(of: current.pid)
                let opened = try await mover.click(window: window, pid: current.pid)
                if !opened, let frame = MoveEngine.bounds(of: window), let screen = NSScreen.screens.first {
                    hint.show("Wingbar moved \(hintName(item)) here. Click it; it goes back when you're done.",
                              below: NSPoint(x: frame.midX, y: hintAnchorY), on: screen)
                }
                await waitForMenuToClose(pid: current.pid, baseline: baseline, alreadyOpen: opened)
                try await putBack(window: window, pid: current.pid, left: left, right: right)
            } catch {
                showStuckHint(item)
            }
        }
    }

    /// Waits for the app's menu/popover to open (if it hasn't) and close again.
    private func waitForMenuToClose(pid: pid_t, baseline: Set<Int>, alreadyOpen: Bool) async {
        var sawOpen = alreadyOpen
        let deadline = Date().addingTimeInterval(alreadyOpen ? 120 : 20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
            let isOpen = !MoveEngine.windowIDs(of: pid).subtracting(baseline).isEmpty
            if isOpen, !sawOpen { sawOpen = true }
            if sawOpen, !isOpen { break }
        }
        // Let the closing animation finish before the icon moves.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Puts the icon back out of view. Drops only work at visible points next to
    /// drawn icons, so, in order:
    /// 1. left of its original right neighbour, if that edge is visible (exact slot);
    /// 2. left of the leftmost icon right of the notch, then the next one, checking
    ///    each time that the icon really ended up hidden (the first slot under the notch);
    /// 3. left of Wingbar's line, with the hidden section open.
    private func putBack(window: CGWindowID, pid: pid_t, left: CGWindowID?, right: CGWindowID?) async throws {
        guard let notch = MenuBarScanner.currentNotch() else { return }
        func visibleEdge(_ id: CGWindowID) -> Bool {
            guard let frame = MoveEngine.bounds(of: id), let screen = NSScreen.screens.first else { return false }
            return frame.minX > screen.frame.minX && frame.minX < screen.frame.maxX && !notch.isUnderNotch(frame)
        }
        func isHidden() -> Bool {
            guard let frame = MoveEngine.bounds(of: window) else { return true }
            return notch.isUnderNotch(frame) || !MoveEngine.isOnScreen(window)
        }

        let wasCollapsed = !sections.state.showsHidden
        if wasCollapsed {
            sections.toggle(includingAlwaysHidden: false)
            try? await Task.sleep(for: .milliseconds(400))
        }
        defer { if wasCollapsed { sections.collapse() } }

        if let right, right != window, visibleEdge(right) {
            try? await mover.move(window: window, pid: pid, to: .leftOf(right))
            if isHidden() { return }
        }
        guard let dividerFrame = sections.hiddenDivider.button?.window?.frame else { return }
        let fresh = await MenuBarScanner.scanInBackground(excluding: sections.ownWindowIDs)
        let candidates = fresh.items
            .filter { $0.windowID != nil && $0.windowID != window && $0.pid != getpid() }
            .filter { $0.frame.minX >= (notch.notchSpan?.upperBound ?? 0) && $0.frame.maxX <= dividerFrame.minX + 1 }
            .sorted { $0.frame.minX < $1.frame.minX }
        for candidate in candidates.prefix(3) {
            guard let id = candidate.windowID else { continue }
            try? await mover.move(window: window, pid: pid, to: .leftOf(id))
            if isHidden() { return }
        }
        guard let divider = MoveEngine.windowID(matching: dividerFrame) else { return }
        try await mover.move(window: window, pid: pid, to: .leftOf(divider))
    }

    /// Last resort: say why the icon can't be opened from Wingbar.
    private func showStuckHint(_ item: MenuBarItem) {
        guard let screen = NSScreen.screens.first, let span = MenuBarScanner.currentNotch()?.notchSpan else { return }
        let message = item.windowID == nil
            ? "macOS has no room for \(hintName(item)) at all, and it only opens from its own icon. Quit or hide a few menu bar apps to make space."
            : "Couldn't move \(hintName(item)) into view right now. Try again in a moment."
        hint.show(message, below: NSPoint(x: (span.lowerBound + span.upperBound) / 2, y: hintAnchorY), on: screen)
    }

    private static func windowIDs(of pid: Int32) -> Set<Int> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.compactMap { $0[kCGWindowNumber as String] as? Int })
    }

    // MARK: - Context menu

    private func showContextMenu(for item: MenuBarItem, event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(title: item.displayName))
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.activate(item, from: view) })
        menu.addItem(.separator())

        let rule = prefs.rule(for: item.id)
        for option in ItemRule.allCases {
            let entry = ClosureMenuItem(option == .automatic ? "Show in Left Wing" : option == .overflowOnly ? "Show Only in Overflow" : "Don't Show in Wingbar") { [weak self] in
                self?.store.setRule(option, for: item.id)
                self?.rescan()
            }
            entry.state = rule == option ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        let groupMenu = NSMenu()
        let current = prefs.group(containing: item.id)
        for group in prefs.groups {
            let entry = ClosureMenuItem(group.name) { [weak self] in self?.store.setGroup(group.id, for: item.id) }
            entry.state = current?.id == group.id ? .on : .off
            groupMenu.addItem(entry)
        }
        if !prefs.groups.isEmpty { groupMenu.addItem(.separator()) }
        groupMenu.addItem(ClosureMenuItem("New Group…") { [weak self] in self?.promptNewGroup(with: item) })
        if current != nil {
            groupMenu.addItem(ClosureMenuItem("Remove from Group") { [weak self] in self?.store.setGroup(nil, for: item.id) })
        }
        let groupItem = NSMenuItem(title: "Group", action: nil, keyEquivalent: "")
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)

        if prefs.iconPictures == .captureOnce, item.windowID != nil {
            let live = ClosureMenuItem("Keep Picture Live") { [weak self] in
                guard let self else { return }
                if self.store.prefs.liveItems.contains(item.id) { self.store.prefs.liveItems.remove(item.id) } else { self.store.prefs.liveItems.insert(item.id) }
            }
            live.state = prefs.liveItems.contains(item.id) ? .on : .off
            live.toolTip = "Keep updating this icon's picture (for clocks, graphs and percentages)."
            menu.addItem(live)
        }
        if prefs.needsDirectClick.contains(item.id) {
            menu.addItem(ClosureMenuItem("Try Opening from Wingbar Again") { [weak self] in
                self?.store.prefs.needsDirectClick.remove(item.id)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Wingbar Settings…") { [weak self] in self?.openSettings?() })
        // popUp works from a non-activating panel in a background app; popUpContextMenu doesn't.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 2 : -2), in: view)
    }

    private func promptNewGroup(with item: MenuBarItem) {
        let alert = NSAlert()
        alert.messageText = "New Group"
        alert.informativeText = "Grouped icons share one spot in the Left Wing and open together."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name, e.g. Network"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        store.addGroup(named: name.isEmpty ? "Group" : name, with: item.id)
    }

    /// Re-captures every hidden icon's picture once ("Refresh Icon Pictures").
    func refreshPictures() {
        Task {
            await images.refresh(hiddenItems, prefs: prefs, force: true)
            rebuild()
        }
    }

    func clearPictures() {
        images.clearDisk()
        rebuild()
    }

    /// Opens the overflow with every hidden icon (menu command, hotkey).
    func showAllHidden() {
        showOverflow(.notch)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
