public struct WorkspaceDatabaseDataFilter: Hashable, Sendable {
    public var logic: WorkspaceDatabaseDataFilterLogic
    public var conditions: [WorkspaceDatabaseDataFilterCondition]

    public init(
        logic: WorkspaceDatabaseDataFilterLogic = .matchAll,
        conditions: [WorkspaceDatabaseDataFilterCondition] = []
    ) {
        self.logic = logic
        self.conditions = conditions
    }

    public static let empty = WorkspaceDatabaseDataFilter()

    public var enabledConditions: [WorkspaceDatabaseDataFilterCondition] {
        conditions.filter(\.isEnabled)
    }

    public var effectiveConditions: [WorkspaceDatabaseDataFilterCondition] {
        usesElasticsearchConditions ? conditions : enabledConditions
    }

    public var usesElasticsearchConditions: Bool {
        conditions.contains { $0.columnKind.isElasticsearch }
    }

    public var isActive: Bool {
        !effectiveConditions.isEmpty
    }

    public var isValid: Bool {
        effectiveConditions.allSatisfy(\.isValid)
    }
}
