import Observation

@MainActor
@Observable
final public class WorkspaceDatabaseDataFilterEditor {
    var isPresented = false
    var draft = WorkspaceDatabaseDataFilter.empty

    func present(
        appliedFilter: WorkspaceDatabaseDataFilter,
        defaultCondition: WorkspaceDatabaseDataFilterCondition?
    ) {
        draft = appliedFilter
        if draft.conditions.isEmpty, let defaultCondition {
            draft.conditions = [defaultCondition]
        }
        isPresented = true
    }

    func dismiss(appliedFilter: WorkspaceDatabaseDataFilter) {
        draft = appliedFilter
        isPresented = false
    }

    func resetForSelectionChange() {
        draft = .empty
        isPresented = false
    }
}
