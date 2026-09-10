import AppKit
import SwiftUI

struct WorkspaceDatabaseDataFilterKeyCommandHandler: NSViewRepresentable {
    let actions: WorkspaceDatabaseDataFilterCommandActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
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
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var actions: WorkspaceDatabaseDataFilterCommandActions
        private var eventMonitor: Any?

        init(actions: WorkspaceDatabaseDataFilterCommandActions) {
            self.actions = actions
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

        private func handle(_ event: NSEvent) -> Bool {
            if event.keyCode == 53 {
                guard actions.canCloseFilter else { return false }
                actions.close()
                return true
            }

            let modifiers = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask
            )
            guard modifiers.contains(.command) else { return false }

            switch event.keyCode {
            case 36 where actions.canApplyAll:
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
            if event.matchesWorkspaceShortcut(keyCode: 34, character: "i"),
               modifiers.contains(.shift),
               actions.canRemoveCondition
            {
                actions.removeCondition()
            } else if event.matchesWorkspaceShortcut(
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
