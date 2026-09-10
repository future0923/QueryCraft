import Foundation

enum WorkspaceDatabaseDataFilterFocus: Hashable {
    case enabled(UUID)
    case elasticsearchClause(UUID)
    case column(UUID)
    case operation(UUID)
    case value(UUID)
    case secondValue(UUID)

    var conditionID: UUID {
        switch self {
        case let .enabled(id),
             let .elasticsearchClause(id),
             let .column(id),
             let .operation(id),
             let .value(id),
             let .secondValue(id):
            id
        }
    }

    func moving(to conditionID: UUID) -> Self {
        switch self {
        case .enabled: .enabled(conditionID)
        case .elasticsearchClause: .elasticsearchClause(conditionID)
        case .column: .column(conditionID)
        case .operation: .operation(conditionID)
        case .value: .value(conditionID)
        case .secondValue: .secondValue(conditionID)
        }
    }

    static func preferredAfterSelecting(
        _ operation: WorkspaceDatabaseDataFilterOperator,
        conditionID: UUID
    ) -> Self? {
        guard operation.requiresValue else { return nil }
        return .value(conditionID)
    }
}
