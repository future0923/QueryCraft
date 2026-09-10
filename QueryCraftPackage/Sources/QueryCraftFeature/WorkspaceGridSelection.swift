struct WorkspaceGridCoordinate: Equatable, Sendable {
    let row: Int
    let column: Int
}

struct WorkspaceGridSelection: Equatable, Sendable {
    static let empty = WorkspaceGridSelection(anchor: nil, active: nil)

    let anchor: WorkspaceGridCoordinate?
    let active: WorkspaceGridCoordinate?

    var isEmpty: Bool {
        anchor == nil || active == nil
    }

    var rows: ClosedRange<Int>? {
        guard let anchor, let active else { return nil }
        return min(anchor.row, active.row)...max(anchor.row, active.row)
    }

    var columns: ClosedRange<Int>? {
        guard let anchor, let active else { return nil }
        return min(anchor.column, active.column)...max(
            anchor.column,
            active.column
        )
    }

    var cellCount: Int {
        guard let rows, let columns else { return 0 }
        return rows.count * columns.count
    }

    func contains(row: Int, column: Int) -> Bool {
        guard let rows, let columns else { return false }
        return rows.contains(row) && columns.contains(column)
    }

    static func cell(_ coordinate: WorkspaceGridCoordinate) -> Self {
        Self(anchor: coordinate, active: coordinate)
    }

    func extending(to coordinate: WorkspaceGridCoordinate) -> Self {
        Self(anchor: anchor ?? coordinate, active: coordinate)
    }
}

enum WorkspaceGridColumnReordering {
    static func allows(
        columnIdentifier: String,
        rowNumberIdentifier: String,
        proposedIndex: Int
    ) -> Bool {
        guard columnIdentifier != rowNumberIdentifier else { return false }

        // AppKit uses -1 for its initial "may dragging begin?" probe.
        return proposedIndex == -1 || proposedIndex > 0
    }
}
