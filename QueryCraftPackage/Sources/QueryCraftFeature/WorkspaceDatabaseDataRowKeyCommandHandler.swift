import AppKit
import SwiftUI

struct WorkspaceDatabaseDataRowKeyCommandHandler: NSViewRepresentable {
    let actions: WorkspaceDatabaseDataRowCommandActions?
    let filterPresentationActions:
        WorkspaceDatabaseDataFilterPresentationActions?
    let objectDetailTabActions: WorkspaceDatabaseObjectDetailTabActions?
    let isSuspended: Bool
    let schemaActions: WorkspaceDatabaseSchemaRowCommandActions?
    let handlesSchemaActionsInDataGrid: Bool

    init(
        actions: WorkspaceDatabaseDataRowCommandActions?,
        filterPresentationActions:
            WorkspaceDatabaseDataFilterPresentationActions?,
        objectDetailTabActions: WorkspaceDatabaseObjectDetailTabActions?,
        isSuspended: Bool,
        schemaActions: WorkspaceDatabaseSchemaRowCommandActions? = nil,
        handlesSchemaActionsInDataGrid: Bool = false
    ) {
        self.actions = actions
        self.filterPresentationActions = filterPresentationActions
        self.objectDetailTabActions = objectDetailTabActions
        self.isSuspended = isSuspended
        self.schemaActions = schemaActions
        self.handlesSchemaActionsInDataGrid = handlesSchemaActionsInDataGrid
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            actions: actions,
            filterPresentationActions: filterPresentationActions,
            objectDetailTabActions: objectDetailTabActions,
            isSuspended: isSuspended,
            schemaActions: schemaActions,
            handlesSchemaActionsInDataGrid: handlesSchemaActionsInDataGrid
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.actions = actions
        context.coordinator.filterPresentationActions =
            filterPresentationActions
        context.coordinator.objectDetailTabActions = objectDetailTabActions
        context.coordinator.isSuspended = isSuspended
        context.coordinator.schemaActions = schemaActions
        context.coordinator.handlesSchemaActionsInDataGrid = handlesSchemaActionsInDataGrid
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var actions: WorkspaceDatabaseDataRowCommandActions?
        var filterPresentationActions:
            WorkspaceDatabaseDataFilterPresentationActions?
        var objectDetailTabActions: WorkspaceDatabaseObjectDetailTabActions?
        var isSuspended: Bool
        var schemaActions: WorkspaceDatabaseSchemaRowCommandActions?
        var handlesSchemaActionsInDataGrid: Bool
        private var eventMonitor: Any?

        init(
            actions: WorkspaceDatabaseDataRowCommandActions?,
            filterPresentationActions:
                WorkspaceDatabaseDataFilterPresentationActions?,
            objectDetailTabActions: WorkspaceDatabaseObjectDetailTabActions?,
            isSuspended: Bool,
            schemaActions: WorkspaceDatabaseSchemaRowCommandActions? = nil,
            handlesSchemaActionsInDataGrid: Bool = false
        ) {
            self.actions = actions
            self.filterPresentationActions = filterPresentationActions
            self.objectDetailTabActions = objectDetailTabActions
            self.isSuspended = isSuspended
            self.schemaActions = schemaActions
            self.handlesSchemaActionsInDataGrid = handlesSchemaActionsInDataGrid
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard
                    let self,
                    event.window === view?.window
                else {
                    return event
                }
                return handle(event) ? nil : event
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .control, .option, .shift])

            if modifiers == [.command, .shift],
               event.matchesWorkspaceShortcut(keyCode: 3, character: "f"),
               let toggle = filterPresentationActions?.toggle
            {
                performAfterCurrentKeyEvent(toggle)
                return true
            }

            if modifiers == .command,
               let objectDetailTabActions,
               let tab = objectDetailTabActions.availableTabs.first(
                   where: { tab in
                       guard let shortcut = objectDetailTabActions.shortcut(
                           for: tab
                       ) else {
                           return false
                       }
                       return event.matchesWorkspaceShortcut(
                           keyCode: shortcut.keyCode,
                           character: String(shortcut.character)
                       )
                   }
               )
            {
                performAfterCurrentKeyEvent { [objectDetailTabActions] in
                    objectDetailTabActions.selectIfAvailable(tab)
                }
                return true
            }

            guard !isSuspended else { return false }
            // SQL Structure owns a dedicated grid monitor. Mapping uses the data
            // grid, so its published schema actions must handle key equivalents
            // here before an unrelated editor/menu can consume them.
            if event.window?.firstResponder is WorkspaceDirectDrawTableView,
               !handlesSchemaActionsInDataGrid {
                return false
            }

            if let schemaActions {
                if modifiers == .command,
                   event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
                   schemaActions.canAdd
                {
                    performAfterCurrentKeyEvent(schemaActions.add)
                    return true
                }
                if modifiers == .command,
                   event.matchesWorkspaceShortcut(keyCode: 2, character: "d"),
                   schemaActions.canDuplicate,
                   let selectedID = schemaActions.selectedID
                {
                    let duplicate = schemaActions.duplicate
                    performAfterCurrentKeyEvent {
                        duplicate(selectedID)
                    }
                    return true
                }
                if modifiers.isEmpty,
                   [51, 117].contains(event.keyCode),
                   !Self.isTextEditingResponder(event.window?.firstResponder),
                   schemaActions.canDelete,
                   let selectedID = schemaActions.selectedID
                {
                    schemaActions.delete(selectedID)
                    return true
                }
            }

            guard let actions else { return false }

            if modifiers == .command,
               event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
               actions.canAddRow
            {
                performAfterCurrentKeyEvent(actions.addRow)
                return true
            }
            if modifiers == .command,
               event.matchesWorkspaceShortcut(keyCode: 2, character: "d"),
               actions.canDuplicateRow,
               let row = actions.selectedRowIndex
            {
                let duplicateRow = actions.duplicateRow
                performAfterCurrentKeyEvent {
                    duplicateRow(row)
                }
                return true
            }
            if modifiers.isEmpty,
               [51, 117].contains(event.keyCode),
               !Self.isTextEditingResponder(event.window?.firstResponder),
               actions.canDeleteRow,
               !actions.selectedRowIndexes.isEmpty
            {
                actions.deleteRows(actions.selectedRowIndexes)
                return true
            }
            return false
        }

        static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
            responder is NSTextView
        }

        private func performAfterCurrentKeyEvent(
            _ action: @escaping @MainActor @Sendable () -> Void
        ) {
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
