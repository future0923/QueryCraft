public struct WorkspaceDatabaseDataChangeSet: Equatable, Sendable {
    public let updates: [WorkspaceDatabaseDataCellUpdate]
    public let inserts: [WorkspaceDatabaseDataRowInsert]
    public let deletes: [WorkspaceDatabaseDataRowDelete]

    public init(
        updates: [WorkspaceDatabaseDataCellUpdate],
        inserts: [WorkspaceDatabaseDataRowInsert],
        deletes: [WorkspaceDatabaseDataRowDelete]
    ) {
        self.updates = updates
        self.inserts = inserts
        self.deletes = deletes
    }

    public var isEmpty: Bool {
        updates.isEmpty && inserts.isEmpty && deletes.isEmpty
    }

    public var selection: WorkspaceDatabaseObjectSelection? {
        updates.first?.selection
            ?? inserts.first?.selection
            ?? deletes.first?.selection
    }

    public var hasConsistentSelection: Bool {
        guard let selection else { return false }
        return updates.allSatisfy { $0.selection == selection }
            && inserts.allSatisfy { $0.selection == selection }
            && deletes.allSatisfy { $0.selection == selection }
    }

    public var rowUpdates: [WorkspaceDatabaseDataRowUpdate] {
        WorkspaceDatabaseDataRowUpdate.group(updates)
    }
}
