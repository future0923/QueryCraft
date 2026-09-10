import AppKit
import SwiftUI

struct WorkspacePendingChangesKeyCommandHandler: NSViewRepresentable {
    let actions: WorkspacePendingChangesActions?

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
        var actions: WorkspacePendingChangesActions?
        private var eventMonitor: Any?

        init(actions: WorkspacePendingChangesActions?) {
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

        func handle(_ event: NSEvent) -> Bool {
            guard let actions else { return false }
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .control, .option, .shift])

            if modifiers == .command,
               event.matchesWorkspaceShortcut(keyCode: 1, character: "s"),
               actions.canPreview,
               actions.canCommit,
               !actions.isCommitting
            {
                actions.commit()
                return true
            }
            if modifiers == [.command, .shift],
               event.matchesWorkspaceShortcut(keyCode: 35, character: "p"),
               actions.canPreview
            {
                actions.preview()
                return true
            }
            if modifiers == [.command, .shift],
               [51, 117].contains(event.keyCode),
               actions.hasChanges,
               !actions.isCommitting
            {
                actions.discard()
                return true
            }
            return false
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
