import CoreGraphics

/// Where the notch sits on a display, in global x coordinates (AppKit and
/// CoreGraphics agree on x, so this works for window-list frames too).
public struct NotchGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    /// Horizontal span hidden by the camera housing, or nil on displays without one.
    public let notchSpan: ClosedRange<CGFloat>?

    /// - Parameters:
    ///   - leftArea: `NSScreen.auxiliaryTopLeftArea` (menu bar left of the notch).
    ///   - rightArea: `NSScreen.auxiliaryTopRightArea` (menu bar right of the notch).
    public init(screenFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?) {
        self.screenFrame = screenFrame
        if let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            notchSpan = leftArea.maxX...rightArea.minX
        } else {
            notchSpan = nil
        }
    }

    public var hasNotch: Bool { notchSpan != nil }

    public var notchWidth: CGFloat {
        notchSpan.map { $0.upperBound - $0.lowerBound } ?? 0
    }

    /// The menu bar to the right of the notch (the only place status items live).
    public var rightWing: ClosedRange<CGFloat> {
        (notchSpan?.upperBound ?? screenFrame.minX)...screenFrame.maxX
    }

    /// The menu bar to the left of the notch (app menus, plus free space).
    public var leftWing: ClosedRange<CGFloat>? {
        notchSpan.map { screenFrame.minX...$0.lowerBound }
    }

    /// True when any part of `frame` falls under the notch. macOS does not draw such items.
    public func isUnderNotch(_ frame: CGRect) -> Bool {
        guard let notchSpan else { return false }
        return frame.maxX > notchSpan.lowerBound && frame.minX < notchSpan.upperBound
    }
}
