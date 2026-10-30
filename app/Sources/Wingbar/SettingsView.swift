import ServiceManagement
import SwiftUI
import WingbarCore

/// Everything Settings needs from the running app.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var autoHide = Settings.autoHide { didSet { Settings.autoHide = autoHide } }
    @Published var autoHideDelay = Settings.autoHideDelay { didSet { Settings.autoHideDelay = autoHideDelay } }
    @Published var alwaysHiddenEnabled = Settings.alwaysHiddenEnabled {
        didSet { sections.setAlwaysHiddenEnabled(alwaysHiddenEnabled) }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?
    @Published var spacing = Double(ItemSpacing.current ?? ItemSpacing.systemDefault)
    @Published private(set) var spacingChanged = false
    @Published var tab: SettingsView.Tab = .general

    let permissions = Permissions.shared
    let arranger: Arranger
    private let sections: SectionController
    let showOnboarding: () -> Void
    var refreshPictures: () -> Void = {}
    var clearPictures: () -> Void = {}

    init(sections: SectionController, arranger: Arranger, showOnboarding: @escaping () -> Void) {
        self.sections = sections
        self.arranger = arranger
        self.showOnboarding = showOnboarding
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func applySpacing() {
        ItemSpacing.set(Int(spacing))
        spacingChanged = true
    }

    func resetSpacing() {
        ItemSpacing.reset()
        spacing = Double(ItemSpacing.systemDefault)
        spacingChanged = true
    }

    /// Writes the spacing, then relaunches every app with a menu bar icon so it
    /// takes effect now instead of at next login. Asks first, naming the apps.
    func applySpacingNow() {
        let pids = Set((arranger.menuBarRows + arranger.leftWingRows).map(\.item.pid))
        let apps = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { $0.processIdentifier != getpid() && $0.bundleIdentifier?.hasPrefix("com.apple.") != true && $0.bundleURL != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let alert = NSAlert()
        alert.messageText = "Relaunch menu bar apps?"
        alert.informativeText = "To apply the new spacing now, Wingbar will quit and reopen:\n\n"
            + apps.compactMap(\.localizedName).joined(separator: ", ")
            + "\n\nmacOS's own icons (Wi-Fi, battery, clock…) refresh too. Unsaved work in these apps could be lost; most menu bar apps don't have any."
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        applySpacing()
        Task {
            for app in apps {
                guard let url = app.bundleURL else { continue }
                app.terminate()
                for _ in 0..<30 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(100)) }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            // Apple's menu extras live in these two; macOS restarts them at once.
            let killall = Process()
            killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killall.arguments = ["ControlCenter", "SystemUIServer"]
            try? killall.run()
        }
    }
}

struct SettingsView: View {
    enum Tab: String { case general, wing, arrange, spacing, permissions, about }

    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            LeftWingTab(model: model, store: .shared, permissions: model.permissions).tabItem { Label("Left Wing", systemImage: "rectangle.lefthalf.inset.filled") }.tag(Tab.wing)
            ArrangeTab(arranger: model.arranger, store: .shared, permissions: model.permissions).tabItem { Label("Arrange", systemImage: "menubar.rectangle") }.tag(Tab.arrange)
            SpacingTab(model: model).tabItem { Label("Spacing", systemImage: "arrow.left.and.right") }.tag(Tab.spacing)
            Form { PermissionRows(permissions: model.permissions) }
                .formStyle(.grouped)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(Tab.permissions)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }.tag(Tab.about)
        }
        .frame(width: 640, height: 580)
    }
}

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch Wingbar at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Hidden section") {
                Toggle("Hide items again automatically", isOn: $model.autoHide)
                if model.autoHide {
                    LabeledContent("After") {
                        HStack {
                            Slider(value: $model.autoHideDelay, in: 5...60, step: 5)
                            Text("\(Int(model.autoHideDelay)) s").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                Toggle("Always-hidden section", isOn: $model.alwaysHiddenEnabled)
                Text("Adds a dashed divider. ⌘-drag it left; icons beyond it stay hidden until you Option-click Wingbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeneralExtras(store: .shared)
            Section {
                Button("Show Welcome Guide…", action: model.showOnboarding)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralExtras: View {
    @ObservedObject var store: WingStore

    var body: some View {
        Section("Shortcuts and behaviour") {
            Picker("Show all hidden icons", selection: $store.prefs.hotkey) {
                ForEach(HotkeyChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Wingbar icon", selection: $store.prefs.wingbarIconStyle) {
                ForEach(WingbarIconStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Check for icon changes", selection: $store.prefs.scanInterval) {
                Text("Every 1.5 s (most responsive)").tag(1.5)
                Text("Every 2.5 s (balanced)").tag(2.5)
                Text("Every 5 s (battery saver)").tag(5.0)
                Text("Every 10 s").tag(10.0)
            }
        }
    }
}

private struct ArrangeTab: View {
    @ObservedObject var arranger: Arranger
    @ObservedObject var store: WingStore
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 0) {
            if !permissions.accessibility {
                ContentUnavailableView {
                    Label("Accessibility needed", systemImage: "lock")
                } description: {
                    Text("Wingbar needs Accessibility to see and move menu bar icons.")
                } actions: {
                    Button("Grant…", action: permissions.requestAccessibility)
                }
            } else {
                List {
                    Section {
                        Toggle("Left Wing mode", isOn: $store.prefs.keepHiddenClosed)
                        Text("Keep every icon left of Wingbar's line out of the menu bar; they show in the Left Wing instead. Clicking the Wingbar icon still peeks at them in place. Move the icons you always want to the menu bar list first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(arranger.menuBarRows) { row in
                            ArrangeRow(row: row, side: .menuBar, arranger: arranger, store: store)
                        }
                        DropZone(title: "Drop here to always show it in the menu bar", side: .menuBar, arranger: arranger)
                    } header: {
                        Text("Always in the menu bar")
                    } footer: {
                        Text("Right of Wingbar's line, left to right as in the menu bar. Drag rows to reorder, or between the lists to show or hide; Wingbar moves the real icons. Clock and Control Centre stay where macOS puts them.")
                    }
                    Section {
                        ForEach(arranger.leftWingRows) { row in
                            ArrangeRow(row: row, side: .leftWing, arranger: arranger, store: store)
                        }
                        DropZone(title: "Drop here to hide it: first to go to the Left Wing", side: .leftWing, arranger: arranger)
                    } header: {
                        Text("Left of the line: menu bar when there's room, else Left Wing")
                    } footer: {
                        Text("Left to right, exactly as in the menu bar. macOS fills the bar from the right, so the icons at the bottom of this list stay in the menu bar and the ones at the top overflow into the Left Wing (all of them in Left Wing mode). Drag a row up to send it to the Left Wing, down to keep it in the menu bar. The menu on each row sets where Wingbar may show it.")
                    }
                    GroupsSection(store: store)
                }
                HStack {
                    if let message = arranger.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if arranger.busy { ProgressView().controlSize(.small) }
                    Button("Refresh") { Task { await arranger.refresh() } }
                        .disabled(arranger.busy)
                }
                .padding(10)
            }
        }
        .onAppear { Task { await arranger.refresh() } }
    }
}

private struct ArrangeRow: View {
    let row: Arranger.Row
    let side: Arranger.Side
    @ObservedObject var arranger: Arranger
    @ObservedObject var store: WingStore
    @State private var targeted = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                // Insertion line: the dropped icon goes here, before this row.
                if targeted { Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -5) }
            }
            .modifier(DragSource(id: row.id, enabled: row.movable, icon: row.icon, title: row.item.displayName))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                arranger.drop(id, before: row, in: side)
                return true
            } isTargeted: { targeted = $0 && !arranger.busy }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(row.movable ? 1 : 0)
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                }
            }
            .frame(width: 44, height: 18)
            Text(row.item.displayName).lineLimit(1)
            if side == .leftWing { WhereTag(row: row, leftWingMode: store.prefs.keepHiddenClosed) }
            if !row.movable {
                Image(systemName: row.item.windowID == nil ? "exclamationmark.triangle" : "lock")
                    .foregroundStyle(.secondary)
                    .help(row.item.windowID == nil ? "macOS has no room for this icon at all, so it can't be moved." : "macOS keeps this icon in place.")
            }
            if store.prefs.needsDirectClick.contains(row.item.id) {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                    .help("Only opens from its own icon; Wingbar moves it into view to open it.")
            }
            Spacer()
            if side == .leftWing {
                if store.prefs.iconPictures == .captureOnce, row.item.windowID != nil {
                    Toggle(isOn: Binding(
                        get: { store.prefs.liveItems.contains(row.item.id) },
                        set: { if $0 { store.prefs.liveItems.insert(row.item.id) } else { store.prefs.liveItems.remove(row.item.id) } })) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .toggleStyle(.button)
                    .help("Keep this icon's picture live (for clocks, graphs and percentages)")
                }
                Picker("", selection: Binding(get: { store.prefs.rule(for: row.item.id) }, set: { store.setRule($0, for: row.item.id) })) {
                    ForEach(ItemRule.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("None") { store.setGroup(nil, for: row.item.id) }
                    ForEach(store.prefs.groups) { group in
                        Button(group.name) { store.setGroup(group.id, for: row.item.id) }
                    }
                    Divider()
                    Button("New Group…") { store.addGroup(named: "Group \(store.prefs.groups.count + 1)", with: row.item.id) }
                } label: {
                    Image(systemName: store.prefs.group(containing: row.item.id) == nil ? "folder" : "folder.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { arranger.sendToMenuBar(row) } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Always show in the menu bar")
                    .disabled(row.item.windowID == nil || arranger.busy)
            } else {
                Button { arranger.sendToLeftWing(row) } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Hide from the menu bar (shows in the Left Wing)")
                    .disabled(!row.movable || arranger.busy)
            }
        }
        .buttonStyle(.borderless)
    }
}

/// Where a hidden-list icon is right now, so the effect of a drag is visible.
private struct WhereTag: View {
    let row: Arranger.Row
    let leftWingMode: Bool

    var body: some View {
        let (text, color): (String, Color) = row.item.windowID == nil
            ? ("No room", .orange)
            : row.isDrawn && !leftWingMode ? ("In menu bar", .green) : ("Left Wing", .accentColor)
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Makes a row draggable (by its id), with a small preview.
private struct DragSource: ViewModifier {
    let id: String
    let enabled: Bool
    let icon: NSImage?
    let title: String

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(id) {
                HStack {
                    if let icon { Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 18) }
                    Text(title)
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            content
        }
    }
}

/// The end of a list: dropping here shows the icon at the start of the menu bar, or hides it.
private struct DropZone: View {
    let title: String
    let side: Arranger.Side
    @ObservedObject var arranger: Arranger
    @State private var targeted = false

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(targeted ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5)))
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                arranger.drop(id, before: nil, in: side)
                return true
            } isTargeted: { targeted = $0 && !arranger.busy }
    }
}

private struct GroupsSection: View {
    @ObservedObject var store: WingStore
    private static let symbols = ["square.grid.2x2", "network", "wifi", "bolt", "cloud", "gauge.with.dots.needle.33percent", "wrench.and.screwdriver", "sparkles", "music.note", "tray.full", "star", "folder"]

    var body: some View {
        Section {
            if store.prefs.groups.isEmpty {
                Text("Group icons to give them one spot in the Left Wing. Use the folder button on any row, or right-click an icon in the Left Wing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($store.prefs.groups) { $group in
                HStack {
                    Menu {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button { group.symbol = symbol } label: { Label(symbol, systemImage: symbol) }
                        }
                    } label: { Image(systemName: group.symbol) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    TextField("Name", text: $group.name).textFieldStyle(.plain)
                    Text("\(group.itemIDs.count) icons").foregroundStyle(.secondary)
                    Button(role: .destructive) { store.removeGroup(group.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Groups")
        }
    }
}

private struct LeftWingTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var store: WingStore
    @ObservedObject var permissions: Permissions

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden icons left of the notch", isOn: $store.prefs.leftWingEnabled)
                Text("Icons macOS can't draw (under the notch, or behind Wingbar's line when it's closed) appear in the free menu bar space after the app's menus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                LabeledContent("Icon size") {
                    HStack {
                        Slider(value: $store.prefs.iconScale, in: 0.6...1, step: 0.05)
                        Text("\(Int(store.prefs.iconScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Spacing") {
                    HStack {
                        Slider(value: $store.prefs.spacing, in: 0...20, step: 1)
                        Text("\(Int(store.prefs.spacing)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Show", selection: $store.prefs.visibility) {
                    ForEach(WingVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Position", selection: $store.prefs.alignment) {
                    ForEach(WingAlignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Order", selection: $store.prefs.order) {
                    ForEach(WingOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Gap after app menus") {
                    HStack {
                        Slider(value: $store.prefs.gapAfterMenus, in: 4...60, step: 2)
                        Text("\(Int(store.prefs.gapAfterMenus)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .disabled(!store.prefs.leftWingEnabled)
            Section("Appearance") {
                Picker("Background", selection: $store.prefs.background) {
                    ForEach(WingBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Icons without a live picture", selection: $store.prefs.fallbackIconStyle) {
                    ForEach(FallbackIconStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Icon pictures") {
                Picker("Use Screen Recording", selection: $store.prefs.iconPictures) {
                    ForEach(IconPictureMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                switch store.prefs.iconPictures {
                case .captureOnce:
                    Text("Each icon is pictured once and saved; Screen Recording is only used for icons Wingbar hasn't seen. For a changing icon (a clock, a graph), turn on its live button in Arrange, or keep it in the menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                case .live:
                    Picker("Update every", selection: $store.prefs.liveRefreshInterval) {
                        Text("2 seconds").tag(2.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("10 seconds").tag(10.0)
                    }
                case .off:
                    Text("Wingbar never uses Screen Recording; icons show as app icons in the style above. You can turn the permission off in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.prefs.iconPictures != .off {
                    HStack {
                        Button("Refresh Pictures Now", action: model.refreshPictures)
                        Button("Delete Saved Pictures", action: model.clearPictures)
                    }
                    if !permissions.screenRecording {
                        HStack {
                            Text("Needs Screen Recording; until granted, app icons are shown.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Grant…", action: permissions.requestScreenRecording)
                        }
                    }
                }
            }
            Section("When it's full") {
                Picker("Overflow style", selection: $store.prefs.overflowStyle) {
                    ForEach(OverflowStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Icons that don't fit go behind a ‹ button at the edge of the Left Wing and open in a bar below the notch.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Hover over the notch to show all hidden icons", isOn: $store.prefs.notchHoverEnabled)
                    .help("Off by default; the Left Wing and the shortcut usually cover it.")
                if store.prefs.notchHoverEnabled {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $store.prefs.notchHoverDelay, in: 0...1, step: 0.05)
                            Text(String(format: "%.2f s", store.prefs.notchHoverDelay)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Opening icons") {
                Toggle("Move icons into view to open them", isOn: $store.prefs.moveToOpen)
                Text("Some apps only open from their real icon. Wingbar briefly ⌘-drags it next to its line, clicks it, and puts it back when you're done. Your pointer jumps there for a split second.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.prefs.needsDirectClick.isEmpty {
                Section {
                    HStack {
                        Text("\(store.prefs.needsDirectClick.count) icons only open from their own icon, so Wingbar reveals them instead.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry All") { store.prefs.needsDirectClick.removeAll() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}

private struct SpacingTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Icon spacing") {
                    HStack {
                        Slider(value: $model.spacing, in: 0...16, step: 1)
                        Text("\(Int(model.spacing))").monospacedDigit().frame(width: 24, alignment: .trailing)
                    }
                }
                Text("Smaller gaps fit more icons before the notch. macOS uses 16; 6–8 fits about a third more.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Apply at Next Login", action: model.applySpacing)
                    Button("Apply Now…", action: model.applySpacingNow)
                    Button("Reset to Default", action: model.resetSpacing)
                }
                if model.spacingChanged {
                    Label("Saved. Apps pick it up when they relaunch (or at next login).", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.left.2").font(.system(size: 36, weight: .semibold))
            Text("Wingbar").font(.title.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Menu bar icons on both wings of the notch.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
