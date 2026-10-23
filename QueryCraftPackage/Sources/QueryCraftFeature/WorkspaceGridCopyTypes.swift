import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

struct WorkspaceGridCopyColumn: Equatable, Sendable {
    let name: String
    let dataIndex: Int
}

enum WorkspaceGridCopyRows: Sendable {
    case range(ClosedRange<Int>)
    case indexes(IndexSet)

    var count: Int {
        switch self {
        case let .range(range):
            range.count
        case let .indexes(indexes):
            indexes.count
        }
    }

    var first: Int? {
        switch self {
        case let .range(range):
            range.first
        case let .indexes(indexes):
            indexes.first
        }
    }

    func forEach(_ body: (Int) -> Bool) -> Bool {
        switch self {
        case let .range(range):
            for row in range where !body(row) {
                return false
            }
        case let .indexes(indexes):
            for row in indexes where !body(row) {
                return false
            }
        }
        return true
    }
}

struct WorkspaceGridCopySnapshot: Sendable {
    let rowAt: @Sendable (Int) -> WorkspaceDatabaseDataRow?
    let requiresBackgroundEncoding: Bool

    init(
        rowAt: @escaping @Sendable (Int) -> WorkspaceDatabaseDataRow?,
        requiresBackgroundEncoding: Bool = false
    ) {
        self.rowAt = rowAt
        self.requiresBackgroundEncoding = requiresBackgroundEncoding
    }
}

