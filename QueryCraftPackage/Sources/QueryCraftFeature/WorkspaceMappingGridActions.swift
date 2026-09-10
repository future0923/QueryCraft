import AppKit

struct WorkspaceMappingGridActions {
    let changedColumns: [Int: Set<Int>]
    let canEdit: @MainActor (Int, Int) -> Bool
    let menuItems: @MainActor (Int) -> [NSMenuItem]
    var cellOptions: @MainActor (Int, Int) -> [NSMenuItem] = { _, _ in [] }
    var cellControls: @MainActor (Int) -> [Int: WorkspaceGridInlineControl] = { _ in [:] }
    var toggleIndexed: @MainActor (Int) -> Void = { _ in }

    @MainActor static func controls(row: WorkspaceMappingEditorRow, values: WorkspaceDatabaseDataRow?,
                                    canEdit: (Int) -> Bool) -> [Int: WorkspaceGridInlineControl] {
        var controls: [Int: WorkspaceGridInlineControl] = [:]
        if canEdit(1) { controls[1] = .options }
        if ["object", "nested"].contains(row.type) || row.hasConflict {
            controls[2] = .unavailable
        } else {
            let value = row.parameters["index"]
            controls[2] = .booleanIndicator(value == "true" ? .on : value == "false" ? .off : .mixed)
        }
        for column in 3...4 {
            let value = values?.value(at: column)
            let state: NSControl.StateValue = value == .text("true") ? .on : value == .text("false") ? .off : .mixed
            controls[column] = .booleanIndicator(state)
        }
        return controls
    }

    static func nextIndexedValue(_ value: String?) -> String? {
        switch value {
        case "true": "false"
        case "false": nil
        default: "true"
        }
    }
}

@MainActor final class WorkspaceMappingMenuItem: NSMenuItem, NSMenuItemValidation {
    private let perform: () -> Void
    private let allowsAction: Bool
    init(title: String, enabled: Bool = true, action: @escaping () -> Void) {
        perform = action
        allowsAction = enabled
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self; isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { allowsAction }
    @objc private func invoke() { if allowsAction { perform() } }
}
