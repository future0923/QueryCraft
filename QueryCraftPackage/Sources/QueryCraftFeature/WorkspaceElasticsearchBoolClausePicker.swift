import AppKit
import SwiftUI

struct WorkspaceElasticsearchBoolClausePicker: NSViewRepresentable {
    @Binding var selection: WorkspaceElasticsearchBoolClause

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        Self.configureLayout(popUpButton)
        popUpButton.controlSize = .regular
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))
        popUpButton.setAccessibilityLabel(
            AppCopy.current.text("Bool 子句", "Bool Clause")
        )
        synchronize(popUpButton, coordinator: context.coordinator)
        return popUpButton
    }

    func updateNSView(_ popUpButton: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        synchronize(popUpButton, coordinator: context.coordinator)
    }

    static func configureLayout(_ popUpButton: NSPopUpButton) {
        popUpButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUpButton.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        popUpButton.cell?.usesSingleLineMode = true
        popUpButton.cell?.lineBreakMode = .byTruncatingTail
    }

    private func synchronize(
        _ popUpButton: NSPopUpButton,
        coordinator: Coordinator
    ) {
        let options = WorkspaceElasticsearchBoolClause.allCases
        let titles = options.map(\.rawValue)
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
        var selection: Binding<WorkspaceElasticsearchBoolClause>
        var options: [WorkspaceElasticsearchBoolClause] = []

        init(selection: Binding<WorkspaceElasticsearchBoolClause>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard options.indices.contains(sender.indexOfSelectedItem) else {
                return
            }
            selection.wrappedValue = options[sender.indexOfSelectedItem]
        }
    }
}
