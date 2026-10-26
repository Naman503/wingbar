import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI
import WingbarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sections: SectionController!
    private var settingsModel: SettingsModel!
    private var settingsWindow: WindowPresenter<SettingsView>!
    private var onboardingWindow: WindowPresenter<OnboardingView>!
    private var autoHideTask: Task<Void, Never>?
    private var lastScan = ScanResult()
    private var leftWing: LeftWingController!
    private var arranger: Arranger!
    private let hotKey = HotKey()
    private var prefsObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sections = SectionController()
        leftWing = LeftWingController(sections: sections)
        sections.onChange = { [weak self] state in
            self?.scheduleAutoHide(state)
            self?.leftWing.sectionsChanged()
        }

        let button = sections.icon.button
        button?.target = self
        button?.action = #selector(iconClicked)
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configureDividers()

        arranger = Arranger(sections: sections)
        arranger.picture = { [weak self] item in self?.leftWing.displayImage(for: item) }
        settingsModel = SettingsModel(sections: sections, arranger: arranger) { [weak self] in self?.showOnboarding() }
        settingsModel.refreshPictures = { [weak self] in self?.leftWing.refreshPictures() }
        settingsModel.clearPictures = { [weak self] in self?.leftWing.clearPictures() }
        // --settings[=tab] opens Settings at launch (handy for screenshots and testing).
        let settingsArg = CommandLine.arguments.first { $0.hasPrefix("--settings") }
        let initialTab = settingsArg.flatMap { $0.split(separator: "=").last.map(String.init) }.flatMap(SettingsView.Tab.init) ?? .general
        settingsModel.tab = initialTab
        settingsWindow = WindowPresenter(title: "Wingbar Settings") { [unowned self] in SettingsView(model: settingsModel) }
        settingsWindow.closesOnOutsideClick = true
        onboardingWindow = WindowPresenter(title: "Welcome to Wingbar") { [unowned self] in
            OnboardingView(permissions: .shared) { [weak self] in
                Settings.hasCompletedOnboarding = true
                self?.onboardingWindow.close()
            }
        }

        if !Settings.hasCompletedOnboarding || CommandLine.arguments.contains("--onboarding") {
            showOnboarding()
        }
        leftWing.openSettings = { [weak self] in self?.showSettings() }
        leftWing.start()
        applyPreferences(WingStore.shared.prefs, previous: nil)
        prefsObserver = WingStore.shared.$prefs.dropFirst().scan((WingStore.shared.prefs, WingStore.shared.prefs)) { ($0.1, $1) }
            .receive(on: RunLoop.main)
            .sink { [weak self] pair in MainActor.assumeIsolated { self?.applyPreferences(pair.1, previous: pair.0) } }
        if settingsArg != nil { showSettings() }
        if let path = CommandLine.arguments.first(where: { $0.hasPrefix("--dump-scan=") })?.dropFirst(12) {
            dumpScan(to: String(path))
        }
    }

    /// Debug: writes the raw scan (windows, extras, matches) to a file, then keeps running.
    private func dumpScan(to path: String) {
        let own = sections.ownWindowIDs
        Task {
            var raw = await Task.detached { MenuBarScanner.debugDescription(excluding: own) }.value
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                raw += "\nScreenCaptureKit: ok, \(content.windows.count) windows\n"
            } catch {
                raw += "\nScreenCaptureKit: \(error.localizedDescription)\n"
            }
            raw += "preflight: \(CGPreflightScreenCaptureAccess())\n"
            try? raw.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Preferences that live outside the Left Wing: shortcut, icon style, Left Wing mode.
    private func applyPreferences(_ prefs: WingPreferences, previous: WingPreferences?) {
        if previous?.hotkey != prefs.hotkey {
            hotKey.set(prefs.hotkey) { [weak self] in self?.leftWing.showAllHidden() }
        }
        if previous?.wingbarIconStyle != prefs.wingbarIconStyle { sections.updateIcon() }
        if let previous, !previous.keepHiddenClosed, prefs.keepHiddenClosed { sections.collapse() }
    }

    // MARK: - Icon

    @objc private func iconClicked() {
        // No mouse event means an accessibility press (VoiceOver, AXPress): treat it as a click.
        let event = NSApp.currentEvent.flatMap { [.leftMouseUp, .rightMouseUp].contains($0.type) ? $0 : nil }
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            sections.toggle(includingAlwaysHidden: event?.modifierFlags.contains(.option) == true)
        }
    }

    /// Clicking a divider line opens Settings (⌘-dragging it still moves it,
    /// since the menu bar handles ⌘-drags before the button sees them).
    private func configureDividers() {
        let wire: (NSStatusItem) -> Void = { [unowned self] divider in
            divider.button?.target = self
            divider.button?.action = #selector(dividerClicked)
            divider.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        [sections.hiddenDivider, sections.alwaysHiddenDivider].compactMap { $0 }.forEach(wire)
        sections.onDividerAdded = wire
    }

    @objc private func dividerClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { return showMenu() }
        // Click again to close.
        if settingsWindow.isVisible { settingsWindow.close() } else { showSettings(tab: .wing) }
    }

    @objc func openSettingsFromMenu(_ sender: Any?) { showSettings() }

    private func scheduleAutoHide(_ state: SectionState) {
        autoHideTask?.cancel()
        // In Left Wing mode a peek always closes again.
        let leftWingMode = WingStore.shared.prefs.keepHiddenClosed
        guard state.showsHidden, Settings.autoHide || leftWingMode else { return }
        let delay = Settings.autoHideDelay
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            // Don't pull the bar out from under an icon Wingbar moved into view.
            while self.leftWing.isRevealing {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            self.sections.collapse()
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let own = sections.ownWindowIDs
        Task {
            lastScan = await MenuBarScanner.scanInBackground(excluding: own)
            let menu = buildMenu()
            sections.icon.menu = menu
            sections.icon.button?.performClick(nil)
            // Detach so the next left click toggles instead of opening the menu.
            sections.icon.menu = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // Whatever isn't drawn right now: behind a collapsed divider, under the notch, or parked.
        let hidden = lastScan.items.filter { $0.placement != .visible }

        if !Permissions.shared.accessibility {
            let item = NSMenuItem(title: "Grant Accessibility to List Hidden Items…", action: #selector(openOnboarding), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else if hidden.isEmpty {
            menu.addItem(NSMenuItem(title: "No Hidden Items", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem.sectionHeader(title: "Hidden Items"))
            for item in hidden {
                let entry = NSMenuItem(title: item.displayName, action: #selector(openHiddenItem(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = item.id
                entry.image = NSRunningApplication(processIdentifier: item.pid)?.icon.map(Self.menuSized)
                entry.toolTip = Self.placementNote(item.placement)
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())

        let showAll = NSMenuItem(title: "Show All Hidden Icons Below Notch", action: #selector(showAllHidden), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)
        let toggle = NSMenuItem(title: sections.state.showsHidden ? "Hide Items" : "Show Hidden Items", action: #selector(toggleSection), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wingbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func openHiddenItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = lastScan.items.first(where: { $0.id == id }),
              let element = lastScan.element(for: item) else { return }
        // Let our own menu finish closing first, or the target's menu closes with it.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            MenuBarScanner.press(element)
        }
    }

    @objc private func toggleSection() { sections.toggle(includingAlwaysHidden: false) }
    @objc private func showAllHidden() { leftWing.showAllHidden() }
    @objc private func openSettings() { showSettings() }
    @objc private func openOnboarding() { showOnboarding() }

    private func showSettings(tab: SettingsView.Tab? = nil) {
        if let tab { settingsModel.tab = tab }
        settingsWindow.show()
    }
    private func showOnboarding() { onboardingWindow.show() }

    private static func menuSized(_ image: NSImage) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    private static func placementNote(_ placement: ItemPlacement) -> String? {
        switch placement {
        case .visible: nil
        case .underNotch: "Hidden under the notch"
        case .offScreen: "Hidden by macOS"
        case .parked: "No room in the menu bar"
        }
    }
}
