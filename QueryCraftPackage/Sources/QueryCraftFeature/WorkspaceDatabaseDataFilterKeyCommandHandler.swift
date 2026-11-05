import AppKit
import SwiftUI

struct WorkspaceDatabaseDataFilterKeyCommandHandler: NSViewRepresentable {
    let actions: WorkspaceDatabaseDataFilterCommandActions
    let isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions, isFocused: isFocused)
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
        context.coordinator.isFocused = isFocused
        if isFocused {
            context.coordinator.startMonitoring()
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var actions: WorkspaceDatabaseDataFilterCommandActions
        var isFocused: Bool
        private var eventMonitor: Any?

        init(actions: WorkspaceDatabaseDataFilterCommandActions, isFocused: Bool) {
            self.actions = actions
            self.isFocused = isFocused
        }

        func startMonitoring() {
            guard isFocused, eventMonitor == nil else { return }
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
            guard isFocused else { return false }
            let modifiers = event.modifierFlags
                .intersection([.command, .control, .option, .shift])
            if event.keyCode == 53, modifiers.isEmpty {
                guard actions.canCloseFilter else { return false }
                actions.close()
                return true
            }

            guard modifiers == .command || modifiers == [.command, .shift] else { return false }

            // AppKit's field editor owns native cursor and selection movement,
            // including when it belongs to a filter value rather than a cell.
            if [123, 124, 125, 126].contains(event.keyCode),
               modifiers != .command || event.window?.firstResponder is NSTextView {
                return false
            }

            switch event.keyCode {
            case 36 where modifiers == .command && actions.canApplyAll:
                actions.applyAll()
            case 126 where actions.canNavigateConditions:
                actions.moveUp()
            case 125 where actions.canNavigateConditions:
                actions.moveDown()
            case 123 where actions.canEditActiveCondition:
                actions.openColumnPicker()
            case 124 where actions.canEditActiveCondition:
                actions.openOperatorPicker()
            default:
                return handleCharacterShortcut(event, modifiers: modifiers)
            }
            return true
        }

        private func handleCharacterShortcut(
            _ event: NSEvent,
            modifiers: NSEvent.ModifierFlags
        ) -> Bool {
            if modifiers == [.command, .shift] {
                guard event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
                      actions.canRemoveCondition else { return false }
                actions.removeCondition()
                return true
            }
            if event.matchesWorkspaceShortcut(
                keyCode: 34,
                character: "i"
            ), actions.canAddCondition {
                actions.addCondition()
            } else if event.matchesWorkspaceShortcut(
                keyCode: 11,
                character: "b"
            ), actions.canToggleCondition {
                actions.toggleCondition()
            } else {
                return false
            }
            return true
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

    }
}
