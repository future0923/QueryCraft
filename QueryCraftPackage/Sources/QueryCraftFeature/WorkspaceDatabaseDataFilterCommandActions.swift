struct WorkspaceDatabaseDataFilterCommandActions {
    let canAddCondition: Bool
    let canRemoveCondition: Bool
    let canApplyAll: Bool
    let canNavigateConditions: Bool
    let canEditActiveCondition: Bool
    let canToggleCondition: Bool
    let canCloseFilter: Bool
    let addCondition: @MainActor @Sendable () -> Void
    let removeCondition: @MainActor @Sendable () -> Void
    let applyAll: @MainActor @Sendable () -> Void
    let moveUp: @MainActor @Sendable () -> Void
    let moveDown: @MainActor @Sendable () -> Void
    let openColumnPicker: @MainActor @Sendable () -> Void
    let openOperatorPicker: @MainActor @Sendable () -> Void
    let toggleCondition: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void
}
