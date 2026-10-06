import Foundation
import Observation
import TDShim

/// Single source of truth for `[userId: firstName]` resolved from TDLib's
/// `updateUser` events. Owned by `TDClient`; injected into `ChatListStore`
/// and `ChatHistoryStore` at construction. Lifetime tied to the active
/// `TDClient` — account switch rebuilds it.
///
/// Stores `firstName` only (matches the existing single-field shape used
/// by `senderName(...)`, `senderPrefix(...)`, `replyPreview(...)`,
/// `serviceActor(...)`). If the codebase ever needs a richer display
/// name, swap the dict's value type here.
@Observable @MainActor
final class UserNamesStore {
    private(set) var names: [Int64: String] = [:]
    /// Bumped whenever a name changes, so projections can tell their names are stale
    /// without comparing the whole dictionary.
    @ObservationIgnored private(set) var generation = 0

    /// Absorbs `.updateUser` events. Other update kinds are ignored. Idempotent.
    func handle(_ update: Update) {
        if case .updateUser(let upd) = update, names[upd.user.id] != upd.user.firstName {
            names[upd.user.id] = upd.user.firstName
            generation += 1
        }
    }

    #if DEBUG
    /// Perf bench / previews: names for made-up users.
    func debugSeed(_ seed: [Int64: String]) {
        names.merge(seed) { _, new in new }
        generation += 1
    }
    #endif
}
