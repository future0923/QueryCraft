import Foundation

/// Lets a staged-change owner end its native editor without reconstructing the grid.
@MainActor
final class WorkspaceDataCellEditingLifetime: Equatable {
    private(set) var revision = UUID()
    private var endEditing: ((Bool) -> Void)?

    nonisolated static func == (lhs: WorkspaceDataCellEditingLifetime, rhs: WorkspaceDataCellEditingLifetime) -> Bool {
        lhs === rhs
    }

    func register(revision: UUID, endEditing: @escaping (Bool) -> Void) -> Bool {
        guard self.revision == revision else { return false }
        self.endEditing = endEditing
        return true
    }

    func unregister(revision: UUID?) {
        if self.revision == revision { endEditing = nil }
    }

    func finish(commit: Bool) {
        let action = endEditing
        endEditing = nil
        revision = UUID()
        action?(commit)
    }
}
