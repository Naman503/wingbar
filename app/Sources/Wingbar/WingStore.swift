import Foundation
import WingbarCore

/// The user's Left Wing / overflow preferences, persisted as one JSON blob.
@MainActor
final class WingStore: ObservableObject {
    static let shared = WingStore()
    private static let key = "wingPreferences"

    @Published var prefs: WingPreferences {
        didSet {
            guard prefs != oldValue else { return }
            if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    private static let versionKey = "wingPreferencesVersion"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(WingPreferences.self, from: data) {
            prefs = decoded
        } else {
            prefs = WingPreferences()
        }
        // v2: notch hover off and capture-once pictures by default, also for
        // preferences saved before those options existed.
        if UserDefaults.standard.integer(forKey: Self.versionKey) < 2 {
            prefs.notchHoverEnabled = false
            prefs.iconPictures = .captureOnce
            if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.key) }
            UserDefaults.standard.set(2, forKey: Self.versionKey)
        }
        // v3: Arrange now mirrors the real menu bar; drop custom orders saved by the
        // old list reordering, which never moved the real icons.
        if UserDefaults.standard.integer(forKey: Self.versionKey) < 3 {
            if prefs.order == .custom { prefs.order = .menuBar }
            prefs.customOrder = []
            if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.key) }
            UserDefaults.standard.set(3, forKey: Self.versionKey)
        }
    }

    func setRule(_ rule: ItemRule, for itemID: String) {
        prefs.rules[itemID] = rule == .automatic ? nil : rule
    }

    /// Moves an item into a group (removing it from any other), or out of all groups when nil.
    func setGroup(_ groupID: UUID?, for itemID: String) {
        for i in prefs.groups.indices { prefs.groups[i].itemIDs.removeAll { $0 == itemID } }
        if let groupID, let i = prefs.groups.firstIndex(where: { $0.id == groupID }) {
            prefs.groups[i].itemIDs.append(itemID)
        }
    }

    @discardableResult
    func addGroup(named name: String, with itemID: String?) -> UUID {
        let group = ItemGroup(name: name)
        prefs.groups.append(group)
        if let itemID { setGroup(group.id, for: itemID) }
        return group.id
    }

    func removeGroup(_ id: UUID) {
        prefs.groups.removeAll { $0.id == id }
    }
}
