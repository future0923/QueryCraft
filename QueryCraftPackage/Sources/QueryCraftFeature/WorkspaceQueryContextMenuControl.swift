import AppKit
import SwiftUI

struct WorkspaceQueryContextMenuOption: Equatable {
    let value: String?
    let title: String
}

struct WorkspaceQueryContextMenuControl: NSViewRepresentable {
    let options: [WorkspaceQueryContextMenuOption]
    let selection: String?
    let width: CGFloat
    let isEnabled: Bool
    let help: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let select: @MainActor (String?) -> Void

    static func preferredWidth(
        for options: [WorkspaceQueryContextMenuOption],
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize(for: .regular)
        )
        let titleWidth = options.lazy.map { option in
            (option.title as NSString).size(
                withAttributes: [.font: font]
            ).width
        }.max() ?? 0
        // Includes the native popup button's text insets and arrow area.
        return min(maximum, max(minimum, ceil(titleWidth + 42)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(control: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        popUpButton.controlSize = .regular
        popUpButton.target = context.coordinator
        popUpButton.action = #selector(Coordinator.selectionChanged(_:))
        (popUpButton.cell as? NSPopUpButtonCell)?.lineBreakMode =
            .byTruncatingTail
        update(popUpButton, coordinator: context.coordinator)
        return popUpButton
    }

    func updateNSView(
        _ popUpButton: NSPopUpButton,
        context: Context
    ) {
        context.coordinator.control = self
        update(popUpButton, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSPopUpButton,
        context: Context
    ) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    private func update(
        _ popUpButton: NSPopUpButton,
        coordinator: Coordinator
    ) {
        let titles = options.map(\.title)
        if popUpButton.itemTitles != titles {
            popUpButton.removeAllItems()
            popUpButton.addItems(withTitles: titles)
        }
        let selectedIndex = options.firstIndex { $0.value == selection }
            ?? options.indices.first
        if let selectedIndex,
           popUpButton.indexOfSelectedItem != selectedIndex
        {
            popUpButton.selectItem(at: selectedIndex)
        }
        popUpButton.isEnabled = isEnabled
        popUpButton.toolTip = help
        popUpButton.setAccessibilityLabel(accessibilityLabel)
        popUpButton.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var control: WorkspaceQueryContextMenuControl

        init(control: WorkspaceQueryContextMenuControl) {
            self.control = control
        }

        @objc
        func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard control.options.indices.contains(index) else { return }
            control.select(control.options[index].value)
        }
    }
}
