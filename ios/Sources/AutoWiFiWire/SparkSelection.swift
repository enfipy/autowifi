import Foundation

/// Pure selection policy shared by the app UI and its behavior tests.
/// Newly restored accessories are selected by default; an explicit user choice
/// survives ordinary AccessorySetupKit refreshes but not accessory removal.
public struct SparkSelection: Equatable, Sendable {
    public private(set) var selected: Set<UUID> = []
    private var available: Set<UUID> = []

    public init() {}

    public mutating func reconcile(available identifiers: [UUID]) {
        let next = Set(identifiers)
        selected.formIntersection(next)
        selected.formUnion(next.subtracting(available))
        available = next
    }

    public mutating func toggle(_ identifier: UUID) {
        guard available.contains(identifier) else { return }
        if selected.contains(identifier) {
            selected.remove(identifier)
        } else {
            selected.insert(identifier)
        }
    }

    public mutating func selectAll() {
        selected = available
    }

    public mutating func deselectAll() {
        selected.removeAll(keepingCapacity: true)
    }
}
