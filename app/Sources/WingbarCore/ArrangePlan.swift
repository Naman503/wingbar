/// Turns the menu bar's current left-to-right order into the one the user
/// asked for with as few real moves as possible. Every move costs a cursor
/// jump, and drops only land next to an icon whose edge is visible, so the
/// plan keeps the longest run of icons already in the right relative order
/// and places each of the others next to a neighbour.
public enum ArrangePlan {
    public struct Step: Equatable, Sendable {
        /// The icon to move.
        public let id: String
        /// Put it right of this icon (already in its final place), if any.
        public let after: String?
        /// Or left of this icon, which doesn't move, if any.
        public let before: String?

        public init(id: String, after: String?, before: String?) {
            self.id = id
            self.after = after
            self.before = before
        }
    }

    /// Steps in the order to perform them (left to right in `desired`), or nil
    /// when `fixed` icons (ones whose app ignores moves) would have to change
    /// order among themselves. `current` and `desired` must hold the same ids.
    public static func steps(current: [String], desired: [String], fixed: Set<String> = []) -> [Step]? {
        let staying = Set(longestCommonSubsequence(current, desired, mustKeep: fixed))
        guard fixed.filter({ desired.contains($0) }).isSubset(of: staying) else { return nil }
        return desired.indices.compactMap { i in
            let id = desired[i]
            guard !staying.contains(id) else { return nil }
            let next = i + 1 < desired.count ? desired[i + 1] : nil
            return Step(id: id,
                        after: i > 0 ? desired[i - 1] : nil,
                        before: next.flatMap { staying.contains($0) ? $0 : nil })
        }
    }

    /// `ids` with `id` taken out and put back just before `target` (or at the end).
    public static func reordered(_ ids: [String], moving id: String, before target: String?) -> [String] {
        var result = ids.filter { $0 != id }
        let index = target.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(id, at: index)
        return result
    }

    /// Longest common subsequence, weighted so `mustKeep` items are kept
    /// whenever their relative order allows it.
    static func longestCommonSubsequence(_ a: [String], _ b: [String], mustKeep: Set<String> = []) -> [String] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let heavy = a.count + 1 // one kept fixed icon outweighs every movable one
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + (mustKeep.contains(a[i]) ? heavy : 1)
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var result = [String]()
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j], table[i][j] == table[i + 1][j + 1] + (mustKeep.contains(a[i]) ? heavy : 1) {
                result.append(a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
