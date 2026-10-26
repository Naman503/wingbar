import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Accessibility (required) and Screen Recording (optional), polled while a
/// window that shows them is open.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    private var timer: Timer?
    private var watchers = 0
    /// Only probe ScreenCaptureKit after the user asked for it: the probe itself can prompt.
    private var askedForScreenRecording = false

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    func startWatching() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        if !screenRecording {
            // The spike found preflight stays false on macOS 26 even after the grant
            // works, so confirm with a real (cheap) ScreenCaptureKit call.
            if CGPreflightScreenCaptureAccess() {
                screenRecording = true
            } else if askedForScreenRecording {
                Task {
                    let granted = (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil
                    if granted { self.screenRecording = true }
                }
            }
        }
    }

    /// A ScreenCaptureKit call succeeded, which is the real proof of the grant.
    func markScreenRecordingGranted() {
        if !screenRecording { screenRecording = true }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { open(.accessibility) }
    }

    func requestScreenRecording() {
        askedForScreenRecording = true
        if !CGRequestScreenCaptureAccess() { open(.screenRecording) }
    }

    func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
