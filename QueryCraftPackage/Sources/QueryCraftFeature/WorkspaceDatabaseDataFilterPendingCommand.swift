enum WorkspaceDatabaseDataFilterPendingCommand: Sendable {
    case addCondition
    case removeCondition
    case applyAll
    case moveUp
    case moveDown
    case openColumnPicker
    case openOperatorPicker
    case toggleCondition
    case closeFilter
}
