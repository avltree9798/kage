import Foundation
import KageModels

/// Picks which live WebViews to release so memory stays bounded (spec 6.2, AT02).
/// Logical tabs are unlimited; resident WebViews are capped.
public enum TabResidencyPolicy {
    public static let defaultMaxResident = 6
    public static let lowMemoryMaxResident = 2

    /// - Returns: IDs of resident tabs to suspend, oldest-used first. Never the active tab;
    ///   pinned tabs are kept while there is room.
    public static func tabsToSuspend(resident: [BrowserTab], activeID: UUID?, maxResident: Int) -> [UUID] {
        let limit = max(1, maxResident)
        guard resident.count > limit else { return [] }
        let candidates = resident
            .filter { $0.id != activeID }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return !lhs.isPinned }   // unpinned go first
                return lhs.lastActiveAt < rhs.lastActiveAt
            }
        return candidates.prefix(resident.count - limit).map(\.id)
    }
}
