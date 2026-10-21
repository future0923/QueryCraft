import AppKit
import SwiftUI

/// Keep the native menu and its items alive across policy changes. SwiftUI's
/// menu Picker otherwise rebuilds its selection content inside grouped Forms.
struct MCPPermissionPicker: NSViewRepresentable {
    let selection: MCPPermissionSelection
    let choices: [MCPPermissionSelection]
    let accessibilityLabel: String
    let onChange: (MCPPermissionSelection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = true
        button.alignment = .right
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: min(MCPPermissionLayout.controlWidth, max(80, nsView.intrinsicContentSize.width)), height: 22)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        context.coordinator.onChange = onChange
        context.coordinator.selection = selection
        button.setAccessibilityLabel(accessibilityLabel)
        let identifiers = choices.map(\.rawValue)
        if button.itemArray.compactMap({ $0.representedObject as? String }) != identifiers {
            button.removeAllItems()
            for choice in choices {
                button.addItem(withTitle: choice.title)
                button.lastItem?.representedObject = choice.rawValue
            }
            button.menu?.autoenablesItems = false
        }
        for (item, choice) in zip(button.itemArray, choices) {
            let title = choice.title
            if item.title != title { item.title = title }
            // A mixed group is a derived display state, never a selectable action.
            let hidden = choice == .custom && selection != .custom
            if item.isHidden != hidden { item.isHidden = hidden }
        }
        if let index = choices.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var selection: MCPPermissionSelection = .denied
        var onChange: ((MCPPermissionSelection) -> Void)?

        @objc func select(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let raw = sender.selectedItem?.representedObject as? String,
                  let value = MCPPermissionSelection(rawValue: raw), value != .custom, value != selection else { return }
            selection = value
            onChange?(value)
        }
    }
}
