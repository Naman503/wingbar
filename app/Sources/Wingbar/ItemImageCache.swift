import AppKit
import ScreenCaptureKit
import WingbarCore

/// Pictures of status items, captured from their windows (which exist even
/// under the notch or behind a collapsed divider) and kept on disk, so in
/// capture-once mode Screen Recording is only used for icons Wingbar hasn't
/// seen yet. Pictures include the menu bar's look, so light and dark are
/// stored separately. Without a picture, callers fall back to the app icon.
@MainActor
final class ItemImageCache {
    private var images: [String: NSImage] = [:]
    private var capturing = false
    /// When capture last failed for lack of permission; retried after a minute.
    private var deniedAt: Date?
    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Wingbar/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// "dark" or "light": captured pictures only match the bar they came from.
    var appearance = "dark"

    func image(for item: MenuBarItem) -> NSImage? {
        let key = cacheKey(item.id)
        if let image = images[key] { return image }
        guard let data = try? Data(contentsOf: file(for: key)),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let image = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2))
        image.addRepresentation(rep)
        images[key] = image
        return image
    }

    /// Captures pictures as the mode allows. `force` re-captures everything once
    /// (the "Refresh Icon Pictures" button). Returns true if any size changed.
    @discardableResult
    func refresh(_ items: [MenuBarItem], prefs: WingPreferences, force: Bool = false) async -> Bool {
        guard prefs.iconPictures != .off || force else { return false }
        let targets = items.filter { item in
            guard item.windowID != nil else { return false }
            if force || prefs.iconPictures == .live || prefs.liveItems.contains(item.id) { return true }
            return image(for: item) == nil // capture once
        }
        return await capture(targets)
    }

    func clearDisk() {
        images.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func capture(_ targets: [MenuBarItem]) async -> Bool {
        guard !capturing, !targets.isEmpty else { return false }
        // Preflight can report false on macOS 26 even when capture works, so just try.
        if let deniedAt, Date().timeIntervalSince(deniedAt) < 60, !Permissions.shared.screenRecording { return false }
        capturing = true
        defer { capturing = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            deniedAt = Date()
            return false
        }
        deniedAt = nil
        Permissions.shared.markScreenRecordingGranted()
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let scale: CGFloat = 2
        var resized = false
        for item in targets {
            guard let id = item.windowID, let window = windows[id] else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config),
                  let cropped = Self.crop(cg, windowWidth: window.frame.width, iconWidth: item.frame.width, scale: scale),
                  !Self.isBlank(cropped) else { continue }
            let image = NSImage(cgImage: cropped, size: NSSize(width: CGFloat(cropped.width) / scale, height: CGFloat(cropped.height) / scale))
            let key = cacheKey(item.id)
            if images[key]?.size != image.size { resized = true }
            images[key] = image
            if let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) {
                try? png.write(to: file(for: key))
            }
        }
        return resized
    }

    private func cacheKey(_ id: String) -> String { "\(id)@\(appearance)" }

    private func file(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "@" || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".png")
    }

    /// The window includes the item's own padding; keep just the icon (plus 2 pt a
    /// side) so Wingbar's spacing setting decides the gaps.
    private static func crop(_ image: CGImage, windowWidth: CGFloat, iconWidth: CGFloat, scale: CGFloat) -> CGImage? {
        let contentWidth = min(windowWidth, max(iconWidth + 4, 8))
        let x = ((windowWidth - contentWidth) / 2 * scale).rounded()
        return image.cropping(to: CGRect(x: x, y: 0, width: (contentWidth * scale).rounded(), height: CGFloat(image.height)))
    }

    /// A capture taken mid-transition can come back empty; never cache that.
    private static func isBlank(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        let alphaOffset = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst ? 0 : 3
        var i = alphaOffset
        while i < length {
            if bytes[i] > 24 { return false }
            i += 4 * 7
        }
        return true
    }
}
