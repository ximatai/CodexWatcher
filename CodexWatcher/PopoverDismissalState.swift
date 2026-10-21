import Foundation

/// An external interaction remains pending until all nested menus finish tracking.
struct PopoverDismissalState {
    private var menus: Set<ObjectIdentifier> = []
    private var pendingDismissal = false
    var isTrackingMenu: Bool { !menus.isEmpty }

    mutating func menuBegan(_ menu: AnyObject) { menus.insert(ObjectIdentifier(menu)) }

    mutating func menuEnded(_ menu: AnyObject) -> Bool {
        menus.remove(ObjectIdentifier(menu))
        guard menus.isEmpty, pendingDismissal else { return false }
        pendingDismissal = false
        return true
    }

    mutating func outsideInteraction() -> Bool {
        guard menus.isEmpty else { pendingDismissal = true; return false }
        return true
    }

    mutating func reset() { menus.removeAll(); pendingDismissal = false }
}
