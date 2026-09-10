import Foundation

struct WorkspaceDatabaseSchemaRowCommandActions: Equatable {
    let kind: WorkspaceDatabaseSchemaGridItemKind
    let selectedID: UUID?
    let canAdd: Bool
    let canDuplicate: Bool
    let canDelete: Bool
    let add: @MainActor @Sendable () -> Void
    let duplicate: @MainActor @Sendable (UUID) -> Void
    let delete: @MainActor @Sendable (UUID) -> Void

    static func == (
        lhs: WorkspaceDatabaseSchemaRowCommandActions,
        rhs: WorkspaceDatabaseSchemaRowCommandActions
    ) -> Bool {
        lhs.kind == rhs.kind
            && lhs.selectedID == rhs.selectedID
            && lhs.canAdd == rhs.canAdd
            && lhs.canDuplicate == rhs.canDuplicate
            && lhs.canDelete == rhs.canDelete
    }
}
