import Foundation
import Observation
import QueryCraftMobileCore

@MainActor @Observable final class MobileTableFilterDraft: Identifiable {
    let id = UUID()
    let object: MobileDatabaseObject
    let columns: [MobileTableColumn]
    var filter: WorkspaceDatabaseDataFilter
    var message: String?

    init(object: MobileDatabaseObject, columns: [MobileTableColumn], filter: WorkspaceDatabaseDataFilter) {
        self.object = object; self.columns = columns; self.filter = filter
        if self.filter.conditions.isEmpty { addCondition() }
    }
    var canApply: Bool { (try? Self.validate(filter, columns: columns)) != nil }
    func addCondition() {
        guard let column = columns.first else { return }
        filter.conditions.append(WorkspaceSQLDataFilterColumn.defaultCondition(name: column.name, type: column.type,
            kind: .init(mysqlType: column.type)))
    }
    nonisolated static func validate(_ filter: WorkspaceDatabaseDataFilter, columns: [MobileTableColumn]) throws {
        guard !filter.usesElasticsearchConditions, filter.isValid, filter.enabledConditions.allSatisfy({ condition in
            columns.contains { $0.name == condition.columnName && WorkspaceDatabaseDataFilterColumnKind(mysqlType: $0.type) == condition.columnKind }
        }) else { throw WorkspaceSessionError.invalidDataFilter }
    }
}
