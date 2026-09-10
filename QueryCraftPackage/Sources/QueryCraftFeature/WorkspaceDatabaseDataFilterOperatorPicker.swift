import AppKit
import SwiftUI

struct WorkspaceDatabaseDataFilterOperatorPicker: NSViewRepresentable {
    @Binding var selection: WorkspaceDatabaseDataFilterOperator
    let options: [WorkspaceDatabaseDataFilterOperator]
    var accessibilityTitle = AppCopy.current.text("运算符", "Operator")
    let presentationRequest: Int
    let dismissalRequest: Int
    let presentationChanged: @MainActor @Sendable (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: $selection,
            presentationChanged: presentationChanged
        )
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        Self.configureLayout(popUpButton)
        popUpButton.controlSize = .regular
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))
        popUpButton.setAccessibilityLabel(accessibilityTitle)
        synchronize(popUpButton, coordinator: context.coordinator)
        return popUpButton
    }

    static func configureLayout(_ popUpButton: NSPopUpButton) {
        popUpButton.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        popUpButton.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        popUpButton.cell?.usesSingleLineMode = true
        popUpButton.cell?.lineBreakMode = .byTruncatingTail
    }

    func updateNSView(_ popUpButton: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.presentationChanged = presentationChanged
        popUpButton.setAccessibilityLabel(accessibilityTitle)
        synchronize(popUpButton, coordinator: context.coordinator)
        context.coordinator.dismissIfNeeded(
            popUpButton,
            request: dismissalRequest
        )
        context.coordinator.presentIfNeeded(
            popUpButton,
            request: presentationRequest
        )
    }

    static func dismantleNSView(
        _ popUpButton: NSPopUpButton,
        coordinator: Coordinator
    ) {
        popUpButton.menu?.cancelTracking()
        coordinator.cancelPresentation()
    }

    private func synchronize(
        _ popUpButton: NSPopUpButton,
        coordinator: Coordinator
    ) {
        let titles = options.map(\.title)
        if popUpButton.itemTitles != titles {
            popUpButton.removeAllItems()
            popUpButton.addItems(withTitles: titles)
        }
        if let selectedIndex = options.firstIndex(of: selection) {
            popUpButton.selectItem(at: selectedIndex)
        }
        coordinator.options = options
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<WorkspaceDatabaseDataFilterOperator>
        var presentationChanged: @MainActor @Sendable (Bool) -> Void
        var options: [WorkspaceDatabaseDataFilterOperator] = []
        private var lastPresentationRequest = 0
        private var lastDismissalRequest = 0
        private var presentationTask: Task<Void, Never>?

        init(
            selection: Binding<WorkspaceDatabaseDataFilterOperator>,
            presentationChanged: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            self.selection = selection
            self.presentationChanged = presentationChanged
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard options.indices.contains(sender.indexOfSelectedItem) else {
                return
            }
            selection.wrappedValue = options[sender.indexOfSelectedItem]
        }

        func presentIfNeeded(
            _ popUpButton: NSPopUpButton,
            request: Int
        ) {
            guard request > 0, request != lastPresentationRequest else { return }
            lastPresentationRequest = request
            presentationTask?.cancel()
            presentationTask = Task { @MainActor [weak popUpButton] in
                presentationChanged(true)
                await Task.yield()
                guard !Task.isCancelled, let popUpButton else {
                    presentationChanged(false)
                    return
                }
                popUpButton.performClick(nil)
                presentationChanged(false)
                presentationTask = nil
            }
        }

        func dismissIfNeeded(
            _ popUpButton: NSPopUpButton,
            request: Int
        ) {
            guard request > 0, request != lastDismissalRequest else { return }
            lastDismissalRequest = request
            presentationTask?.cancel()
            popUpButton.menu?.cancelTracking()
        }

        func cancelPresentation() {
            presentationTask?.cancel()
            presentationTask = nil
            presentationChanged(false)
        }
    }
}
