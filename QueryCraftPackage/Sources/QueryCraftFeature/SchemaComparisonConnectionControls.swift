import AppKit
import SwiftUI

/// Explicit native popup: the whole bordered control opens the connection menu.
struct SchemaComparisonConnectionPicker: NSViewRepresentable {
    let profiles: [ConnectionProfile]
    let selection: UUID?
    let accessibilityIdentifier: String
    let select: (UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel(AppCopy.current.text("选择连接", "Choose Connection"))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        if context.coordinator.profiles != profiles {
            context.coordinator.profiles = profiles
            button.removeAllItems()
            button.addItem(withTitle: AppCopy.current.text("选择 MySQL 连接…", "Choose MySQL Connection…"))
            for profile in profiles {
                let duplicatedName = profiles.filter { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }.count > 1
                button.addItem(withTitle: duplicatedName ? "\(profile.name) — \(profile.host):\(profile.port)" : profile.name)
                button.lastItem?.toolTip = "\(profile.host):\(profile.port)"
                button.lastItem?.representedObject = profile.id.uuidString
            }
        }
        let index = selection.flatMap { id in profiles.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: SchemaComparisonConnectionPicker
        var profiles: [ConnectionProfile]? // nil forces initial menu construction, even if empty.
        init(parent: SchemaComparisonConnectionPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            parent.select((sender.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)))
        }
    }
}

/// Lists discovered databases while allowing a name when listing is restricted.
struct SchemaComparisonDatabaseComboBox: NSViewRepresentable {
    @Binding var text: String
    let databases: [String]
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox(frame: .zero)
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.isEditable = true
        box.completes = true
        box.hasVerticalScroller = true
        box.numberOfVisibleItems = 8
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.changed(_:))
        box.placeholderString = AppCopy.current.text("选择或输入数据库", "Choose or Enter Database")
        box.setAccessibilityLabel(AppCopy.current.text("数据库", "Database"))
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        box.setAccessibilityIdentifier(accessibilityIdentifier)
        if context.coordinator.databases != databases {
            context.coordinator.databases = databases
            box.removeAllItems()
            box.addItems(withObjectValues: databases)
        }
        if box.stringValue != text { box.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: SchemaComparisonDatabaseComboBox
        var databases: [String] = []
        init(parent: SchemaComparisonDatabaseComboBox) { self.parent = parent }
        @objc func changed(_ sender: NSComboBox) { parent.text = sender.stringValue }
        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            changed(box)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            if box.indexOfSelectedItem >= 0,
               let name = box.itemObjectValue(at: box.indexOfSelectedItem) as? String { parent.text = name }
        }
    }
}
