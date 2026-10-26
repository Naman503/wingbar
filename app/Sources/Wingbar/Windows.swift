import AppKit
import SwiftUI

/// Hosts a SwiftUI view in a regular window. Wingbar has no Dock icon, so
/// showing a window also has to activate the app to bring it to the front.
@MainActor
final class WindowPresenter<Content: View>: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let makeContent: () -> Content
    var onClose: (() -> Void)?
    /// Close when the user clicks anywhere outside Wingbar, like a popover.
    var closesOnOutsideClick = false
    private var outsideClickMonitor: Any?

    init(title: String, content: @escaping () -> Content) {
        self.title = title
        self.makeContent = content
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeContent()))
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if closesOnOutsideClick, outsideClickMonitor == nil {
            // A global monitor only sees clicks in other apps, so clicks on
            // Wingbar's own icon, line and Left Wing don't close the window.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                // Wingbar's own synthetic clicks (moving or opening icons while
                // arranging) arrive here too; only the user's clicks close it.
                let fromWingbar = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
                MainActor.assumeIsolated {
                    guard !fromWingbar, !MoveEngine.isPostingEvents else { return }
                    self?.close()
                }
            }
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        onClose?()
        // Drop the hosting view so SwiftUI state (and permission polling) stops.
        window = nil
    }
}

/// One permission row, shared by onboarding and Settings.
struct PermissionRow: View {
    let title: String
    let detail: String
    let required: Bool
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Text(required ? "Required" : "Optional")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: grant)
            }
        }
    }
}

struct PermissionRows: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionRow(
                title: "Accessibility",
                detail: "Lets Wingbar see which app owns each menu bar icon and open hidden ones.",
                required: true, granted: permissions.accessibility,
                grant: permissions.requestAccessibility)
            PermissionRow(
                title: "Screen Recording",
                detail: "Lets Wingbar show the real icons of hidden items. Nothing is recorded or saved.",
                required: false, granted: permissions.screenRecording,
                grant: permissions.requestScreenRecording)
        }
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}
