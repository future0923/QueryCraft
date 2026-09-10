import AppKit
import SwiftUI

struct WorkspaceSidebarKeyCommandHandler: NSViewRepresentable {
    let toggleSidebar: @MainActor () -> Void
    let openConnectionPicker: @MainActor () -> Void

    init(
        toggleSidebar: @escaping @MainActor () -> Void,
        openConnectionPicker: @escaping @MainActor () -> Void = {}
    ) {
        self.toggleSidebar = toggleSidebar
        self.openConnectionPicker = openConnectionPicker
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            toggleSidebar: toggleSidebar,
            openConnectionPicker: openConnectionPicker
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
        context.coordinator.toggleSidebar = toggleSidebar
        context.coordinator.openConnectionPicker = openConnectionPicker
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var toggleSidebar: @MainActor () -> Void
        var openConnectionPicker: @MainActor () -> Void
        private var eventMonitor: Any?

        init(
            toggleSidebar: @escaping @MainActor () -> Void,
            openConnectionPicker: @escaping @MainActor () -> Void = {}
        ) {
            self.toggleSidebar = toggleSidebar
            self.openConnectionPicker = openConnectionPicker
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
            if modifiers == [.command, .control],
               event.matchesWorkspaceShortcut(keyCode: 1, character: "s")
            {
                toggleSidebar()
                return true
            }
            if modifiers == [.command, .shift],
               event.matchesWorkspaceShortcut(keyCode: 40, character: "k")
            {
                openConnectionPicker()
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
