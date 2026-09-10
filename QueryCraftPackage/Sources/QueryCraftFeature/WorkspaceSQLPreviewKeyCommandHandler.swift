import AppKit
import SwiftUI

struct WorkspaceSQLPreviewKeyCommandHandler: NSViewRepresentable {
    let dismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.dismiss = dismiss
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var dismiss: @MainActor () -> Void
        private var eventMonitor: Any?

        init(dismiss: @escaping @MainActor () -> Void) {
            self.dismiss = dismiss
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard
                    let self,
                    event.window === view?.window,
                    Self.shouldDismiss(for: event)
                else {
                    return event
                }
                dismiss()
                return nil
            }
        }

        static func shouldDismiss(for event: NSEvent) -> Bool {
            event.type == .keyDown && event.keyCode == 53
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
