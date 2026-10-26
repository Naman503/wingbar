import Foundation

/// UserDefaults-backed preferences.
enum Settings {
    private static let defaults = UserDefaults.standard

    /// Collapse the hidden section again after `autoHideDelay` seconds.
    static var autoHide: Bool {
        get { defaults.object(forKey: "autoHide") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoHide") }
    }

    static var autoHideDelay: Double {
        get { defaults.object(forKey: "autoHideDelay") as? Double ?? 15 }
        set { defaults.set(newValue, forKey: "autoHideDelay") }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the hidden section was open, restored at launch. Starts open:
    /// until the user arranges items, everything sits left of the divider.
    static var showsHidden: Bool {
        get { defaults.object(forKey: "showsHidden") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showsHidden") }
    }

    /// Which placement scheme last seeded Wingbar's status items (0 = never).
    static var seededPositionsVersion: Int {
        get { defaults.integer(forKey: "seededPositionsVersion") }
        set { defaults.set(newValue, forKey: "seededPositionsVersion") }
    }

    /// The optional third section, left of a second divider. Off by default:
    /// that divider can't be placed reliably, so the user drags it into place.
    static var alwaysHiddenEnabled: Bool {
        get { defaults.bool(forKey: "alwaysHiddenEnabled") }
        set { defaults.set(newValue, forKey: "alwaysHiddenEnabled") }
    }

    /// The key AppKit uses to remember where a status item sits.
    static func preferredPositionKey(_ autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    static func setPreferredPosition(_ position: Double, for autosaveName: String) {
        defaults.set(position, forKey: preferredPositionKey(autosaveName))
    }
}

/// The two undocumented, per-host global defaults that set the gap between
/// menu bar items (`defaults -currentHost write -globalDomain …`). macOS reads
/// them when an app creates its status items, so changes apply at next login.
enum ItemSpacing {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"
    /// What macOS uses when the keys are unset.
    static let systemDefault = 16

    static var current: Int? {
        read(spacingKey)
    }

    /// Writes both keys. Padding follows spacing, a little tighter, as most guides suggest.
    static func set(_ spacing: Int) {
        write(spacingKey, spacing)
        write(paddingKey, max(spacing - 2, 0))
    }

    static func reset() {
        write(spacingKey, nil)
        write(paddingKey, nil)
    }

    private static func read(_ key: String) -> Int? {
        CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
    }

    private static func write(_ key: String, _ value: Int?) {
        CFPreferencesSetValue(key as CFString, value.map { $0 as CFNumber }, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }
}
