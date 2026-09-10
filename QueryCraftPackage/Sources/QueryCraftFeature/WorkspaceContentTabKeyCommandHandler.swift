import AppKit
import SwiftUI

struct WorkspaceContentTabKeyCommandHandler: NSViewRepresentable {
    let actions: WorkspaceContentTabCommandActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

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
        var actions: WorkspaceContentTabCommandActions
        private var eventMonitor: Any?

        init(actions: WorkspaceContentTabCommandActions) {
            self.actions = actions
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, event.window === view?.window else { return event }
                return handle(event) ? nil : event
            }
        }

        func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .control, .option, .shift])

            if modifiers == .command,
               event.matchesWorkspaceShortcut(keyCode: 17, character: "t"),
               actions.canCreateQuery
            {
                actions.createQuery()
                return true
            }
            if modifiers == .command,
               event.matchesWorkspaceShortcut(keyCode: 13, character: "w")
            {
                actions.closeSelected()
                return true
            }
            if modifiers == .command,
               let index = Self.numberKeyCodes.firstIndex(of: event.keyCode)
            {
                actions.selectAtIndex(index)
                return true
            }
            if event.keyCode == 30, modifiers == [.command, .shift] {
                actions.selectRelative(1)
                return true
            }
            if event.keyCode == 33, modifiers == [.command, .shift] {
                actions.selectRelative(-1)
                return true
            }
            return false
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        private static let numberKeyCodes: [UInt16] = [
            18, 19, 20, 21, 23, 22, 26, 28, 25,
        ]
    }
}
